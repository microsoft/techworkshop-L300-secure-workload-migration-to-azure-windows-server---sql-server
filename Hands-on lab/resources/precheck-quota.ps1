param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [string]$Region,

    [string[]]$Regions,

    [string]$VmSku = 'Standard_D4s_v4',

    [int]$RequiredSqlMiVCore = 4,

    [int]$RequiredSqlMiSubnets = 1,

    [switch]$OutputJson
)

$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }

    if ([string]::IsNullOrWhiteSpace($result)) {
        return $null
    }

    return $result | ConvertFrom-Json
}

function Get-CapabilityValue {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Capabilities,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $item = $Capabilities | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($null -eq $item) {
        return $null
    }

    return $item.value
}

function Test-RegionDeployability {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$Region,

        [Parameter(Mandatory = $true)]
        [string]$VmSku,

        [Parameter(Mandatory = $true)]
        [int]$RequiredSqlMiVCore,

        [Parameter(Mandatory = $true)]
        [int]$RequiredSqlMiSubnets
    )

    $vmSkuRecord = Invoke-AzCliJson -Arguments @(
        'vm', 'list-skus',
        '--location', $Region,
        '--resource-type', 'virtualMachines',
        '--size', $VmSku,
        '--all',
        '--query', "[?name=='$VmSku'] | [0].{family:family, capabilities:capabilities}",
        '--output', 'json'
    )

    if ($null -eq $vmSkuRecord) {
        throw "VM SKU '$VmSku' was not found in region '$Region'."
    }

    $vmFamily = $vmSkuRecord.family
    if ([string]::IsNullOrWhiteSpace($vmFamily)) {
        throw "Could not determine VM family for SKU '$VmSku' in '$Region'."
    }

    $requiredVmCoresRaw = Get-CapabilityValue -Capabilities $vmSkuRecord.capabilities -Name 'vCPUs'
    if ([string]::IsNullOrWhiteSpace($requiredVmCoresRaw)) {
        throw "Could not determine required vCPU count for '$VmSku'."
    }

    $requiredVmCores = [int]$requiredVmCoresRaw

    $vmUsage = Invoke-AzCliJson -Arguments @(
        'vm', 'list-usage',
        '--location', $Region,
        '--query', "[?name.value=='$vmFamily'] | [0].{currentValue:currentValue,limit:limit}",
        '--output', 'json'
    )

    if ($null -eq $vmUsage) {
        throw "Could not read VM family quota usage for family '$vmFamily' in '$Region'."
    }

    $vmCurrent = [double]$vmUsage.currentValue
    $vmLimit = [double]$vmUsage.limit
    $vmAvailable = $vmLimit - $vmCurrent

    $sqlUsage = Invoke-AzCliJson -Arguments @(
        'rest', '--method', 'get',
        '--url', "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Sql/locations/$Region/usages?api-version=2023-08-01-preview",
        '--output', 'json'
    )

    if ($null -eq $sqlUsage -or $null -eq $sqlUsage.value) {
        throw "Could not read SQL usage data for region '$Region'."
    }

    $vCoreQuota = $sqlUsage.value | Where-Object { $_.name -eq 'VCoreQuota' } | Select-Object -First 1
    $subnetQuota = $sqlUsage.value | Where-Object { $_.name -eq 'SubnetQuota' } | Select-Object -First 1

    if ($null -eq $vCoreQuota -or $null -eq $subnetQuota) {
        throw "Missing SQL MI quota counters (VCoreQuota/SubnetQuota) for '$Region'."
    }

    $sqlVCoreCurrent = [double]$vCoreQuota.properties.currentValue
    $sqlVCoreLimit = [double]$vCoreQuota.properties.limit
    $sqlVCoreAvailable = $sqlVCoreLimit - $sqlVCoreCurrent

    $sqlSubnetCurrent = [double]$subnetQuota.properties.currentValue
    $sqlSubnetLimit = [double]$subnetQuota.properties.limit
    $sqlSubnetAvailable = $sqlSubnetLimit - $sqlSubnetCurrent

    $vmQuotaOk = $vmAvailable -ge $requiredVmCores
    $sqlVCoreQuotaOk = $sqlVCoreAvailable -ge $RequiredSqlMiVCore
    $sqlSubnetQuotaOk = $sqlSubnetAvailable -ge $RequiredSqlMiSubnets
    $canDeploy = $vmQuotaOk -and $sqlVCoreQuotaOk -and $sqlSubnetQuotaOk

    return [PSCustomObject]@{
        region = $Region
        vm = [PSCustomObject]@{
            sku = $VmSku
            family = $vmFamily
            requiredCores = $requiredVmCores
            current = $vmCurrent
            limit = $vmLimit
            available = $vmAvailable
            quotaOk = $vmQuotaOk
        }
        sqlManagedInstance = [PSCustomObject]@{
            requiredVCore = $RequiredSqlMiVCore
            currentVCore = $sqlVCoreCurrent
            limitVCore = $sqlVCoreLimit
            availableVCore = $sqlVCoreAvailable
            vCoreQuotaOk = $sqlVCoreQuotaOk
            requiredSubnets = $RequiredSqlMiSubnets
            currentSubnets = $sqlSubnetCurrent
            limitSubnets = $sqlSubnetLimit
            availableSubnets = $sqlSubnetAvailable
            subnetQuotaOk = $sqlSubnetQuotaOk
        }
        canDeploy = $canDeploy
        error = $null
    }
}

if (($null -eq $Regions -or $Regions.Count -eq 0) -and [string]::IsNullOrWhiteSpace($Region)) {
    throw 'Provide either -Region or -Regions.'
}

$targetRegionsRaw = @()
if ($null -ne $Regions -and $Regions.Count -gt 0) {
    $targetRegionsRaw += $Regions
}
if (-not [string]::IsNullOrWhiteSpace($Region)) {
    $targetRegionsRaw += $Region
}

$targetRegions = @(
    $targetRegionsRaw |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

# Set subscription context first so all lookups use the same scope.
& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Unable to set subscription context to '$SubscriptionId'."
}

$results = @()
foreach ($targetRegion in $targetRegions) {
    try {
        $results += Test-RegionDeployability -SubscriptionId $SubscriptionId -Region $targetRegion -VmSku $VmSku -RequiredSqlMiVCore $RequiredSqlMiVCore -RequiredSqlMiSubnets $RequiredSqlMiSubnets
    }
    catch {
        $results += [PSCustomObject]@{
            region = $targetRegion
            vm = $null
            sqlManagedInstance = $null
            canDeploy = $false
            error = $_.Exception.Message
        }
    }
}

$summary = [PSCustomObject]@{
    subscriptionId = $SubscriptionId
    checkedRegions = $targetRegions
    vmSku = $VmSku
    requiredSqlMiVCore = $RequiredSqlMiVCore
    requiredSqlMiSubnets = $RequiredSqlMiSubnets
    deployableRegions = @($results | Where-Object { $_.canDeploy } | ForEach-Object { $_.region })
    canDeployAnyRegion = ($results | Where-Object { $_.canDeploy } | Measure-Object).Count -gt 0
    results = $results
}

if ($OutputJson) {
    $summary | ConvertTo-Json -Depth 6
    return
}

Write-Host ""
Write-Host "Subscription : $SubscriptionId"
Write-Host "VM SKU       : $VmSku"
Write-Host ""

$tableRows = $results | ForEach-Object {
    $vmStatus    = if ($null -eq $_.vm)                { '?' } elseif ($_.vm.quotaOk)                         { 'OK' } else { 'FAIL' }
    $vcoreStatus = if ($null -eq $_.sqlManagedInstance) { '?' } elseif ($_.sqlManagedInstance.vCoreQuotaOk)   { 'OK' } else { 'FAIL' }
    $subnetStatus= if ($null -eq $_.sqlManagedInstance) { '?' } elseif ($_.sqlManagedInstance.subnetQuotaOk)  { 'OK' } else { 'FAIL' }
    $deploy      = if ($_.canDeploy) { 'YES' } else { 'NO' }
    $vmDetail    = if ($null -ne $_.vm)                { "$($_.vm.available) avail / $($_.vm.limit) limit" }  else { $_.error }
    $vcoreDetail = if ($null -ne $_.sqlManagedInstance) { "$($_.sqlManagedInstance.availableVCore) avail / $($_.sqlManagedInstance.limitVCore) limit" } else { '' }
    $subnetDetail= if ($null -ne $_.sqlManagedInstance) { "$($_.sqlManagedInstance.availableSubnets) avail / $($_.sqlManagedInstance.limitSubnets) limit" } else { '' }

    [PSCustomObject]@{
        Region       = $_.region
        'VM Quota'   = "$vmStatus ($vmDetail)"
        'MI vCores'  = "$vcoreStatus ($vcoreDetail)"
        'MI Subnets' = "$subnetStatus ($subnetDetail)"
        Deployable   = $deploy
    }
}

$tableRows | Format-Table -AutoSize

$deployable = @($results | Where-Object { $_.canDeploy } | ForEach-Object { $_.region })
if ($deployable.Count -gt 0) {
    Write-Host "Deployable region(s): $($deployable -join ', ')" -ForegroundColor Green
} else {
    Write-Host "No deployable regions found. Increase SQL MI quota via: https://aka.ms/sql-mi-obtain-larger-quota" -ForegroundColor Red
}
Write-Host ""
