param(
    [string]$Prompt = "Introduce Taipei in one sentence.",
    [string]$ResourceGroup = "lab-slm-self-hosting-eastus2",
    [string]$ServiceName = "apim-fo3nm7zih5szs",
    [string]$McpUrl = "http://localhost/testmcpv2/mcp",
    [string]$ApiVersion = "2024-10-21",
    [string]$Model = "Phi-3.5-mini-instruct-openvino-gpu:1",
    [switch]$Raw,
    [switch]$SkipVerificationLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
        throw "Unable to resolve APIM resource id for service '$ApimServiceName' in resource group '$ResourceGroupName'."
    }

    $key = az rest `
        --method post `
        --uri "$apimId/subscriptions/apim-subscription/listSecrets?api-version=2024-06-01-preview" `
        --query primaryKey -o tsv

    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "Unable to retrieve APIM subscription key (subscription: apim-subscription)."
    }

    return $key
}

function Get-McpJsonPayloadFromResponse {
    param([Parameter(Mandatory = $true)][string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        throw "MCP endpoint returned an empty response body."
    }

    $trimmed = $Body.Trim()
    if ($trimmed.StartsWith("{")) {
        return $trimmed
    }

    $dataLines = $Body -split "`r?`n" |
        Where-Object { $_ -like "data:*" } |
        ForEach-Object { $_.Substring(5).Trim() } |
        Where-Object { $_ -and $_ -ne "[DONE]" }

    foreach ($line in $dataLines) {
        if ($line.Trim().StartsWith("{")) {
            return $line.Trim()
        }
    }

    throw "Unable to parse MCP response as JSON-RPC. Raw body: $Body"
}

function Show-ShgwVerificationLogs {
    param(
        [Parameter(Mandatory = $true)][string]$SinceUtcIso,
        [Parameter(Mandatory = $true)][string]$McpEndpointUrl
    )

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Warning "docker command not found. Skip SHGW verification logs."
        return
    }

    $mcpPath = $McpEndpointUrl
    try {
        $mcpPath = ([System.Uri]$McpEndpointUrl).AbsolutePath
    }
    catch {
    }

    $logText = docker logs --since $SinceUtcIso --tail 500 self-hosted-gateway 2>$null
    if ([string]::IsNullOrWhiteSpace($logText)) {
        Write-Warning "No new SHGW logs found since $SinceUtcIso."
        return
    }

    $lines = $logText -split "`r?`n"

    $mcpRouteLines = $lines | Where-Object {
        $_ -like "*GatewayLogs*" -and
        $_ -like "*url:*$mcpPath*" -and
        $_ -like "*apiId:*"
    }
    $mcpHandlerLines = $lines | Where-Object {
        $_ -like "*McpPostRequestHandler*" -or
        $_ -like "*Processed MCP method tools/call*"
    }
    $backendLines = $lines | Where-Object {
        $_ -like '*apiId: "ai-model-inference"*' -and
        $_ -like "*getChatCompletions*"
    }

    Write-Host ""
    Write-Host "=== Verification 1/3: SHGW route hit ($mcpPath) ==="
    if ($mcpRouteLines) {
        $mcpRouteLines | Select-Object -Last 2 | ForEach-Object { Write-Host $_ }
    }
    else {
        Write-Host "No matching SHGW route line found."
    }

    Write-Host ""
    Write-Host "=== Verification 2/3: MCP handler executed ==="
    if ($mcpHandlerLines) {
        $mcpHandlerLines | Select-Object -Last 2 | ForEach-Object { Write-Host $_ }
    }
    else {
        Write-Host "No MCP handler line found."
    }

    Write-Host ""
    Write-Host "=== Verification 3/3: Backend ai-model-inference called ==="
    if ($backendLines) {
        $backendLines | Select-Object -Last 2 | ForEach-Object { Write-Host $_ }
    }
    else {
        Write-Host "No backend call line found."
    }
}

Require-AzCli
$subscriptionKey = Get-ApimSubscriptionKey -ResourceGroupName $ResourceGroup -ApimServiceName $ServiceName
$logSinceUtc = (Get-Date).ToUniversalTime().ToString("o")

$payload = @{
    jsonrpc = "2.0"
    id = 1
    method = "tools/call"
    params = @{
        name = "getChatCompletions"
        arguments = @{
            "api-version" = $ApiVersion
            ChatCompletionsOptions = @{
                model = $Model
                messages = @(
                    @{
                        role = "user"
                        content = $Prompt
                    }
                )
            }
        }
    }
}

$payloadJson = $payload | ConvertTo-Json -Depth 20 -Compress
$headers = @{
    "Content-Type" = "application/json; charset=utf-8"
    "Accept" = "text/event-stream"
    "Ocp-Apim-Subscription-Key" = $subscriptionKey
    "api-key" = $subscriptionKey
}

$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
$response = Invoke-WebRequest -Method Post -Uri $McpUrl -Headers $headers -Body $payloadBytes -TimeoutSec 120
$mcpJsonText = Get-McpJsonPayloadFromResponse -Body $response.Content
$mcpResponse = $mcpJsonText | ConvertFrom-Json

if ($Raw) {
    $mcpResponse | ConvertTo-Json -Depth 30
    exit 0
}

if (-not $mcpResponse.result -or -not $mcpResponse.result.content -or $mcpResponse.result.content.Count -eq 0) {
    throw "MCP response does not contain result.content."
}

$toolText = $mcpResponse.result.content[0].text
if ([string]::IsNullOrWhiteSpace($toolText)) {
    throw "Tool response text is empty. Use -Raw to inspect full response."
}

try {
    $toolResult = $toolText | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Tool response is not valid JSON: $toolText"
}

$propertyNames = $toolResult.PSObject.Properties.Name
$hasStatusCode = $propertyNames -contains "statusCode"
$hasStatus = $propertyNames -contains "status"

if ($hasStatusCode -and [int]$toolResult.statusCode -ge 400) {
    throw "Tool call failed: statusCode=$($toolResult.statusCode), message=$($toolResult.message)"
}

if ($hasStatus -and [int]$toolResult.status -ge 400) {
    throw "Tool call failed: status=$($toolResult.status), title=$($toolResult.title), detail=$($toolResult.detail)"
}

if (-not ($propertyNames -contains "choices")) {
    throw "Tool response does not contain chat choices. Use -Raw to inspect full response: $toolText"
}

$messageContent = $toolResult.choices[0].message.content
if ([string]::IsNullOrWhiteSpace($messageContent)) {
    throw "Chat completion returned no content."
}

Write-Host "Model: $($toolResult.model)"
Write-Host "Completion:"
Write-Host $messageContent

if (-not $SkipVerificationLogs) {
    Show-ShgwVerificationLogs -SinceUtcIso $logSinceUtc -McpEndpointUrl $McpUrl
}
