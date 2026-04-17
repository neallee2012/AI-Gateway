param(
    [int]$RequestCount = 5,
    [int]$ConcurrentRequests = 1,
    [int]$DelayBetweenBatchesMs = 500,
    [string]$Prompt = "用台灣的繁體中文 Write a detailed paragraph (about 500 words) explaining Taiwan semiconductor industry history, current status, and future challenges, including two concrete supply-chain resilience examples.",
    [string]$Endpoint = "http://localhost/inference/chat/completions",
    [string]$ApiVersion = "2024-10-21",
    [string]$Model = "Phi-3.5-mini-instruct-openvino-gpu:1",
    [string]$ResourceGroup = "lab-slm-self-hosting",
    [string]$ServiceName = "apim-id37gfgbdfhxu",
    [string]$ApiKey = "",
    [int]$TimeoutSec = 120,
    [switch]$ShowResponseBody
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

if ($RequestCount -lt 1) {
    throw "RequestCount must be >= 1."
}
if ($ConcurrentRequests -lt 1) {
    throw "ConcurrentRequests must be >= 1."
}
if ($DelayBetweenBatchesMs -lt 0) {
    throw "DelayBetweenBatchesMs must be >= 0."
}

function Require-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') is not installed or not in PATH."
    }
}

function Get-ApimSubscriptionKey {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$ApimServiceName
    )

    $apimId = az apim show -g $ResourceGroupName -n $ApimServiceName --query id -o tsv
    if ([string]::IsNullOrWhiteSpace($apimId)) {
        throw "Unable to resolve APIM resource id for '$ApimServiceName'."
    }

    $key = az rest `
        --method post `
        --uri "$apimId/subscriptions/apim-subscription/listSecrets?api-version=2024-06-01-preview" `
        --query primaryKey -o tsv

    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "Unable to retrieve APIM subscription key."
    }

    return $key
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Require-AzCli
    $ApiKey = Get-ApimSubscriptionKey -ResourceGroupName $ResourceGroup -ApimServiceName $ServiceName
}

$uri = "${Endpoint}?api-version=$ApiVersion"
$payloadObject = @{
    model = $Model
    messages = @(
        @{
            role = "user"
            content = $Prompt
        }
    )
}
$payloadJson = $payloadObject | ConvertTo-Json -Depth 10 -Compress
$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
$testRunId = [Guid]::NewGuid().ToString("N")
$headers = @{
    "Content-Type" = "application/json; charset=utf-8"
    "api-key" = $ApiKey
    "x-test-run-id" = $testRunId
}

Write-Host ("Endpoint: {0}" -f $uri)
Write-Host ("Model: {0}" -f $Model)
Write-Host ("Test run id: {0}" -f $testRunId)
Write-Host ("Prompt: {0}" -f $Prompt)

$invokeRequest = {
    param(
        [int]$RequestId,
        [string]$Uri,
        [hashtable]$Headers,
        [byte[]]$PayloadBytes,
        [int]$TimeoutSec,
        [bool]$ShowBody
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $statusCode = 0
    $responseBody = ""
    $errorMessage = ""

    try {
        $invokeParams = @{
            Method = "Post"
            Uri = $Uri
            Headers = $Headers
            Body = $PayloadBytes
            TimeoutSec = $TimeoutSec
        }
        if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("SkipHttpErrorCheck")) {
            $invokeParams["SkipHttpErrorCheck"] = $true
        }

        $response = Invoke-WebRequest @invokeParams
        $statusCode = [int]$response.StatusCode
        $responseBody = [string]$response.Content
    }
    catch {
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                $reader.Dispose()
            }
            catch {
                $responseBody = ""
            }
        }
        else {
            $errorMessage = $_.Exception.Message
        }
    }
    finally {
        $stopwatch.Stop()
    }

    if ($ShowBody -and -not [string]::IsNullOrWhiteSpace($responseBody) -and $responseBody.Length -gt 600) {
        $responseBody = $responseBody.Substring(0, 600) + "..."
    }

    [pscustomobject]@{
        RequestId = $RequestId
        StatusCode = $statusCode
        DurationMs = [int]$stopwatch.ElapsedMilliseconds
        Error = $errorMessage
        Body = $responseBody
    }
}

function Get-ResponsePreview {
    param(
        [string]$Body,
        [int]$MaxLength = 500
    )

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return ""
    }

    $text = $Body
    try {
        $json = $Body | ConvertFrom-Json -Depth 20
        if ($null -ne $json.choices -and $json.choices.Count -gt 0) {
            $choice = $json.choices[0]
            $candidate = $null

            if ($null -ne $choice.message -and $null -ne $choice.message.content) {
                $candidate = $choice.message.content
            }
            elseif ($null -ne $choice.delta -and $null -ne $choice.delta.content) {
                $candidate = $choice.delta.content
            }
            elseif ($null -ne $choice.text) {
                $candidate = $choice.text
            }

            if ($candidate -is [array]) {
                $parts = @()
                foreach ($item in $candidate) {
                    if ($null -ne $item.text -and -not [string]::IsNullOrWhiteSpace([string]$item.text)) {
                        $parts += [string]$item.text
                    }
                }
                if ($parts.Count -gt 0) {
                    $text = $parts -join " "
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $text = [string]$candidate
            }
        }
        elseif ($null -ne $json.error.message) {
            $text = [string]$json.error.message
        }
    }
    catch {
    }

    if ($text -match "\\u[0-9a-fA-F]{4}") {
        try {
            $text = [System.Text.RegularExpressions.Regex]::Unescape($text)
        }
        catch {
        }
    }

    $text = $text -replace "\r?\n", " "
    if ($text.Length -gt $MaxLength) {
        return $text.Substring(0, $MaxLength) + "..."
    }
    return $text
}

function Write-RequestResultLog {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [bool]$ShowRawBody
    )

    $statusColor = "White"
    if ($Result.StatusCode -ge 200 -and $Result.StatusCode -lt 300) {
        $statusColor = "Green"
    }
    elseif ($Result.StatusCode -ge 400 -and $Result.StatusCode -lt 600) {
        $statusColor = "Red"
    }

    Write-Host ("request#{0} status={1} duration={2}ms" -f $Result.RequestId, $Result.StatusCode, $Result.DurationMs) -ForegroundColor $statusColor

    if (-not [string]::IsNullOrWhiteSpace($Result.Error)) {
        Write-Host ("  error: {0}" -f $Result.Error)
    }

    if (-not [string]::IsNullOrWhiteSpace($Result.Body)) {
        Write-Host ("  response: {0}" -f (Get-ResponsePreview -Body $Result.Body))
        if ($ShowRawBody) {
            Write-Host ("  raw body: {0}" -f $Result.Body)
        }
    }
}

if ($ConcurrentRequests -eq 1) {
    Write-Host "Running sequential requests (best for avoiding backend busy)..."
}
else {
    Write-Warning "ConcurrentRequests=$ConcurrentRequests may increase backend busy errors. Use 1 for strict sequential mode."
}

$results = @()
$nextRequest = 1

if ($ConcurrentRequests -eq 1) {
    while ($nextRequest -le $RequestCount) {
        $result = & $invokeRequest -RequestId $nextRequest -Uri $uri -Headers $headers -PayloadBytes $payloadBytes -TimeoutSec $TimeoutSec -ShowBody $ShowResponseBody.IsPresent
        $results += $result
        Write-RequestResultLog -Result $result -ShowRawBody $ShowResponseBody.IsPresent

        $nextRequest++
        if ($nextRequest -le $RequestCount -and $DelayBetweenBatchesMs -gt 0) {
            Start-Sleep -Milliseconds $DelayBetweenBatchesMs
        }
    }
}
else {
    while ($nextRequest -le $RequestCount) {
        $batchSize = [Math]::Min($ConcurrentRequests, $RequestCount - $nextRequest + 1)
        $jobs = @()

        for ($i = 0; $i -lt $batchSize; $i++) {
            $requestId = $nextRequest + $i
            $jobs += Start-Job -ScriptBlock $invokeRequest -ArgumentList $requestId, $uri, $headers, $payloadBytes, $TimeoutSec, $ShowResponseBody.IsPresent
        }

        $nextRequest += $batchSize
        $batchResults = @()
        foreach ($job in $jobs) {
            $batchResults += Receive-Job -Job $job -Wait
        }
        $jobs | Remove-Job | Out-Null

        foreach ($result in ($batchResults | Sort-Object RequestId)) {
            $results += $result
            Write-RequestResultLog -Result $result -ShowRawBody $ShowResponseBody.IsPresent
        }

        if ($nextRequest -le $RequestCount -and $DelayBetweenBatchesMs -gt 0) {
            Start-Sleep -Milliseconds $DelayBetweenBatchesMs
        }
    }
}

Write-Host ""
Write-Host "=== Summary ==="
$grouped = $results | Group-Object StatusCode | Sort-Object Name
foreach ($group in $grouped) {
    $statusCode = [int]$group.Name
    $summaryColor = "White"
    if ($statusCode -ge 200 -and $statusCode -lt 300) {
        $summaryColor = "Green"
    }
    elseif ($statusCode -ge 400 -and $statusCode -lt 600) {
        $summaryColor = "Red"
    }
    Write-Host ("HTTP {0}: {1}" -f $group.Name, $group.Count) -ForegroundColor $summaryColor
}

$first429 = $results | Where-Object { $_.StatusCode -eq 429 } | Select-Object -First 1
if ($first429) {
    Write-Host "Rate limit hit (429) detected."
}
else {
    Write-Host "No 429 detected in this run."
}

