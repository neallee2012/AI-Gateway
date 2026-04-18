# =============================================================================
#  Apply LLM logging policy to a specific API in APIM
# =============================================================================
#  Usage:
#    ./apply-policy.ps1 -ApiName "kunlenewfoundry01" -PolicyType "llm"
#    ./apply-policy.ps1 -ApiName "<agent-api>"      -PolicyType "agent"
# =============================================================================

param(
    [string]$SubscriptionId = "fd50f208-ec1f-4985-85e0-5cb476436ca3",
    [string]$ResourceGroup  = "newfoundry01",
    [string]$ApimName       = "testaigw01",
    [string]$ApiName        = "kunlenewfoundry01",
    [ValidateSet("llm","agent")]
    [string]$PolicyType = "llm"
)

$ErrorActionPreference = "Stop"

$policyFile = if ($PolicyType -eq "llm") {
    "$PSScriptRoot\..\policies\llm-logging-policy.xml"
} else {
    "$PSScriptRoot\..\policies\agent-logging-policy.xml"
}

Write-Host "Setting subscription..."
az account set --subscription $SubscriptionId | Out-Null

Write-Host "Applying '$PolicyType' policy to API '$ApiName'..."
# Read as UTF-8 text explicitly (avoids Get-Content encoding issues / BOM)
$policyXml = [System.IO.File]::ReadAllText($policyFile, [System.Text.UTF8Encoding]::new($false))
# Strip any leading BOM just in case
if ($policyXml.Length -gt 0 -and $policyXml[0] -eq [char]0xFEFF) {
    $policyXml = $policyXml.Substring(1)
}

# Use REST API to set the policy (azure cli doesn't have a direct command for api policy)
$apiVersion = "2024-06-01-preview"
$uri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/apis/$ApiName/policies/policy?api-version=$apiVersion"

$body = @{
    properties = @{
        format = "rawxml"
        value  = $policyXml
    }
} | ConvertTo-Json -Depth 5

$tempFile = [System.IO.Path]::GetTempFileName()
# Write UTF-8 without BOM (az rest cannot handle BOM)
[System.IO.File]::WriteAllText($tempFile, $body, (New-Object System.Text.UTF8Encoding $false))

try {
    # Use Invoke-RestMethod (more robust than `az rest` which has CP950 codec issues
    # when handling responses containing non-ASCII or BOM characters on Windows zh-TW)
    $token = (az account get-access-token --query accessToken -o tsv)
    if ([string]::IsNullOrEmpty($token)) { throw "Failed to acquire ARM access token" }
    $fullUri = "https://management.azure.com$uri"
    $resp = Invoke-RestMethod -Method PUT -Uri $fullUri `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body $body
    Write-Host "Policy applied successfully." -ForegroundColor Green
} catch {
    Write-Host "ERROR applying policy:" -ForegroundColor Red
    Write-Host $_.ErrorDetails.Message
    throw
} finally {
    Remove-Item $tempFile -ErrorAction SilentlyContinue
}
