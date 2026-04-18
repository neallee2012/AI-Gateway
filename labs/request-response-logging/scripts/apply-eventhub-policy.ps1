# =============================================================================
#  Solution C — Apply log-to-eventhub policy at API or Operation scope
# =============================================================================
#  KEY: Policy is header-keyed. Solution ① is unaffected for normal traffic.
#  Only requests with header `X-Logging-Channel: solution-c` will log to EH.
#
#  Usage:
#    .\apply-eventhub-policy.ps1 -ApiName kunlenewfoundry01
#    .\apply-eventhub-policy.ps1 -ApiName kunlenewfoundry01 -Remove
# =============================================================================

param(
    [string]$SubscriptionId = "fd50f208-ec1f-4985-85e0-5cb476436ca3",
    [string]$ResourceGroup  = "newfoundry01",
    [string]$ApimName       = "testaigw01",
    [Parameter(Mandatory=$true)]
    [string]$ApiName,
    [string]$OperationId,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
az account set --subscription $SubscriptionId | Out-Null

$policyFile = "$PSScriptRoot\..\policies\combined-llm-and-eventhub-policy.xml"
$emptyPolicy = '<policies><inbound><base/></inbound><backend><base/></backend><outbound><base/></outbound><on-error><base/></on-error></policies>'

$apiVersion = "2023-05-01-preview"
$baseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/apis/$ApiName"
if ($OperationId) {
    $url = "$baseUrl/operations/$OperationId/policies/policy?api-version=$apiVersion"
} else {
    $url = "$baseUrl/policies/policy?api-version=$apiVersion"
}

$token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

if ($Remove) {
    Write-Host "[Remove] Restoring Solution 1 policy on $ApiName$(if($OperationId){"/$OperationId"})..." -ForegroundColor Yellow
    $solution1File = "$PSScriptRoot\..\policies\llm-logging-policy.xml"
    if (-not (Test-Path $solution1File)) { Write-Error "Solution 1 policy not found: $solution1File"; exit 1 }
    $xml = Get-Content -Path $solution1File -Raw
    $body = @{ properties = @{ format = 'rawxml'; value = $xml } } | ConvertTo-Json -Compress -Depth 5
    Invoke-RestMethod -Method Put -Uri $url -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' | Out-Null
    Write-Host "[Remove] Done. Solution 1 restored." -ForegroundColor Green
    return
}

if (-not (Test-Path $policyFile)) { Write-Error "Policy file not found: $policyFile"; exit 1 }

Write-Host "[Apply] Applying Solution C policy to $ApiName$(if($OperationId){"/$OperationId"})..." -ForegroundColor Cyan
$xml = Get-Content -Path $policyFile -Raw
$body = @{ properties = @{ format = 'rawxml'; value = $xml } } | ConvertTo-Json -Compress -Depth 5
try {
    Invoke-RestMethod -Method Put -Uri $url -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' | Out-Null
    Write-Host "[Apply] Done. Trigger by sending header: X-Logging-Channel: solution-c" -ForegroundColor Green
} catch {
    Write-Host "ERROR:" -ForegroundColor Red
    if ($_.ErrorDetails) { Write-Host $_.ErrorDetails.Message }
    else { Write-Host $_.Exception.Message }
    exit 1
}
