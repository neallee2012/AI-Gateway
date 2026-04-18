# ============================================================================
#  Solution ③ - Deploy Foundry Diagnostic Settings (獨立 Pipeline)
# ============================================================================
#  與方案 ① (deploy-logging.ps1) 完全獨立，可單獨部署/移除。
#  使用方式：
#    .\deploy-foundry-diag.ps1
#    .\deploy-foundry-diag.ps1 -EnableStorageArchive
#    .\deploy-foundry-diag.ps1 -Destroy
# ============================================================================

[CmdletBinding()]
param(
    [string] $ResourceGroup       = 'newfoundry01',
    [string] $FoundryAccountName  = 'kunlenewfoundry01',
    [int]    $RetentionDays       = 30,
    [switch] $EnableStorageArchive,
    [switch] $Destroy
)

$ErrorActionPreference = 'Stop'
$bicepFile = Join-Path $PSScriptRoot '..\bicep\foundry-diagnostics.bicep'

if ($Destroy) {
    Write-Host '[Destroy] Removing solution ③ resources...' -ForegroundColor Yellow
    # 刪 diagnostic setting (no-op if absent)
    az monitor diagnostic-settings delete `
        --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$FoundryAccountName" `
        --name 'foundry-to-dedicated-law' 2>$null

    # 刪 LAW + Storage (依 tag 找)
    $laws = az monitor log-analytics workspace list -g $ResourceGroup `
        --query "[?starts_with(name,'log-foundry-diag-')].name" -o tsv
    foreach ($n in ($laws -split "`n" | Where-Object { $_ })) {
        Write-Host "  Removing LAW: $n" -ForegroundColor DarkYellow
        az monitor log-analytics workspace delete -g $ResourceGroup -n $n --yes --force true 2>$null
    }
    $stgs = az storage account list -g $ResourceGroup `
        --query "[?starts_with(name,'stfoundrydiag')].name" -o tsv
    foreach ($n in ($stgs -split "`n" | Where-Object { $_ })) {
        Write-Host "  Removing Storage: $n" -ForegroundColor DarkYellow
        az storage account delete -g $ResourceGroup -n $n --yes 2>$null
    }
    Write-Host '[Destroy] Done.' -ForegroundColor Green
    return
}

Write-Host "[Deploy] Solution ③ - Foundry Diagnostic Settings (isolated)" -ForegroundColor Cyan
Write-Host "  RG              : $ResourceGroup"
Write-Host "  Foundry Account : $FoundryAccountName"
Write-Host "  Retention       : $RetentionDays days"
Write-Host "  Storage Archive : $($EnableStorageArchive.IsPresent)"

$deployment = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $bicepFile `
    --parameters foundryAccountName=$FoundryAccountName `
                 retentionDays=$RetentionDays `
                 enableStorageArchive=$($EnableStorageArchive.IsPresent.ToString().ToLower()) `
    --query 'properties.outputs' -o json | ConvertFrom-Json

Write-Host ''
Write-Host '[OK] Deployed. Outputs:' -ForegroundColor Green
$deployment | Format-List

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. 等 5-10 分鐘讓第一筆 diagnostic log ingest 進 LAW'
Write-Host '  2. 跑 notebook TC-07 產生流量'
Write-Host "  3. 用 kql\queries-foundry-diag.kql 查詢"
Write-Host "     LAW 名稱：$($deployment.foundryLawName.value)"
