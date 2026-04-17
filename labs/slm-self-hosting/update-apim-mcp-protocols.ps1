[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$ApimServiceName,

    [Parameter(Mandatory)]
    [string]$ApiId,

    [ValidateSet('http', 'https', 'ws', 'wss')]
    [string[]]$Protocols = @('https', 'http'),

    [string]$ApiVersion = '2024-06-01-preview'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed or not available in PATH."
}

$normalizedProtocols = $Protocols |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim().ToLowerInvariant() } |
    Select-Object -Unique

if (-not $normalizedProtocols) {
    throw "At least one protocol must be provided."
}

$uri = "https://management.azure.com/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.ApiManagement/service/${ApimServiceName}/apis/${ApiId}?api-version=${ApiVersion}"
$payload = @{
    properties = @{
        protocols = $normalizedProtocols
    }
} | ConvertTo-Json -Depth 5

$tempFile = Join-Path $env:TEMP ("apim-protocols-{0}.json" -f ([guid]::NewGuid()))

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempFile, $payload, $utf8NoBom)

    az account show --subscription $SubscriptionId --output none

    $target = "$ApimServiceName/$ApiId"
    $action = "set protocols to $($normalizedProtocols -join ', ')"

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        az rest `
            --method patch `
            --uri $uri `
            --headers "Content-Type=application/json" "If-Match=*" `
            --body "@$tempFile" `
            --output none
    }

    $apiResource = az rest `
        --method get `
        --uri $uri `
        --output json | ConvertFrom-Json

    $currentProtocols = @($apiResource.properties.protocols)

    [pscustomobject]@{
        SubscriptionId    = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        ApimServiceName   = $ApimServiceName
        ApiId             = $ApiId
        Protocols         = @($currentProtocols)
    }
}
finally {
    if (Test-Path $tempFile) {
        Remove-Item $tempFile -Force
    }
}
