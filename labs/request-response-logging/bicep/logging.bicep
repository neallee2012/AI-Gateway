// ============================================================================
//  AI Gateway Request/Response Logging - Infrastructure
// ============================================================================
//  Deploys Log Analytics Workspace + Application Insights
//  and attaches them to an existing APIM instance as a Logger + Diagnostic.
//
//  Usage:
//    az deployment group create \
//      --resource-group newfoundry01 \
//      --template-file logging.bicep \
//      --parameters apimName=testaigw01 apiName=<your-api-name>
// ============================================================================

@description('Name of the existing APIM instance')
param apimName string = 'testaigw01'

@description('Name of the API in APIM to attach diagnostics to (e.g. kunlenewfoundry01)')
param apiName string

@description('Location for new resources')
param location string = resourceGroup().location

@description('Suffix to make resource names unique')
param resourceSuffix string = uniqueString(resourceGroup().id)

@description('Log Analytics workspace retention in days')
param retentionDays int = 30

@description('Max size (bytes) for logging LLM messages')
param llmMessageMaxBytes int = 262144

// ------------------
//  VARIABLES
// ------------------

var logAnalyticsName = 'log-aigw-${resourceSuffix}'
var appInsightsName = 'appi-aigw-${resourceSuffix}'
var apimLoggerName = 'appinsights-logger'

// ------------------
//  RESOURCES
// ------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

// APIM Logger → App Insights
resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = {
  name: apimLoggerName
  parent: apim
  properties: {
    loggerType: 'applicationInsights'
    description: 'Logger for AI Gateway LLM request/response logging'
    resourceId: appInsights.id
    credentials: {
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
  }
}

// Service-level diagnostic (optional - catches anything not covered by API-level)
resource serviceDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2024-06-01-preview' = {
  name: 'applicationinsights'
  parent: apim
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    sampling: { samplingType: 'fixed', percentage: 100 }
    logClientIp: true
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    frontend: {
      request: { body: { bytes: 8192 } }
      response: { body: { bytes: 8192 } }
    }
    backend: {
      request: { body: { bytes: 8192 } }
      response: { body: { bytes: 8192 } }
    }
  }
}

// Reference existing API
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' existing = {
  name: apiName
  parent: apim
}

// API-level diagnostic with LLM logging enabled
resource apiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  name: 'applicationinsights'
  parent: api
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    sampling: { samplingType: 'fixed', percentage: 100 }
    logClientIp: true
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    largeLanguageModel: {
      logs: 'enabled'
      requests: {
        messages: 'all'
        maxSizeInBytes: llmMessageMaxBytes
      }
      responses: {
        messages: 'all'
        maxSizeInBytes: llmMessageMaxBytes
      }
    }
    frontend: {
      request: { body: { bytes: 8192 } }
      response: { body: { bytes: 8192 } }
    }
    backend: {
      request: { body: { bytes: 8192 } }
      response: { body: { bytes: 8192 } }
    }
  }
}

// Platform diagnostic setting - send GatewayLogs / AllMetrics to Log Analytics
resource apimDiagnosticSetting 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'apim-to-log-analytics'
  scope: apim
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ------------------
//  OUTPUTS
// ------------------

output logAnalyticsId string = logAnalytics.id
output logAnalyticsName string = logAnalytics.name
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
output apimLoggerId string = apimLogger.id
