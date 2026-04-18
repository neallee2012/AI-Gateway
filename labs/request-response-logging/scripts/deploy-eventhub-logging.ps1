# =============================================================================
#  Solution C — Deploy Event Hub + APIM Logger (independent from Solution ①)
# =============================================================================
#  Usage:
#    .\deploy-eventhub-logging.ps1                  # deploy
#    .\deploy-eventhub-logging.ps1 -Destroy         # tear down
# =============================================================================

param(
    [string]$SubscriptionId = "fd50f208-ec1f-4985-85e0-5cb476436ca3",
    [string]$ResourceGroup  = "newfoundry01",
    [string]$ApimName       = "testaigw01",
    [switch]$Destroy
)

$ErrorActionPreference = "Stop"
az account set --subscription $SubscriptionId | Out-Null

if ($Destroy) {
    Write-Host "[Destroy] Removing Solution C resources..." -ForegroundColor Yellow
    # Remove APIM logger first (depends on EH)
    az apim logger delete -g $ResourceGroup --service-name $ApimName --logger-id eh-logger-solutionc --yes 2>$null
    # List & delete by name pattern
    $ehns = az eventhubs namespace list -g $ResourceGroup -o json | ConvertFrom-Json | Where-Object { $_.name -like 'ehns-aigw-c-*' }
    foreach ($n in $ehns) {
        Write-Host "  Removing EH NS: $($n.name)"
        az eventhubs namespace delete -g $ResourceGroup -n $n.name --no-wait
    }
    $sas = az storage account list -g $ResourceGroup -o json | ConvertFrom-Json | Where-Object { $_.name -like 'staigwc*' }
    foreach ($s in $sas) {
        Write-Host "  Removing Storage: $($s.name)"
        az storage account delete -g $ResourceGroup -n $s.name --yes
    }
    Write-Host "[Destroy] Done." -ForegroundColor Green
    return
}

Write-Host "[Deploy] Solution C — Event Hub logging..." -ForegroundColor Cyan
$dep = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file "$PSScriptRoot\..\bicep\eventhub-logging.bicep" `
    --parameters apimName=$ApimName `
    --query "properties.outputs" `
    -o json | ConvertFrom-Json

if (-not $dep) { Write-Error "Deployment failed."; exit 1 }

Write-Host ""
Write-Host "Deployment complete:" -ForegroundColor Green
Write-Host "  Event Hub Namespace : $($dep.eventHubNamespace.value)"
Write-Host "  Event Hub           : $($dep.eventHubName.value)"
Write-Host "  Storage (Capture)   : $($dep.storageAccount.value)"
Write-Host "  Capture container   : $($dep.captureContainer.value)"
Write-Host "  APIM Logger         : $($dep.apimLoggerName.value)"
Write-Host ""
Write-Host "Next: run apply-eventhub-policy.ps1 -ApiName <api-id> [-OperationId <op-id>]" -ForegroundColor Yellow
Write-Host "      Then send requests with header: X-Logging-Channel: solution-c" -ForegroundColor Yellow
