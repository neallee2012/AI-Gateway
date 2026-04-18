// ============================================================================
//  Solution ③ - Foundry Diagnostic Settings (獨立部署，與方案 ① 完全隔離)
// ============================================================================
//  把 Azure AI Foundry / AI Services resource 的 Diagnostic Logs 直接送到
//  「專屬」的 Log Analytics Workspace，繞過 APIM policy 抓 streaming body 的雷 (R4)
//  並避免與方案 ① (APIM + LAW + AI) 的資料混在同一個 workspace。
//
//  這個檔案【完全不依賴】logging.bicep，可獨立部署/刪除。
//
//  Usage:
//    az deployment group create \
//      --resource-group newfoundry01 \
//      --template-file foundry-diagnostics.bicep \
//      --parameters foundryAccountName=kunlenewfoundry01
// ============================================================================

@description('Existing Azure AI Services / Foundry account name')
param foundryAccountName string = 'kunlenewfoundry01'

@description('Location for new resources (建議與 Foundry 同 region)')
param location string = resourceGroup().location

@description('Suffix to make resource names unique')
param resourceSuffix string = uniqueString(resourceGroup().id, 'foundry-diag')

@description('Retention days for the dedicated LAW')
param retentionDays int = 30

@description('Enable Storage archive sink (除了 LAW 也存一份到 Blob)')
param enableStorageArchive bool = false

// ------------------
//  VARIABLES - 命名前綴 log-foundry-* 避免與方案 ① log-aigw-* 混淆
// ------------------

var foundryLawName        = 'log-foundry-diag-${resourceSuffix}'
var foundryStorageName    = take('stfoundrydiag${resourceSuffix}', 24)
var diagnosticSettingName = 'foundry-to-dedicated-law'

// ------------------
//  RESOURCES
// ------------------

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryAccountName
}

// 專屬 LAW - 與方案 ① 完全隔離
resource foundryLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: foundryLawName
  location: location
  tags: {
    purpose: 'foundry-diagnostic-logs'
    solution: 'solution-3-isolated'
  }
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

// 可選：Storage 歸檔
resource foundryStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (enableStorageArchive) {
  name: foundryStorageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
  }
}

// 核心：Foundry resource → Diagnostic Settings → 專屬 LAW (+ optional Storage)
resource foundryDiagnostic 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: diagnosticSettingName
  scope: foundry
  properties: {
    workspaceId: foundryLaw.id
    storageAccountId: enableStorageArchive ? foundryStorage.id : null
    logs: [
      { category: 'Audit',           enabled: true, retentionPolicy: { enabled: false, days: 0 } }
      { category: 'RequestResponse', enabled: true, retentionPolicy: { enabled: false, days: 0 } }
      { category: 'Trace',           enabled: true, retentionPolicy: { enabled: false, days: 0 } }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true, retentionPolicy: { enabled: false, days: 0 } }
    ]
  }
}

// ------------------
//  OUTPUTS
// ------------------

output foundryLawId             string = foundryLaw.id
output foundryLawName           string = foundryLaw.name
output foundryLawCustomerId     string = foundryLaw.properties.customerId
output foundryStorageName       string = enableStorageArchive ? foundryStorage.name : ''
output foundryDiagnosticName    string = foundryDiagnostic.name
output foundryAccountId         string = foundry.id
