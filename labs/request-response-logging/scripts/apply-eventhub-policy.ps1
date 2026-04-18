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

$policyFile = "$PSScriptRoot\..\policies\log-to-eventhub-policy.xml"
$emptyPolicy = '<policies><inbound><base/></inbound><backend><base/></backend><outbound><base/></outbound><on-error><base/></on-error></policies>'

if ($Remove) {
    Write-Host "[Remove] Resetting policy on $ApiName$(if($OperationId){"/$OperationId"})..." -ForegroundColor Yellow
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $emptyPolicy -NoNewline
    if ($OperationId) {
        az apim api operation policy create -g $ResourceGroup --service-name $ApimName --api-id $ApiName --operation-id $OperationId --policy-format rawxml --value-path $tmp.FullName | Out-Null
    } else {
        az apim api policy create -g $ResourceGroup --service-name $ApimName --api-id $ApiName --policy-format rawxml --value-path $tmp.FullName | Out-Null
    }
    Remove-Item $tmp
    Write-Host "[Remove] Done." -ForegroundColor Green
    return
}

if (-not (Test-Path $policyFile)) { Write-Error "Policy file not found: $policyFile"; exit 1 }

Write-Host "[Apply] Applying Solution C policy to $ApiName$(if($OperationId){"/$OperationId"})..." -ForegroundColor Cyan
if ($OperationId) {
    az apim api operation policy create -g $ResourceGroup --service-name $ApimName --api-id $ApiName --operation-id $OperationId --policy-format rawxml --value-path $policyFile | Out-Null
} else {
    az apim api policy create -g $ResourceGroup --service-name $ApimName --api-id $ApiName --policy-format rawxml --value-path $policyFile | Out-Null
}
Write-Host "[Apply] Done. Trigger by sending header: X-Logging-Channel: solution-c" -ForegroundColor Green
