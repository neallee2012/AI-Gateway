// ============================================================================
//  Solution C — APIM log-to-eventhub → Event Hub (+ Capture to Blob)
// ============================================================================
//  Independent from Solution ① (AppInsights). Provides:
//    - Dedicated Event Hub Namespace (Standard SKU, supports Capture)
//    - Event Hub `apim-llm-logs` with Capture enabled → Blob (Avro)
//    - Storage Account for Capture container
//    - APIM Logger (eventhub type) named `eh-logger-solutionc`
//      (does NOT touch the existing AppInsights logger)
//    - Role assignment so APIM MI can send to Event Hub
//
//  IMPORTANT: This bicep ONLY creates infra + APIM Logger. It does NOT
//  apply any policy. Policy is applied by `apply-eventhub-policy.ps1` to
//  let you turn it on/off independently of Solution ①.
// ============================================================================

@description('Existing APIM instance name')
param apimName string = 'testaigw01'

@description('Location for new resources')
param location string = resourceGroup().location

@description('Resource name suffix for uniqueness')
param resourceSuffix string = uniqueString(resourceGroup().id, 'solutionc')

@description('Event Hub Namespace SKU. Standard required for Capture.')
@allowed([ 'Standard', 'Premium' ])
param ehSku string = 'Standard'

@description('Event Hub message retention (days)')
@minValue(1)
@maxValue(7)
param ehRetentionDays int = 7

@description('Capture interval seconds (60-900)')
@minValue(60)
@maxValue(900)
param captureIntervalSeconds int = 300

@description('Capture size threshold bytes (10MB-500MB)')
param captureSizeBytes int = 314572800

// ------------------
//  VARIABLES
// ------------------

var ehNamespaceName = 'ehns-aigw-c-${resourceSuffix}'
var ehName          = 'apim-llm-logs'
var storageName     = take(toLower('staigwc${resourceSuffix}'), 24)
var containerName   = 'capture'
var apimLoggerName  = 'eh-logger-solutionc'

// Built-in role: Azure Event Hubs Data Sender (defined later)



// ------------------
//  EXISTING REFS
// ------------------

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimName
}

// ------------------
//  STORAGE for Capture
// ------------------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
  }

  resource blob 'blobServices' = {
    name: 'default'
    resource container 'containers' = {
      name: containerName
      properties: { publicAccess: 'None' }
    }
  }
}

// ------------------
//  EVENT HUB NAMESPACE + HUB
// ------------------

resource ehNs 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: ehNamespaceName
  location: location
  sku: {
    name: ehSku
    tier: ehSku
    capacity: 1
  }
  properties: {
    isAutoInflateEnabled: true
    maximumThroughputUnits: 5
    minimumTlsVersion: '1.2'
  }
}

resource eh 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: ehNs
  name: ehName
  properties: {
    messageRetentionInDays: ehRetentionDays
    partitionCount: 4
    captureDescription: {
      enabled: true
      encoding: 'Avro'
      intervalInSeconds: captureIntervalSeconds
      sizeLimitInBytes: captureSizeBytes
      destination: {
        name: 'EventHubArchive.AzureBlockBlob'
        properties: {
          storageAccountResourceId: storage.id
          blobContainer: containerName
          archiveNameFormat: '{Namespace}/{EventHub}/{PartitionId}/{Year}/{Month}/{Day}/{Hour}/{Minute}/{Second}'
        }
      }
    }
  }
}

// SAS auth is disabled at tenant policy level — must use Managed Identity.
// Role assignment: APIM system-assigned MI → Event Hubs Data Sender on namespace
var ehDataSenderRoleId = '2b629674-e913-4c01-ae53-ef4638d8f975'

resource roleAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ehNs.id, apimName, ehDataSenderRoleId)
  scope: ehNs
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ehDataSenderRoleId)
  }
}

// ------------------
//  APIM LOGGER (eventhub type, Managed Identity auth)
// ------------------

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = {
  parent: apim
  name: apimLoggerName
  dependsOn: [ roleAssign ]
  properties: {
    loggerType: 'azureEventHub'
    description: 'Solution C — full body logging via Event Hub (MI auth)'
    credentials: {
      endpointAddress: '${ehNs.name}.servicebus.windows.net'
      identityClientId: 'systemAssigned'
      name: ehName
    }
    isBuffered: true
  }
}


// ------------------
//  OUTPUTS
// ------------------

output eventHubNamespace string = ehNs.name
output eventHubName      string = eh.name
output storageAccount    string = storage.name
output captureContainer  string = containerName
output apimLoggerName    string = apimLogger.name
output apimLoggerId      string = apimLogger.id
