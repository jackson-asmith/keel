#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeDiscovery {
    # -Skip conditions are evaluated during discovery, before BeforeAll runs.
    $IsPs7 = [bool]('Microsoft.PowerShell.Commands.HttpResponseException' -as [type])
}

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    $script:ManifestPath = Join-Path $ModuleRoot 'keel.Http.psd1'

    Get-Module keel.Http | Remove-Module -Force
    Import-Module $ManifestPath -Force -ErrorAction Stop

    function New-HttpErrorRecord {
        # Builds an ErrorRecord shaped like the ones Invoke-RestMethod produces:
        # an exception carrying an optional Response object with a StatusCode.
        # Headers, when given, are attached as a plain dictionary like a 5.1 WebHeaderCollection.
        param(
            [string]$Message = 'Request failed.',
            $StatusCode,
            [hashtable]$Headers
        )

        $exception = [System.Exception]::new($Message)
        if ($null -ne $StatusCode) {
            $response = [pscustomobject]@{ StatusCode = $StatusCode; Headers = $Headers }
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
        }

        [System.Management.Automation.ErrorRecord]::new(
            $exception, 'HttpError', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
        )
    }

    function New-Ps7ThrottleErrorRecord {
        # Builds the real PowerShell 7 exception Invoke-RestMethod throws for a 429,
        # with a typed Retry-After header given as either a delay or a date.
        param(
            [Nullable[TimeSpan]]$RetryAfterDelta,
            [Nullable[DateTimeOffset]]$RetryAfterDate
        )

        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
        if ($null -ne $RetryAfterDelta) {
            $response.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]$RetryAfterDelta)
        }
        elseif ($null -ne $RetryAfterDate) {
            $response.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([DateTimeOffset]$RetryAfterDate)
        }

        $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Too many requests', $response)
        [System.Management.Automation.ErrorRecord]::new($exception, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
    }
}

AfterAll {
    Get-Module keel.Http | Remove-Module -Force
}

Describe 'keel.Http module manifest' {
    It 'passes Test-ModuleManifest' {
        Test-ModuleManifest -Path $ManifestPath -ErrorAction Stop | Should-NotBeNull
    }

    It 'declares a non-empty GUID' {
        $manifest = Import-PowerShellDataFile -Path $ManifestPath
        $guid = $manifest.GUID -as [guid]

        $guid | Should-NotBeNull -Because 'GUID must be a valid GUID string'
        $guid | Should-NotBe ([guid]::Empty)
    }

    It 'references a RootModule whose file name matches exactly (case-sensitive file systems)' {
        $manifest = Import-PowerShellDataFile -Path $ManifestPath
        $actualNames = (Get-ChildItem -Path $ModuleRoot -File).Name
        $actualNames -ccontains $manifest.RootModule | Should-BeTrue
    }

    It 'exports exactly the public retry functions' {
        $exported = (Get-Module keel.Http).ExportedFunctions.Keys | Sort-Object
        $exported | Should-BeCollection @('Get-RetryableStatusCode', 'Invoke-WithBoundedRetry')
    }
}

Describe 'Get-RetryableStatusCode' {
    It 'has a mandatory ErrorRecord parameter' {
        Get-Command Get-RetryableStatusCode |
            Should-HaveParameter ErrorRecord -Type System.Management.Automation.ErrorRecord -Mandatory
    }

    Context 'when the exception carries a response object' {
        It 'returns the integer status code from Response.StatusCode' {
            $errorRecord = New-HttpErrorRecord -Message 'throttled' -StatusCode 429
            Get-RetryableStatusCode -ErrorRecord $errorRecord | Should-Be 429
        }

        It 'converts an HttpStatusCode enum value to its integer code' {
            $errorRecord = New-HttpErrorRecord -StatusCode ([System.Net.HttpStatusCode]::ServiceUnavailable)
            Get-RetryableStatusCode -ErrorRecord $errorRecord | Should-Be 503
        }

        It 'returns non-retryable response codes as-is so callers can decide' {
            $errorRecord = New-HttpErrorRecord -Message 'not found' -StatusCode 404
            Get-RetryableStatusCode -ErrorRecord $errorRecord | Should-Be 404
        }

        It 'prefers the response status code over a code mentioned in the message' {
            $errorRecord = New-HttpErrorRecord -Message 'Upstream said 503 earlier' -StatusCode 400
            Get-RetryableStatusCode -ErrorRecord $errorRecord | Should-Be 400
        }

        It 'reads the status code from a real PowerShell 7 HttpResponseException' -Skip:(-not $IsPs7) {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
            $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Too many requests', $response)
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception, 'WebCmdletWebResponseException', 'InvalidOperation', $null
            )

            Get-RetryableStatusCode -ErrorRecord $errorRecord | Should-Be 429
        }
    }

    Context 'when only the exception message is available' {
        It 'extracts retryable code <Code> from the message' -ForEach @(
            @{ Code = 408 }
            @{ Code = 429 }
            @{ Code = 500 }
            @{ Code = 502 }
            @{ Code = 503 }
            @{ Code = 504 }
        ) {
            $errorRecord = New-HttpErrorRecord -Message "Response status code does not indicate success: $Code (Reason)."
            Get-RetryableStatusCode -ErrorRecord $errorRecord | Should-Be $Code
        }

        It 'returns non-retryable codes found in the message so callers can decide' {
            $errorRecord = New-HttpErrorRecord -Message 'Response status code does not indicate success: 404 (Not Found).'
            Get-RetryableStatusCode -ErrorRecord $errorRecord | Should-Be 404
        }

        It 'recognizes the <Source> message format' -ForEach @(
            @{ Source = 'Windows PowerShell 5.1'; Message = 'The remote server returned an error: (429) Too Many Requests.'; Expected = 429 }
            @{ Source = 'Graph SDK named status'; Message = 'Response status code does not indicate success: TooManyRequests (Too Many Requests).'; Expected = 429 }
            @{ Source = 'Graph SDK named status (5xx)'; Message = 'Response status code does not indicate success: ServiceUnavailable (Service Unavailable).'; Expected = 503 }
            @{ Source = 'HTTP status line'; Message = 'Upstream returned HTTP/1.1 502 Bad Gateway'; Expected = 502 }
            @{ Source = 'HTTP prefix'; Message = 'Request failed with HTTP 504'; Expected = 504 }
            @{ Source = 'status code label'; Message = 'Request failed. StatusCode: 408'; Expected = 408 }
            @{ Source = 'status= label'; Message = 'request error status=500 path=/api'; Expected = 500 }
            # Verbatim from Microsoft.Graph.Authentication 2.40.0 after its retry handler gave up.
            @{ Source = 'Graph SDK retries exhausted (504)'; Message = 'Too many retries performed. More than 3 retries encountered while sending the request. (HTTP request failed with status code: GatewayTimeout.) (HTTP request failed with status code: GatewayTimeout.)'; Expected = 504 }
            @{ Source = 'Graph SDK retries exhausted (429)'; Message = 'Too many retries performed. More than 3 retries encountered while sending the request. (HTTP request failed with status code: TooManyRequests.)'; Expected = 429 }
        ) {
            Get-RetryableStatusCode -ErrorRecord (New-HttpErrorRecord -Message $Message) | Should-Be $Expected
        }

        It 'ignores bare numbers that are not presented as a status code: "<Message>"' -ForEach @(
            @{ Message = 'Quota of 500 items exceeded for this tenant.' }
            @{ Message = 'Order 15030 could not be processed' }
            @{ Message = 'Retry 3 of 429 failed validation' }
            @{ Message = 'Response status code does not indicate success: NotARealStatus (Nope).' }
        ) {
            Get-RetryableStatusCode -ErrorRecord (New-HttpErrorRecord -Message $Message) | Should-BeNull
        }

        It 'ignores a status label followed by a word that is not a status name' {
            $record = New-HttpErrorRecord -Message 'Request failed with status code: Unknown.'
            Get-RetryableStatusCode -ErrorRecord $record | Should-BeNull
        }

        It 'returns nothing when no status code can be determined' {
            $errorRecord = New-HttpErrorRecord -Message 'The operation timed out for an unknown reason.'
            Get-RetryableStatusCode -ErrorRecord $errorRecord | Should-BeNull
        }
    }

    Context 'when the exception carries its own StatusCode' {
        It 'reads HttpRequestException.StatusCode' -Skip:(-not $IsPs7) {
            $exception = [System.Net.Http.HttpRequestException]::new('bad gateway', $null, [System.Net.HttpStatusCode]::BadGateway)
            $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, 'HttpError', 'InvalidOperation', $null)

            Get-RetryableStatusCode -ErrorRecord $errorRecord | Should-Be 502
        }

        It 'returns nothing for an HttpRequestException without a status, such as a refused connection' {
            $exception = [System.Net.Http.HttpRequestException]::new('Connection refused (127.0.0.1:1)')
            $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, 'HttpError', 'InvalidOperation', $null)

            Get-RetryableStatusCode -ErrorRecord $errorRecord | Should-BeNull
        }
    }

    Context 'pipeline input' {
        It 'accepts an ErrorRecord from the pipeline' {
            New-HttpErrorRecord -StatusCode 502 | Get-RetryableStatusCode | Should-Be 502
        }

        It 'emits one result per piped ErrorRecord' {
            $results = @(
                New-HttpErrorRecord -StatusCode 429
                New-HttpErrorRecord -Message 'Service returned HTTP 503'
            ) | Get-RetryableStatusCode

            $results | Should-BeCollection @(429, 503)
        }
    }
}

Describe 'Invoke-WithBoundedRetry' {
    BeforeEach {
        $script:Attempts = 0
        Mock Start-Sleep -ModuleName keel.Http { }
        Mock Get-Random -ModuleName keel.Http { 0 }
    }

    It 'has a mandatory ScriptBlock parameter' {
        Get-Command Invoke-WithBoundedRetry | Should-HaveParameter ScriptBlock -Type scriptblock -Mandatory
    }

    It 'rejects a negative BaseDelayMilliseconds' {
        { Invoke-WithBoundedRetry -BaseDelayMilliseconds -1 -ScriptBlock { $script:Attempts++ } } | Should-Throw
        $script:Attempts | Should-Be 0
    }

    It 'allows a BaseDelayMilliseconds of zero' {
        {
            Invoke-WithBoundedRetry -MaxAttempts 2 -BaseDelayMilliseconds 0 -ScriptBlock {
                throw (New-HttpErrorRecord -StatusCode 503)
            }
        } | Should-Throw

        Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 0 }
    }

    It 'rejects a MaxAttempts value below 1 instead of silently doing nothing' {
        { Invoke-WithBoundedRetry -MaxAttempts 0 -ScriptBlock { $script:Attempts++ } } | Should-Throw
        $script:Attempts | Should-Be 0
    }

    Context 'when the operation succeeds' {
        It 'returns the operation output after a single attempt without sleeping' {
            $result = Invoke-WithBoundedRetry -ScriptBlock { $script:Attempts++; 'ok' }

            $result | Should-Be 'ok'
            $script:Attempts | Should-Be 1
            Should-NotInvoke Start-Sleep -ModuleName keel.Http
        }

        It 'passes through multiple output objects unchanged' {
            $result = Invoke-WithBoundedRetry -ScriptBlock { 1; 2; 3 }
            $result | Should-BeCollection @(1, 2, 3)
        }
    }

    Context 'when the operation fails with a retryable status' {
        It 'retries and returns the output of the first successful attempt' {
            $result = Invoke-WithBoundedRetry -ScriptBlock {
                $script:Attempts++
                if ($script:Attempts -lt 3) { throw (New-HttpErrorRecord -StatusCode 503) }
                'recovered'
            }

            $result | Should-Be 'recovered'
            $script:Attempts | Should-Be 3
            Should-Invoke Start-Sleep -ModuleName keel.Http -Times 2 -Exactly
        }

        It 'retries when the status is only present in the exception message' {
            $result = Invoke-WithBoundedRetry -ScriptBlock {
                $script:Attempts++
                if ($script:Attempts -eq 1) {
                    throw 'Response status code does not indicate success: 429 (Too Many Requests).'
                }
                'ok'
            }

            $result | Should-Be 'ok'
            $script:Attempts | Should-Be 2
        }

        It 'gives up after MaxAttempts and rethrows the original error' {
            {
                Invoke-WithBoundedRetry -MaxAttempts 4 -ScriptBlock {
                    $script:Attempts++
                    throw (New-HttpErrorRecord -Message 'still throttled' -StatusCode 429)
                }
            } | Should-Throw -ExceptionMessage 'still throttled'

            $script:Attempts | Should-Be 4
            Should-Invoke Start-Sleep -ModuleName keel.Http -Times 3 -Exactly
        }

        It 'defaults to three attempts' {
            {
                Invoke-WithBoundedRetry -ScriptBlock {
                    $script:Attempts++
                    throw (New-HttpErrorRecord -StatusCode 500)
                }
            } | Should-Throw

            $script:Attempts | Should-Be 3
        }
    }

    Context 'output from failed attempts' {
        It 'returns only the output of the successful attempt' {
            $result = Invoke-WithBoundedRetry -ScriptBlock {
                $script:Attempts++
                "page from attempt $script:Attempts"
                if ($script:Attempts -lt 3) {
                    throw (New-HttpErrorRecord -StatusCode 503)
                }
            }

            $result | Should-Be 'page from attempt 3'
            $script:Attempts | Should-Be 3
        }

        It 'emits nothing when every attempt fails partway through' {
            $output = [System.Collections.Generic.List[object]]::new()
            {
                Invoke-WithBoundedRetry -ScriptBlock {
                    'partial'
                    throw (New-HttpErrorRecord -StatusCode 503)
                } | ForEach-Object { $output.Add($_) }
            } | Should-Throw

            $output.Count | Should-Be 0
        }

        It 'returns nothing when the successful attempt produces no output' {
            $result = @(Invoke-WithBoundedRetry -ScriptBlock { })
            $result.Count | Should-Be 0
        }

        It 'keeps a single collection output as one object' {
            $result = @(Invoke-WithBoundedRetry -ScriptBlock { , @(1, 2, 3) })

            $result.Count | Should-Be 1
            $result[0] | Should-BeCollection @(1, 2, 3)
        }
    }

    Context 'custom retryable status codes' {
        It 'defaults to 408, 429, 500, 502, 503, and 504' {
            $default = (Get-Command Invoke-WithBoundedRetry).Parameters['RetryableStatusCode']
            $default.ParameterType | Should-Be ([int[]])
            InModuleScope keel.Http { $script:RetryableStatusCodes } | Should-BeCollection @(408, 429, 500, 502, 503, 504)
        }

        It 'does not retry status <StatusCode> when it is left out of the list' -ForEach @(
            @{ StatusCode = 500 }
            @{ StatusCode = 502 }
            @{ StatusCode = 504 }
        ) {
            {
                Invoke-WithBoundedRetry -RetryableStatusCode 429, 503 -ScriptBlock {
                    $script:Attempts++
                    throw (New-HttpErrorRecord -StatusCode $StatusCode)
                }
            } | Should-Throw

            $script:Attempts | Should-Be 1
            Should-NotInvoke Start-Sleep -ModuleName keel.Http
        }

        It 'retries status <StatusCode> when it is in the list' -ForEach @(
            @{ StatusCode = 429 }
            @{ StatusCode = 503 }
        ) {
            $result = Invoke-WithBoundedRetry -RetryableStatusCode 429, 503 -ScriptBlock {
                $script:Attempts++
                if ($script:Attempts -eq 1) {
                    throw (New-HttpErrorRecord -StatusCode $StatusCode)
                }
                'sent'
            }

            $result | Should-Be 'sent'
            $script:Attempts | Should-Be 2
        }

        It 'can retry a status outside the default list' {
            $result = Invoke-WithBoundedRetry -RetryableStatusCode 409 -ScriptBlock {
                $script:Attempts++
                if ($script:Attempts -eq 1) {
                    throw (New-HttpErrorRecord -StatusCode 409)
                }
                'resolved'
            }

            $result | Should-Be 'resolved'
        }

        It 'rejects <Case>' -ForEach @(
            @{ Case = 'an empty list'; Codes = @() }
            @{ Case = 'a code below 100'; Codes = @(99) }
            @{ Case = 'a code above 599'; Codes = @(600) }
        ) {
            { Invoke-WithBoundedRetry -RetryableStatusCode $Codes -ScriptBlock { $script:Attempts++ } } | Should-Throw
            $script:Attempts | Should-Be 0
        }
    }

    Context 'when the operation fails with a non-retryable error' {
        It 'rethrows immediately for status <StatusCode>' -ForEach @(
            @{ StatusCode = 400 }
            @{ StatusCode = 401 }
            @{ StatusCode = 403 }
            @{ StatusCode = 404 }
        ) {
            {
                Invoke-WithBoundedRetry -MaxAttempts 5 -ScriptBlock {
                    $script:Attempts++
                    throw (New-HttpErrorRecord -Message 'client error' -StatusCode $StatusCode)
                }
            } | Should-Throw -ExceptionMessage 'client error'

            $script:Attempts | Should-Be 1
            Should-NotInvoke Start-Sleep -ModuleName keel.Http
        }

        It 'does not retry errors that carry no status code' {
            {
                Invoke-WithBoundedRetry -MaxAttempts 5 -ScriptBlock {
                    $script:Attempts++
                    throw 'Cannot index into a null array.'
                }
            } | Should-Throw -ExceptionMessage 'Cannot index into a null array.'

            $script:Attempts | Should-Be 1
        }
    }

    Context 'backoff timing' {
        It 'doubles the delay on each retry starting from BaseDelayMilliseconds' {
            {
                Invoke-WithBoundedRetry -MaxAttempts 4 -BaseDelayMilliseconds 100 -ScriptBlock {
                    throw (New-HttpErrorRecord -StatusCode 503)
                }
            } | Should-Throw

            Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 100 }
            Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 200 }
            Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 400 }
        }

        It 'adds random jitter to the delay' {
            Mock Get-Random -ModuleName keel.Http { 137 }

            {
                Invoke-WithBoundedRetry -MaxAttempts 2 -BaseDelayMilliseconds 100 -ScriptBlock {
                    throw (New-HttpErrorRecord -StatusCode 503)
                }
            } | Should-Throw

            Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 237 }
        }

        It 'caps each delay at 5000 milliseconds' {
            Mock Get-Random -ModuleName keel.Http { 249 }

            {
                Invoke-WithBoundedRetry -MaxAttempts 3 -BaseDelayMilliseconds 6000 -ScriptBlock {
                    throw (New-HttpErrorRecord -StatusCode 503)
                }
            } | Should-Throw

            Should-Invoke Start-Sleep -ModuleName keel.Http -Times 2 -Exactly -ParameterFilter { $Milliseconds -eq 5000 }
        }
    }
}

Describe 'Get-RetryAfterMilliseconds' {
    It 'is not exported' {
        (Get-Module keel.Http).ExportedFunctions.Keys -contains 'Get-RetryAfterMilliseconds' | Should-BeFalse
    }

    Context 'PowerShell 7 typed headers' -Skip:(-not $IsPs7) {
        It 'reads a delta-seconds Retry-After' {
            $errorRecord = New-Ps7ThrottleErrorRecord -RetryAfterDelta ([TimeSpan]::FromSeconds(7))
            InModuleScope keel.Http -Parameters @{ E = $errorRecord } { param($E) Get-RetryAfterMilliseconds -ErrorRecord $E } |
                Should-Be 7000
        }

        It 'reads an HTTP-date Retry-After as the time remaining' {
            $errorRecord = New-Ps7ThrottleErrorRecord -RetryAfterDate ([DateTimeOffset]::UtcNow.AddSeconds(30))
            $result = InModuleScope keel.Http -Parameters @{ E = $errorRecord } { param($E) Get-RetryAfterMilliseconds -ErrorRecord $E }

            $result | Should-BeGreaterThan 25000
            $result | Should-BeLessThanOrEqual 30000
        }

        It 'returns nothing when the response has no Retry-After header' {
            $errorRecord = New-Ps7ThrottleErrorRecord
            InModuleScope keel.Http -Parameters @{ E = $errorRecord } { param($E) Get-RetryAfterMilliseconds -ErrorRecord $E } |
                Should-BeNull
        }
    }

    Context 'Windows PowerShell 5.1 style string headers' {
        It 'reads delta-seconds' {
            $errorRecord = New-HttpErrorRecord -StatusCode 429 -Headers @{ 'Retry-After' = '12' }
            InModuleScope keel.Http -Parameters @{ E = $errorRecord } { param($E) Get-RetryAfterMilliseconds -ErrorRecord $E } |
                Should-Be 12000
        }

        It 'matches the header name case-insensitively' {
            $errorRecord = New-HttpErrorRecord -StatusCode 429 -Headers @{ 'retry-after' = '3' }
            InModuleScope keel.Http -Parameters @{ E = $errorRecord } { param($E) Get-RetryAfterMilliseconds -ErrorRecord $E } |
                Should-Be 3000
        }

        It 'reads an HTTP-date as the time remaining' {
            $date = [DateTimeOffset]::UtcNow.AddSeconds(20).ToString('r', [System.Globalization.CultureInfo]::InvariantCulture)
            $errorRecord = New-HttpErrorRecord -StatusCode 429 -Headers @{ 'Retry-After' = $date }
            $result = InModuleScope keel.Http -Parameters @{ E = $errorRecord } { param($E) Get-RetryAfterMilliseconds -ErrorRecord $E }

            $result | Should-BeGreaterThan 15000
            $result | Should-BeLessThanOrEqual 20000
        }

        It 'treats an HTTP-date in the past as zero' {
            $errorRecord = New-HttpErrorRecord -StatusCode 429 -Headers @{ 'Retry-After' = 'Wed, 21 Oct 2015 07:28:00 GMT' }
            InModuleScope keel.Http -Parameters @{ E = $errorRecord } { param($E) Get-RetryAfterMilliseconds -ErrorRecord $E } |
                Should-Be 0
        }

        It 'returns nothing for an unparseable value' {
            $errorRecord = New-HttpErrorRecord -StatusCode 429 -Headers @{ 'Retry-After' = 'soon' }
            InModuleScope keel.Http -Parameters @{ E = $errorRecord } { param($E) Get-RetryAfterMilliseconds -ErrorRecord $E } |
                Should-BeNull
        }

        It 'returns nothing when there are no headers or no response' {
            $noHeaders = New-HttpErrorRecord -StatusCode 429
            $noResponse = New-HttpErrorRecord -Message 'HTTP 429'

            InModuleScope keel.Http -Parameters @{ E = $noHeaders } { param($E) Get-RetryAfterMilliseconds -ErrorRecord $E } | Should-BeNull
            InModuleScope keel.Http -Parameters @{ E = $noResponse } { param($E) Get-RetryAfterMilliseconds -ErrorRecord $E } | Should-BeNull
        }
    }
}

Describe 'Invoke-WithBoundedRetry Retry-After handling' {
    BeforeEach {
        $script:Attempts = 0
        Mock Start-Sleep -ModuleName keel.Http { }
        Mock Get-Random -ModuleName keel.Http { 0 }
    }

    It 'defaults MaxRetryAfterSeconds to 60' {
        Get-Command Invoke-WithBoundedRetry | Should-HaveParameter MaxRetryAfterSeconds -Type int -DefaultValue 60
    }

    It 'waits the Retry-After duration plus jitter on a <StatusCode>, instead of the backoff delay' -ForEach @(
        @{ StatusCode = 408 }, @{ StatusCode = 429 }, @{ StatusCode = 500 }
        @{ StatusCode = 502 }, @{ StatusCode = 503 }, @{ StatusCode = 504 }
    ) {
        Mock Get-Random -ModuleName keel.Http { 42 }

        $result = Invoke-WithBoundedRetry -BaseDelayMilliseconds 100 -ScriptBlock {
            $script:Attempts++
            if ($script:Attempts -eq 1) {
                throw (New-HttpErrorRecord -StatusCode $StatusCode -Headers @{ 'Retry-After' = '2' })
            }
            'ok'
        }

        $result | Should-Be 'ok'
        Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 2042 }
    }

    It 'is not limited by the 5 second backoff cap' {
        {
            Invoke-WithBoundedRetry -MaxAttempts 2 -ScriptBlock {
                throw (New-HttpErrorRecord -StatusCode 429 -Headers @{ 'Retry-After' = '30' })
            }
        } | Should-Throw

        Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 30000 }
    }

    It 'honors a typed PowerShell 7 Retry-After header' -Skip:(-not $IsPs7) {
        {
            Invoke-WithBoundedRetry -MaxAttempts 2 -ScriptBlock {
                throw (New-Ps7ThrottleErrorRecord -RetryAfterDelta ([TimeSpan]::FromSeconds(9)))
            }
        } | Should-Throw

        Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 9000 }
    }

    It 'rethrows without waiting when Retry-After exceeds MaxRetryAfterSeconds' {
        {
            Invoke-WithBoundedRetry -MaxAttempts 5 -MaxRetryAfterSeconds 10 -ScriptBlock {
                $script:Attempts++
                throw (New-HttpErrorRecord -Message 'slow down' -StatusCode 429 -Headers @{ 'Retry-After' = '11' })
            }
        } | Should-Throw -ExceptionMessage 'slow down'

        $script:Attempts | Should-Be 1
        Should-NotInvoke Start-Sleep -ModuleName keel.Http
    }

    It 'accepts a Retry-After exactly equal to MaxRetryAfterSeconds' {
        {
            Invoke-WithBoundedRetry -MaxAttempts 2 -MaxRetryAfterSeconds 10 -ScriptBlock {
                throw (New-HttpErrorRecord -StatusCode 429 -Headers @{ 'Retry-After' = '10' })
            }
        } | Should-Throw

        Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 10000 }
    }

    It 'falls back to exponential backoff for a 429 without Retry-After' {
        {
            Invoke-WithBoundedRetry -MaxAttempts 2 -BaseDelayMilliseconds 300 -ScriptBlock {
                throw (New-HttpErrorRecord -StatusCode 429)
            }
        } | Should-Throw

        Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 300 }
    }

    It 'does not retry a non-retryable <StatusCode> even when it carries Retry-After' -ForEach @(
        @{ StatusCode = 400 }, @{ StatusCode = 413 }
    ) {
        {
            Invoke-WithBoundedRetry -MaxAttempts 3 -ScriptBlock {
                $script:Attempts++
                throw (New-HttpErrorRecord -StatusCode $StatusCode -Headers @{ 'Retry-After' = '1' })
            }
        } | Should-Throw

        $script:Attempts | Should-Be 1
        Should-NotInvoke Start-Sleep -ModuleName keel.Http
    }

    It 'honors Retry-After when the status is only known from the exception message' {
        # The header comes from the response object; the status comes from the message.
        $exception = [System.Exception]::new('Response status code does not indicate success: 503 (Service Unavailable).')
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ Headers = @{ 'Retry-After' = '4' } })
        $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, 'HttpError', 'InvalidOperation', $null)

        { Invoke-WithBoundedRetry -MaxAttempts 2 -ScriptBlock { throw $errorRecord } } | Should-Throw

        Should-Invoke Start-Sleep -ModuleName keel.Http -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 4000 }
    }

    It 'still gives up after MaxAttempts when every attempt is throttled' {
        {
            Invoke-WithBoundedRetry -MaxAttempts 3 -ScriptBlock {
                $script:Attempts++
                throw (New-HttpErrorRecord -StatusCode 429 -Headers @{ 'Retry-After' = '1' })
            }
        } | Should-Throw

        $script:Attempts | Should-Be 3
        Should-Invoke Start-Sleep -ModuleName keel.Http -Times 2 -Exactly
    }
}
