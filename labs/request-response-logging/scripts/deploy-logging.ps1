# =============================================================================
#  Deploy Log Analytics + App Insights + attach APIM Logger and Diagnostic
# =============================================================================
#  Prerequisites:
#    - Azure CLI logged in to correct subscription
#    - Contributor + RBAC Admin on the Resource Group
#
#  Usage:
#    ./deploy-logging.ps1 -ApiName "kunlenewfoundry01"
# =============================================================================

param(
    [string]$SubscriptionId = "fd50f208-ec1f-4985-85e0-5cb476436ca3",
    [string]$ResourceGroup  = "newfoundry01",
    [string]$ApimName       = "testaigw01",
    [string]$ApiName        = "kunlenewfoundry01"
)

$ErrorActionPreference = "Stop"

Write-Host "Setting subscription to $SubscriptionId..."
az account set --subscription $SubscriptionId | Out-Null

Write-Host "Deploying logging infrastructure..."
$deployment = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file "$PSScriptRoot\..\bicep\logging.bicep" `
    --parameters apimName=$ApimName apiName=$ApiName `
    --query "properties.outputs" `
    -o json | ConvertFrom-Json

if (-not $deployment) {
    Write-Error "Deployment failed."
    exit 1
}

Write-Host ""
Write-Host "Deployment complete:" -ForegroundColor Green
Write-Host "  Log Analytics: $($deployment.logAnalyticsName.value)"
Write-Host "  App Insights : $($deployment.appInsightsName.value)"
Write-Host "  APIM Logger  : $($deployment.apimLoggerId.value)"
Write-Host ""
Write-Host "Next: run ./apply-policy.ps1 to apply LLM logging policy." -ForegroundColor Yellow
