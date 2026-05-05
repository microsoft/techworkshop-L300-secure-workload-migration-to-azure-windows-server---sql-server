param(
    [string]$SubscriptionId,

    [string]$Region,

    [string[]]$Regions,

    [Alias('VmSku')]
    [string[]]$VmSkus = @(
        'Standard_D4s_v4',
        'Standard_D4s_v5',
        'Standard_D4as_v5',
        'Standard_D4_v5',
        'Standard_D4a_v4',
        'Standard_D4d_v5',
        'Standard_D4ds_v5',
        'Standard_D4as_v4'
    ),

    [int]$RequiredSqlMiVCore = 4,

    [int]$RequiredSqlMiSubnets = 1,

    [switch]$ListSubscriptions,

    [switch]$Parallel,

    [ValidateRange(1, 32)]
    [int]$ThrottleLimit = 4,

    [switch]$NoProgress,

    [switch]$OutputJson
)

$ErrorActionPreference = 'Stop'

$DefaultRegions = @(
    'centralus',
    'eastus2',
    'francecentral',
    'northcentralus',
    'swedencentral',
    'westus',
    'westus3'
)

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

function Get-SubscriptionContext {
    param(
        [switch]$IncludeAll
    )

    $current = Invoke-AzCliJson -Arguments @('account', 'show', '--output', 'json')
    if ($null -eq $current) {
        throw "Could not read Azure account context. Run 'az login' first."
    }

    $all = @()
    if ($IncludeAll) {
        $all = Invoke-AzCliJson -Arguments @('account', 'list', '--all', '--output', 'json')
        if ($null -eq $all) {
            $all = @()
        }
    }

    return [PSCustomObject]@{
        Current = $current
        All = @($all)
    }
}

function Get-TenantNameMap {
    $tenantMap = @{}

    $tenants = Invoke-AzCliJson -Arguments @('account', 'tenant', 'list', '--output', 'json')
    if ($null -eq $tenants) {
        return $tenantMap
    }

    foreach ($tenant in $tenants) {
        if ([string]::IsNullOrWhiteSpace($tenant.tenantId)) {
            continue
        }

        $name = $tenant.displayName
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = $tenant.defaultDomain
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = 'Unknown'
        }

        $tenantMap[$tenant.tenantId] = $name
    }

    return $tenantMap
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
        [string[]]$VmSkus,

        [Parameter(Mandatory = $true)]
        [int]$RequiredSqlMiVCore,

        [Parameter(Mandatory = $true)]
        [int]$RequiredSqlMiSubnets
    )

    $vmUsageAll = Invoke-AzCliJson -Arguments @(
        'vm', 'list-usage',
        '--location', $Region,
        '--output', 'json'
    )

    if ($null -eq $vmUsageAll) {
        throw "Could not read VM quota usage in '$Region'."
    }

    $vmUsageByFamily = @{}
    foreach ($usageEntry in $vmUsageAll) {
        if ($null -ne $usageEntry.name -and -not [string]::IsNullOrWhiteSpace($usageEntry.name.value)) {
            $vmUsageByFamily[$usageEntry.name.value] = $usageEntry
        }
    }

    $vmChecks = @()
    $selectedVm = $null

    foreach ($vmSku in $VmSkus) {
        $vmSkuRecord = Invoke-AzCliJson -Arguments @(
            'vm', 'list-skus',
            '--location', $Region,
            '--resource-type', 'virtualMachines',
            '--size', $vmSku,
            '--all',
            '--query', "[?name=='$vmSku'] | [0].{family:family, capabilities:capabilities}",
            '--output', 'json'
        )

        if ($null -eq $vmSkuRecord) {
            $vmChecks += [PSCustomObject]@{
                sku = $vmSku
                family = $null
                requiredCores = $null
                current = $null
                limit = $null
                available = $null
                quotaOk = $false
            }
            continue
        }

        $vmFamily = $vmSkuRecord.family
        $requiredVmCoresRaw = Get-CapabilityValue -Capabilities $vmSkuRecord.capabilities -Name 'vCPUs'

        if ([string]::IsNullOrWhiteSpace($vmFamily) -or [string]::IsNullOrWhiteSpace($requiredVmCoresRaw)) {
            $vmChecks += [PSCustomObject]@{
                sku = $vmSku
                family = $vmFamily
                requiredCores = $null
                current = $null
                limit = $null
                available = $null
                quotaOk = $false
            }
            continue
        }

        $requiredVmCores = [int]$requiredVmCoresRaw
        $vmUsage = $vmUsageByFamily[$vmFamily]

        if ($null -eq $vmUsage) {
            $vmChecks += [PSCustomObject]@{
                sku = $vmSku
                family = $vmFamily
                requiredCores = $requiredVmCores
                current = $null
                limit = $null
                available = $null
                quotaOk = $false
            }
            continue
        }

        $vmCurrent = [double]$vmUsage.currentValue
        $vmLimit = [double]$vmUsage.limit
        $vmAvailable = $vmLimit - $vmCurrent
        $vmQuotaOk = $vmAvailable -ge $requiredVmCores

        $vmResult = [PSCustomObject]@{
            sku = $vmSku
            family = $vmFamily
            requiredCores = $requiredVmCores
            current = $vmCurrent
            limit = $vmLimit
            available = $vmAvailable
            quotaOk = $vmQuotaOk
        }

        $vmChecks += $vmResult

        if ($vmQuotaOk) {
            $selectedVm = $vmResult
            break
        }
    }

    if ($null -eq $selectedVm) {
        $vmSummary = ($vmChecks | ForEach-Object {
            if ($null -eq $_.available) {
                "$($_.sku): no quota data"
            }
            else {
                "$($_.sku): $($_.available) available / need $($_.requiredCores)"
            }
        }) -join '; '

        return [PSCustomObject]@{
            region = $Region
            vm = if ($vmChecks.Count -gt 0) { $vmChecks[0] } else { $null }
            sqlManagedInstance = $null
            canDeploy = $false
            error = "Skipped SQL MI checks because no VM SKU from the provided list has sufficient quota. $vmSummary"
        }
    }

    $sqlUsage = Invoke-AzCliJson -Arguments @(
        'rest', '--method', 'get',
        '--url', "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Sql/locations/$Region/usages?api-version=2023-08-01-preview",
        '--output', 'json'
    )

    if ($null -eq $sqlUsage -or $null -eq $sqlUsage.value) {
        throw "Could not read SQL usage data for region '$Region'."
    }

    $sqlUsageByName = @{}
    foreach ($entry in $sqlUsage.value) {
        if ($null -ne $entry.name) {
            $sqlUsageByName[$entry.name] = $entry
        }
    }

    $vCoreQuota = $sqlUsageByName['VCoreQuota']
    $subnetQuota = $sqlUsageByName['SubnetQuota']

    if ($null -eq $vCoreQuota -or $null -eq $subnetQuota) {
        throw "Missing SQL MI quota counters (VCoreQuota/SubnetQuota) for '$Region'."
    }

    $sqlVCoreCurrent = [double]$vCoreQuota.properties.currentValue
    $sqlVCoreLimit = [double]$vCoreQuota.properties.limit
    $sqlVCoreAvailable = $sqlVCoreLimit - $sqlVCoreCurrent

    $sqlSubnetCurrent = [double]$subnetQuota.properties.currentValue
    $sqlSubnetLimit = [double]$subnetQuota.properties.limit
    $sqlSubnetAvailable = $sqlSubnetLimit - $sqlSubnetCurrent

    $sqlVCoreQuotaOk = $sqlVCoreAvailable -ge $RequiredSqlMiVCore
    $sqlSubnetQuotaOk = $sqlSubnetAvailable -ge $RequiredSqlMiSubnets
    $canDeploy = $selectedVm.quotaOk -and $sqlVCoreQuotaOk -and $sqlSubnetQuotaOk

    return [PSCustomObject]@{
        region = $Region
        vm = $selectedVm
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

$subscriptionContext = Get-SubscriptionContext -IncludeAll:$ListSubscriptions

if ($ListSubscriptions) {
    $tenantNameById = Get-TenantNameMap

    $subscriptionContext.All |
        ForEach-Object {
            $tenantName = $_.tenantDisplayName
            if ([string]::IsNullOrWhiteSpace($tenantName)) {
                $tenantName = $tenantNameById[$_.tenantId]
            }
            if ([string]::IsNullOrWhiteSpace($tenantName)) {
                $tenantName = $_.tenantDefaultDomain
            }
            if ([string]::IsNullOrWhiteSpace($tenantName)) {
                $tenantName = 'Unknown'
            }

            [PSCustomObject]@{
                id = $_.id
                name = $_.name
                isDefault = $_.isDefault
                state = $_.state
                tenantId = $_.tenantId
                tenantName = $tenantName
                user = $_.user.name
            }
        } |
        Sort-Object -Property @(
            @{ Expression = 'isDefault'; Descending = $true },
            @{ Expression = 'tenantName'; Descending = $false },
            @{ Expression = 'name'; Descending = $false }
        ) |
        Format-Table -AutoSize
    return
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = $subscriptionContext.Current.id
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    throw 'Could not determine subscription id. Provide -SubscriptionId or run az login.'
}

$targetRegionsRaw = @()
if ($null -ne $Regions -and $Regions.Count -gt 0) {
    $targetRegionsRaw += $Regions
}
if (-not [string]::IsNullOrWhiteSpace($Region)) {
    $targetRegionsRaw += $Region
}

if ($targetRegionsRaw.Count -eq 0) {
    $targetRegionsRaw = $DefaultRegions
}

$targetRegions = @(
    $targetRegionsRaw |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim().Trim('[', ']', '"', "'") } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

$showProgress = (-not $NoProgress) -and (-not $OutputJson)

# Set subscription context first so all lookups use the same scope.
& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Unable to set subscription context to '$SubscriptionId'."
}

$activeSubscription = Invoke-AzCliJson -Arguments @('account', 'show', '--output', 'json')
if ($null -eq $activeSubscription) {
    throw 'Could not read active subscription after setting context.'
}

$results = @()
$totalRegions = $targetRegions.Count

if ($Parallel -and $totalRegions -gt 1) {
    $pendingRegions = [System.Collections.Generic.Queue[string]]::new()
    foreach ($regionName in $targetRegions) {
        $pendingRegions.Enqueue($regionName)
    }

    $runningJobs = @()
    $jobRegionMap = @{}

    $regionCheckJobScript = {
        param(
            [string]$JobSubscriptionId,
            [string]$JobRegion,
            [string[]]$JobVmSkus,
            [int]$JobRequiredSqlMiVCore,
            [int]$JobRequiredSqlMiSubnets
        )

        $ErrorActionPreference = 'Stop'

        function Invoke-AzCliJsonJob {
            param([string[]]$Arguments)

            $result = & az @Arguments
            if ($LASTEXITCODE -ne 0) {
                throw "Azure CLI command failed: az $($Arguments -join ' ')"
            }

            if ([string]::IsNullOrWhiteSpace($result)) {
                return $null
            }

            return $result | ConvertFrom-Json
        }

        function Get-CapabilityValueJob {
            param([object[]]$Capabilities, [string]$Name)

            $item = $Capabilities | Where-Object { $_.name -eq $Name } | Select-Object -First 1
            if ($null -eq $item) {
                return $null
            }

            return $item.value
        }

        $vmUsageAll = Invoke-AzCliJsonJob -Arguments @(
            'vm', 'list-usage',
            '--subscription', $JobSubscriptionId,
            '--location', $JobRegion,
            '--output', 'json'
        )

        if ($null -eq $vmUsageAll) {
            throw "Could not read VM quota usage in '$JobRegion'."
        }

        $vmUsageByFamily = @{}
        foreach ($usageEntry in $vmUsageAll) {
            if ($null -ne $usageEntry.name -and -not [string]::IsNullOrWhiteSpace($usageEntry.name.value)) {
                $vmUsageByFamily[$usageEntry.name.value] = $usageEntry
            }
        }

        $vmChecks = @()
        $selectedVm = $null

        foreach ($vmSku in $JobVmSkus) {
            $vmSkuRecord = Invoke-AzCliJsonJob -Arguments @(
                'vm', 'list-skus',
                '--subscription', $JobSubscriptionId,
                '--location', $JobRegion,
                '--resource-type', 'virtualMachines',
                '--size', $vmSku,
                '--all',
                '--query', "[?name=='$vmSku'] | [0].{family:family, capabilities:capabilities}",
                '--output', 'json'
            )

            if ($null -eq $vmSkuRecord) {
                $vmChecks += [PSCustomObject]@{
                    sku = $vmSku
                    family = $null
                    requiredCores = $null
                    current = $null
                    limit = $null
                    available = $null
                    quotaOk = $false
                }
                continue
            }

            $vmFamily = $vmSkuRecord.family
            $requiredVmCoresRaw = Get-CapabilityValueJob -Capabilities $vmSkuRecord.capabilities -Name 'vCPUs'
            if ([string]::IsNullOrWhiteSpace($vmFamily) -or [string]::IsNullOrWhiteSpace($requiredVmCoresRaw)) {
                $vmChecks += [PSCustomObject]@{
                    sku = $vmSku
                    family = $vmFamily
                    requiredCores = $null
                    current = $null
                    limit = $null
                    available = $null
                    quotaOk = $false
                }
                continue
            }

            $requiredVmCores = [int]$requiredVmCoresRaw
            $vmUsage = $vmUsageByFamily[$vmFamily]
            if ($null -eq $vmUsage) {
                $vmChecks += [PSCustomObject]@{
                    sku = $vmSku
                    family = $vmFamily
                    requiredCores = $requiredVmCores
                    current = $null
                    limit = $null
                    available = $null
                    quotaOk = $false
                }
                continue
            }

            $vmCurrent = [double]$vmUsage.currentValue
            $vmLimit = [double]$vmUsage.limit
            $vmAvailable = $vmLimit - $vmCurrent
            $vmQuotaOk = $vmAvailable -ge $requiredVmCores

            $vmResult = [PSCustomObject]@{
                sku = $vmSku
                family = $vmFamily
                requiredCores = $requiredVmCores
                current = $vmCurrent
                limit = $vmLimit
                available = $vmAvailable
                quotaOk = $vmQuotaOk
            }

            $vmChecks += $vmResult

            if ($vmQuotaOk) {
                $selectedVm = $vmResult
                break
            }
        }

        if ($null -eq $selectedVm) {
            $vmSummary = ($vmChecks | ForEach-Object {
                if ($null -eq $_.available) {
                    "$($_.sku): no quota data"
                }
                else {
                    "$($_.sku): $($_.available) available / need $($_.requiredCores)"
                }
            }) -join '; '

            return [PSCustomObject]@{
                region = $JobRegion
                vm = if ($vmChecks.Count -gt 0) { $vmChecks[0] } else { $null }
                sqlManagedInstance = $null
                canDeploy = $false
                error = "Skipped SQL MI checks because no VM SKU from the provided list has sufficient quota. $vmSummary"
            }
        }

        $sqlUsage = Invoke-AzCliJsonJob -Arguments @(
            'rest', '--method', 'get',
            '--url', "https://management.azure.com/subscriptions/$JobSubscriptionId/providers/Microsoft.Sql/locations/$JobRegion/usages?api-version=2023-08-01-preview",
            '--output', 'json'
        )

        if ($null -eq $sqlUsage -or $null -eq $sqlUsage.value) {
            throw "Could not read SQL usage data for region '$JobRegion'."
        }

        $sqlUsageByName = @{}
        foreach ($entry in $sqlUsage.value) {
            if ($null -ne $entry.name) {
                $sqlUsageByName[$entry.name] = $entry
            }
        }

        $vCoreQuota = $sqlUsageByName['VCoreQuota']
        $subnetQuota = $sqlUsageByName['SubnetQuota']
        if ($null -eq $vCoreQuota -or $null -eq $subnetQuota) {
            throw "Missing SQL MI quota counters (VCoreQuota/SubnetQuota) for '$JobRegion'."
        }

        $sqlVCoreCurrent = [double]$vCoreQuota.properties.currentValue
        $sqlVCoreLimit = [double]$vCoreQuota.properties.limit
        $sqlVCoreAvailable = $sqlVCoreLimit - $sqlVCoreCurrent

        $sqlSubnetCurrent = [double]$subnetQuota.properties.currentValue
        $sqlSubnetLimit = [double]$subnetQuota.properties.limit
        $sqlSubnetAvailable = $sqlSubnetLimit - $sqlSubnetCurrent

        $sqlVCoreQuotaOk = $sqlVCoreAvailable -ge $JobRequiredSqlMiVCore
        $sqlSubnetQuotaOk = $sqlSubnetAvailable -ge $JobRequiredSqlMiSubnets
        $canDeploy = $selectedVm.quotaOk -and $sqlVCoreQuotaOk -and $sqlSubnetQuotaOk

        return [PSCustomObject]@{
            region = $JobRegion
            vm = $selectedVm
            sqlManagedInstance = [PSCustomObject]@{
                requiredVCore = $JobRequiredSqlMiVCore
                currentVCore = $sqlVCoreCurrent
                limitVCore = $sqlVCoreLimit
                availableVCore = $sqlVCoreAvailable
                vCoreQuotaOk = $sqlVCoreQuotaOk
                requiredSubnets = $JobRequiredSqlMiSubnets
                currentSubnets = $sqlSubnetCurrent
                limitSubnets = $sqlSubnetLimit
                availableSubnets = $sqlSubnetAvailable
                subnetQuotaOk = $sqlSubnetQuotaOk
            }
            canDeploy = $canDeploy
            error = $null
        }
    }

    function Start-RegionJob {
        param([string]$RegionName)

        return Start-Job -ScriptBlock $regionCheckJobScript -ArgumentList $SubscriptionId, $RegionName, $VmSkus, $RequiredSqlMiVCore, $RequiredSqlMiSubnets
    }

    while ($runningJobs.Count -lt $ThrottleLimit -and $pendingRegions.Count -gt 0) {
        $regionName = $pendingRegions.Dequeue()
        $job = Start-RegionJob -RegionName $regionName

        $runningJobs += $job
        $jobRegionMap[$job.Id] = $regionName
    }

    while ($runningJobs.Count -gt 0) {
        $completed = $totalRegions - $pendingRegions.Count - $runningJobs.Count
        if ($showProgress) {
            $percentComplete = [int]($completed * 100 / [Math]::Max(1, $totalRegions))
            Write-Progress -Activity 'Precheck quota by region (parallel)' -Status "$completed/$totalRegions complete, $($runningJobs.Count) running" -PercentComplete $percentComplete
        }

        $doneJob = Wait-Job -Job $runningJobs -Any -Timeout 1
        if ($null -eq $doneJob) {
            continue
        }

        $doneRegion = $jobRegionMap[$doneJob.Id]
        try {
            $childResult = Receive-Job -Job $doneJob -ErrorAction Stop |
                Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName, PSSourceJobInstanceId
            if ($null -eq $childResult) {
                throw "No result returned from job."
            }

            $results += $childResult
        }
        catch {
            $results += [PSCustomObject]@{
                region = $doneRegion
                vm = $null
                sqlManagedInstance = $null
                canDeploy = $false
                error = $_.Exception.Message
            }
        }
        finally {
            Remove-Job -Job $doneJob -Force | Out-Null
            $runningJobs = @($runningJobs | Where-Object { $_.Id -ne $doneJob.Id })
            $jobRegionMap.Remove($doneJob.Id) | Out-Null
        }

        while ($runningJobs.Count -lt $ThrottleLimit -and $pendingRegions.Count -gt 0) {
            $regionName = $pendingRegions.Dequeue()
            $job = Start-RegionJob -RegionName $regionName

            $runningJobs += $job
            $jobRegionMap[$job.Id] = $regionName
        }
    }
}
else {
    $regionIndex = 0
    foreach ($targetRegion in $targetRegions) {
        $regionIndex++

        if ($showProgress) {
            $percentComplete = [int](($regionIndex - 1) * 100 / [Math]::Max(1, $totalRegions))
            Write-Progress -Activity 'Precheck quota by region' -Status "Checking $targetRegion ($regionIndex/$totalRegions)" -PercentComplete $percentComplete
        }

        try {
            $results += Test-RegionDeployability -SubscriptionId $SubscriptionId -Region $targetRegion -VmSkus $VmSkus -RequiredSqlMiVCore $RequiredSqlMiVCore -RequiredSqlMiSubnets $RequiredSqlMiSubnets
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
}

if ($showProgress) {
    Write-Progress -Activity 'Precheck quota by region' -Completed
}

$results = @(
    $results |
        Sort-Object { [Array]::IndexOf($targetRegions, $_.region) }
)

$summary = [PSCustomObject]@{
    subscriptionId = $SubscriptionId
    subscriptionName = $activeSubscription.name
    checkedRegions = $targetRegions
    vmSkus = $VmSkus
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
Write-Host "Subscription : $($activeSubscription.name) ($($activeSubscription.id))"
Write-Host "VM SKUs      : $($VmSkus -join ', ')"
Write-Host ""

$tableRows = $results | ForEach-Object {
    $vmStatus    = if ($null -eq $_.vm)                { '?' } elseif ($_.vm.quotaOk)                         { 'OK' } else { 'FAIL' }
    $vcoreStatus = if ($null -eq $_.sqlManagedInstance) { '?' } elseif ($_.sqlManagedInstance.vCoreQuotaOk)   { 'OK' } else { 'FAIL' }
    $subnetStatus= if ($null -eq $_.sqlManagedInstance) { '?' } elseif ($_.sqlManagedInstance.subnetQuotaOk)  { 'OK' } else { 'FAIL' }
    $deploy      = if ($_.canDeploy) { 'YES' } else { 'NO' }
    $vmDetail    = if ($null -eq $_.vm) { $_.error } elseif ($null -eq $_.vm.available) { $_.error } else { "$($_.vm.available) avail / $($_.vm.limit) limit" }
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
