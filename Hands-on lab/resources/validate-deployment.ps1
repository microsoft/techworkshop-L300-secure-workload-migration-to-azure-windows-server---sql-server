<#
.SYNOPSIS
    Validates that all resources for the Tailspin Toys lab deployment are present and healthy.

.DESCRIPTION
    The lab ARM/Bicep template (deploy.bicep) creates ~15 resources spanning networking,
    compute, SQL Managed Instance, Azure OpenAI and Bastion. Because of inter-dependencies
    (especially VNet subnet operations that block VNet peering), an Azure deployment may
    report `Failed` while most/all resources are actually provisioned correctly.

    This script inspects the resource group and reports the health of each expected
    component so you can decide whether to retry, repair, or proceed with the workshop.

    It checks:
      - Resource group existence and tags
      - Expected resources (VNets, peerings, subnets, Bastion, on-prem SQL VM + extension,
        SQL Managed Instance, storage account, Azure OpenAI account)
      - All 6 VNet peerings (state + sync level)
      - SQL MI state, FQDN, Entra-only authentication and Entra admin
      - SQL VM `SqlVmConfig` extension provisioning state
      - Optional: latest deployment record(s) on the resource group

    Repairs are NOT performed. The script returns exit code 0 when everything is healthy,
    1 when any check fails, so it can be used in CI / pipeline scenarios.

.PARAMETER ResourceGroup
    Resource group that hosts the lab. Default: rg-tailspin.

.PARAMETER SubscriptionId
    Optional. Subscription to use. Defaults to the current `az account` context.

.PARAMETER NamePrefix
    Optional. If you know the auto-generated resource name prefix (e.g. `tailspinabc123`)
    you can pass it. Otherwise the script auto-discovers it from `*-sqlmi` or `*-hub-vnet`
    resources inside the resource group.

.PARAMETER OutputJson
    Emit a machine-readable JSON summary instead of the human-friendly table output.

.PARAMETER SkipDeploymentHistory
    Skip listing the resource group deployment history (faster).

.EXAMPLE
    pwsh ./validate-deployment.ps1

.EXAMPLE
    pwsh ./validate-deployment.ps1 -ResourceGroup rg-tailspin -SubscriptionId 00000000-0000-0000-0000-000000000000

.EXAMPLE
    pwsh ./validate-deployment.ps1 -OutputJson | ConvertFrom-Json
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-tailspin',
    [string]$SubscriptionId,
    [string]$NamePrefix,
    [switch]$OutputJson,
    [switch]$SkipDeploymentHistory
)

$ErrorActionPreference = 'Stop'

# ---------- helpers ----------
function Write-Info($msg)    { if (-not $OutputJson) { Write-Host $msg -ForegroundColor Cyan } }
function Write-Pass($msg)    { if (-not $OutputJson) { Write-Host "  [PASS] $msg" -ForegroundColor Green } }
function Write-Fail($msg)    { if (-not $OutputJson) { Write-Host "  [FAIL] $msg" -ForegroundColor Red } }
function Write-Warn2($msg)   { if (-not $OutputJson) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow } }
function Write-Section($t)   { if (-not $OutputJson) { Write-Host "`n=== $t ===" -ForegroundColor White } }

function Invoke-AzJson {
    param([string[]]$AzArgs)
    # Capture stderr separately so CLI warnings (preview / deprecation) don't corrupt JSON.
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $raw = & az @AzArgs 2>$err
        if ($LASTEXITCODE -ne 0) { return $null }
        try { return ($raw | Out-String | ConvertFrom-Json) } catch { return $null }
    } finally {
        Remove-Item $err -ErrorAction SilentlyContinue
    }
}

# Result accumulator
$report = [ordered]@{
    resourceGroup     = $ResourceGroup
    subscriptionId    = $null
    namePrefix        = $null
    checks            = @()
    summary           = $null
    allHealthy        = $false
}

function Add-Check {
    param(
        [Parameter(Mandatory)] [string]$Category,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateSet('Pass','Fail','Warn','Skip')] [string]$Status,
        [string]$Detail = ''
    )
    $report.checks += [ordered]@{
        category = $Category
        name     = $Name
        status   = $Status
        detail   = $Detail
    }
    switch ($Status) {
        'Pass' { Write-Pass "$Name $Detail" }
        'Fail' { Write-Fail "$Name $Detail" }
        'Warn' { Write-Warn2 "$Name $Detail" }
        'Skip' { if (-not $OutputJson) { Write-Host "  [SKIP] $Name $Detail" -ForegroundColor DarkGray } }
    }
}

# ---------- prerequisites ----------
Write-Info "Lab deployment validator"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required but was not found on PATH."
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
}
$ctx = Invoke-AzJson @('account','show','-o','json')
if (-not $ctx) { throw "Not signed in to Azure. Run 'az login'." }
$report.subscriptionId = $ctx.id

Write-Info "Subscription : $($ctx.name) ($($ctx.id))"
Write-Info "Resource grp : $ResourceGroup"

# ---------- 1. Resource group ----------
Write-Section "Resource Group"
$rg = Invoke-AzJson @('group','show','-n',$ResourceGroup,'-o','json')
if (-not $rg) {
    Add-Check 'ResourceGroup' $ResourceGroup 'Fail' '(does not exist)'
    $report.allHealthy = $false
    $report.summary = 'Resource group not found.'
    if ($OutputJson) { $report | ConvertTo-Json -Depth 6 } else { Write-Host "`nFAILED" -ForegroundColor Red }
    exit 1
}
Add-Check 'ResourceGroup' $ResourceGroup 'Pass' "(location=$($rg.location), state=$($rg.properties.provisioningState))"

# ---------- 2. Auto-discover name prefix ----------
if (-not $NamePrefix) {
    $sqlmi = Invoke-AzJson @('resource','list','-g',$ResourceGroup,'--resource-type','Microsoft.Sql/managedInstances','--query','[0].name','-o','json')
    if ($sqlmi -and $sqlmi -match '^(.*?)-sqlmi$') { $NamePrefix = $matches[1] }
    if (-not $NamePrefix) {
        $hub = Invoke-AzJson @('resource','list','-g',$ResourceGroup,'--resource-type','Microsoft.Network/virtualNetworks','--query',"[?ends_with(name,'-hub-vnet')].name | [0]",'-o','json')
        if ($hub -and $hub -match '^(.*?)-hub-vnet$') { $NamePrefix = $matches[1] }
    }
}
if (-not $NamePrefix) {
    Add-Check 'ResourceGroup' 'NamePrefix' 'Fail' '(could not auto-discover; pass -NamePrefix tailspinXXXXXX)'
    if ($OutputJson) { $report | ConvertTo-Json -Depth 6 } else { Write-Host "`nFAILED" -ForegroundColor Red }
    exit 1
}
$report.namePrefix = $NamePrefix
Add-Check 'ResourceGroup' 'NamePrefix' 'Pass' "($NamePrefix)"

# ---------- 3. Expected resources ----------
Write-Section "Expected Resources"
$expected = @(
    @{ Name = "$NamePrefix-onprem-vnet";       Type = 'Microsoft.Network/virtualNetworks';      Required = $true  }
    @{ Name = "$NamePrefix-hub-vnet";          Type = 'Microsoft.Network/virtualNetworks';      Required = $true  }
    @{ Name = "$NamePrefix-spoke-vnet";        Type = 'Microsoft.Network/virtualNetworks';      Required = $true  }
    @{ Name = "$NamePrefix-hub-bastion";       Type = 'Microsoft.Network/bastionHosts';         Required = $true  }
    @{ Name = "$NamePrefix-hub-bastion-pip";   Type = 'Microsoft.Network/publicIPAddresses';    Required = $true  }
    @{ Name = "$NamePrefix-sqlmi-nsg";         Type = 'Microsoft.Network/networkSecurityGroups';Required = $true  }
    @{ Name = "$NamePrefix-sqlmi-rt";          Type = 'Microsoft.Network/routeTables';          Required = $true  }
    @{ Name = "$NamePrefix-sqlmi";             Type = 'Microsoft.Sql/managedInstances';         Required = $true  }
    @{ Name = "$($NamePrefix)sqlmistor";       Type = 'Microsoft.Storage/storageAccounts';      Required = $true  }
    @{ Name = "$NamePrefix-onprem-sql-vm";     Type = 'Microsoft.Compute/virtualMachines';      Required = $true  }
    @{ Name = "$NamePrefix-onprem-sql-nic";    Type = 'Microsoft.Network/networkInterfaces';    Required = $true  }
    @{ Name = "$NamePrefix-onprem-sql-nsg";    Type = 'Microsoft.Network/networkSecurityGroups';Required = $true  }
)

$rgResources = Invoke-AzJson @('resource','list','-g',$ResourceGroup,'-o','json')
$rgResourceMap = @{}
foreach ($r in $rgResources) { $rgResourceMap["$($r.type)/$($r.name)"] = $r }

foreach ($e in $expected) {
    $key = "$($e.Type)/$($e.Name)"
    if ($rgResourceMap.ContainsKey($key)) {
        $r = $rgResourceMap[$key]
        $state = $r.provisioningState
        if ($state -and $state -ne 'Succeeded') {
            Add-Check 'Resource' $e.Name 'Warn' "(type=$($e.Type), state=$state)"
        } else {
            Add-Check 'Resource' $e.Name 'Pass' "($($e.Type.Split('/')[-1]))"
        }
    } else {
        $status = if ($e.Required) { 'Fail' } else { 'Warn' }
        Add-Check 'Resource' $e.Name $status "(missing, expected $($e.Type))"
    }
}

# Optional Azure OpenAI account (name suffix is random)
$oai = $rgResources | Where-Object { $_.type -eq 'Microsoft.CognitiveServices/accounts' -and $_.name -like "$NamePrefix-oai-*" } | Select-Object -First 1
if ($oai) {
    Add-Check 'Resource' $oai.name 'Pass' "(Azure OpenAI)"
} else {
    Add-Check 'Resource' "$NamePrefix-oai-*" 'Warn' '(Azure OpenAI account not found — only required for AI modules)'
}

# ---------- 4. Subnets ----------
Write-Section "VNet subnets"
$subnetExpectations = @{
    "$NamePrefix-onprem-vnet" = @('default')
    "$NamePrefix-hub-vnet"    = @('hub','AzureBastionSubnet')
    "$NamePrefix-spoke-vnet"  = @('default','AzureSqlMI')
}
foreach ($vnet in $subnetExpectations.Keys) {
    $subs = Invoke-AzJson @('network','vnet','subnet','list','-g',$ResourceGroup,'--vnet-name',$vnet,'-o','json')
    if (-not $subs) {
        Add-Check 'Subnet' $vnet 'Fail' '(unable to list subnets)'
        continue
    }
    $present = $subs.name
    foreach ($want in $subnetExpectations[$vnet]) {
        if ($present -contains $want) {
            $s = $subs | Where-Object { $_.name -eq $want }
            Add-Check 'Subnet' "$vnet/$want" 'Pass' "(state=$($s.provisioningState))"
        } else {
            Add-Check 'Subnet' "$vnet/$want" 'Fail' '(missing)'
        }
    }
}

# ---------- 5. VNet peerings ----------
Write-Section "VNet peerings"
$peeringExpectations = @(
    @{ Vnet = "$NamePrefix-hub-vnet";    Name = 'hub-spoke';    Remote = "$NamePrefix-spoke-vnet"  }
    @{ Vnet = "$NamePrefix-spoke-vnet";  Name = 'spoke-hub';    Remote = "$NamePrefix-hub-vnet"    }
    @{ Vnet = "$NamePrefix-hub-vnet";    Name = 'hub-onprem';   Remote = "$NamePrefix-onprem-vnet" }
    @{ Vnet = "$NamePrefix-onprem-vnet"; Name = 'onprem-hub';   Remote = "$NamePrefix-hub-vnet"    }
    @{ Vnet = "$NamePrefix-spoke-vnet";  Name = 'spoke-onprem'; Remote = "$NamePrefix-onprem-vnet" }
    @{ Vnet = "$NamePrefix-onprem-vnet"; Name = 'onprem-spoke'; Remote = "$NamePrefix-spoke-vnet"  }
)
foreach ($p in $peeringExpectations) {
    $peer = Invoke-AzJson @('network','vnet','peering','show','-g',$ResourceGroup,'--vnet-name',$p.Vnet,'-n',$p.Name,'-o','json')
    if (-not $peer) {
        Add-Check 'Peering' "$($p.Vnet)/$($p.Name)" 'Fail' "(missing — should peer to $($p.Remote))"
        continue
    }
    $state  = $peer.peeringState
    $sync   = $peer.peeringSyncLevel
    if ($state -eq 'Connected' -and $sync -eq 'FullyInSync') {
        Add-Check 'Peering' "$($p.Vnet)/$($p.Name)" 'Pass' "(state=$state, sync=$sync)"
    } else {
        Add-Check 'Peering' "$($p.Vnet)/$($p.Name)" 'Fail' "(state=$state, sync=$sync — try: az network vnet peering sync -g $ResourceGroup --vnet-name $($p.Vnet) -n $($p.Name))"
    }
}

# ---------- 6. SQL Managed Instance ----------
Write-Section "SQL Managed Instance"
$miName = "$NamePrefix-sqlmi"
$mi = Invoke-AzJson @('sql','mi','show','-g',$ResourceGroup,'-n',$miName,'-o','json')
if (-not $mi) {
    Add-Check 'SqlMi' $miName 'Fail' '(not found)'
} else {
    if ($mi.state -eq 'Ready' -and $mi.provisioningState -eq 'Succeeded') {
        Add-Check 'SqlMi' "$miName state" 'Pass' "(state=$($mi.state))"
    } else {
        Add-Check 'SqlMi' "$miName state" 'Fail' "(state=$($mi.state), provisioningState=$($mi.provisioningState))"
    }
    Add-Check 'SqlMi' "$miName fqdn" 'Pass' "($($mi.fullyQualifiedDomainName))"

    $adAdmin = Invoke-AzJson @('sql','mi','ad-admin','list','-g',$ResourceGroup,'--mi',$miName,'-o','json')
    if ($adAdmin -and $adAdmin.Count -gt 0) {
        Add-Check 'SqlMi' 'EntraAdmin' 'Pass' "(login=$($adAdmin[0].login))"
    } else {
        Add-Check 'SqlMi' 'EntraAdmin' 'Warn' '(no Entra admin configured)'
    }

    $adOnly = Invoke-AzJson @('sql','mi','ad-only-auth','get','-g',$ResourceGroup,'-n',$miName,'-o','json')
    if ($adOnly) {
        if ($adOnly.azureAdOnlyAuthentication) {
            Add-Check 'SqlMi' 'EntraOnlyAuth' 'Pass' '(enabled)'
        } else {
            Add-Check 'SqlMi' 'EntraOnlyAuth' 'Warn' '(disabled — SQL auth is allowed)'
        }
    }
}

# ---------- 7. On-prem SQL VM + extension ----------
Write-Section "On-prem SQL VM"
$vmName = "$NamePrefix-onprem-sql-vm"
$vm = Invoke-AzJson @('vm','show','-g',$ResourceGroup,'-n',$vmName,'-d','-o','json')
if (-not $vm) {
    Add-Check 'Vm' $vmName 'Fail' '(not found)'
} else {
    if ($vm.provisioningState -eq 'Succeeded') {
        Add-Check 'Vm' "$vmName provisioning" 'Pass' "(powerState=$($vm.powerState))"
    } elseif ($vm.provisioningState -in @('Updating','Creating')) {
        Add-Check 'Vm' "$vmName provisioning" 'Warn' "(provisioningState=$($vm.provisioningState) — transient; re-run validator)"
    } else {
        Add-Check 'Vm' "$vmName provisioning" 'Fail' "(provisioningState=$($vm.provisioningState))"
    }
    $exts = Invoke-AzJson @('vm','extension','list','-g',$ResourceGroup,'--vm-name',$vmName,'-o','json')
    $sqlExt = $exts | Where-Object { $_.name -eq 'SqlVmConfig' } | Select-Object -First 1
    if ($sqlExt) {
        if ($sqlExt.provisioningState -eq 'Succeeded') {
            Add-Check 'Vm' 'SqlVmConfig extension' 'Pass' '(database restored)'
        } elseif ($sqlExt.provisioningState -in @('Updating','Creating')) {
            Add-Check 'Vm' 'SqlVmConfig extension' 'Warn' "(state=$($sqlExt.provisioningState) — transient)"
        } else {
            Add-Check 'Vm' 'SqlVmConfig extension' 'Fail' "(state=$($sqlExt.provisioningState))"
        }
    } else {
        Add-Check 'Vm' 'SqlVmConfig extension' 'Fail' '(missing)'
    }
}

# ---------- 8. Bastion ----------
Write-Section "Bastion"
$bastion = Invoke-AzJson @('network','bastion','show','-g',$ResourceGroup,'-n',"$NamePrefix-hub-bastion",'-o','json')
if ($bastion) {
    if ($bastion.provisioningState -eq 'Succeeded') {
        Add-Check 'Bastion' $bastion.name 'Pass' "(sku=$($bastion.sku.name))"
    } else {
        Add-Check 'Bastion' $bastion.name 'Fail' "(state=$($bastion.provisioningState))"
    }
} else {
    Add-Check 'Bastion' "$NamePrefix-hub-bastion" 'Fail' '(not found)'
}

# ---------- 9. Recent deployments ----------
if (-not $SkipDeploymentHistory) {
    Write-Section "Recent deployments (last 5)"
    $deps = Invoke-AzJson @('deployment','group','list','-g',$ResourceGroup,'--query','[].{name:name, state:properties.provisioningState, timestamp:properties.timestamp} | [0:5]','-o','json')
    if ($deps) {
        foreach ($d in $deps) {
            $status = if ($d.state -eq 'Succeeded') { 'Pass' } elseif ($d.state -eq 'Failed') { 'Warn' } else { 'Skip' }
            Add-Check 'Deployment' $d.name $status "(state=$($d.state), t=$($d.timestamp))"
        }
    } else {
        Add-Check 'Deployment' 'history' 'Skip' '(no deployments listed)'
    }
}

# ---------- summary ----------
$fails = ($report.checks | Where-Object { $_.status -eq 'Fail' }).Count
$warns = ($report.checks | Where-Object { $_.status -eq 'Warn' }).Count
$passes= ($report.checks | Where-Object { $_.status -eq 'Pass' }).Count
$report.summary    = "Pass=$passes Warn=$warns Fail=$fails"
$report.allHealthy = ($fails -eq 0)

if ($OutputJson) {
    $report | ConvertTo-Json -Depth 6
} else {
    Write-Host "`n=== Summary ===" -ForegroundColor White
    Write-Host "  Pass : $passes" -ForegroundColor Green
    Write-Host "  Warn : $warns" -ForegroundColor Yellow
    Write-Host "  Fail : $fails" -ForegroundColor Red
    if ($report.allHealthy) {
        Write-Host "`nLab deployment is HEALTHY." -ForegroundColor Green
    } else {
        Write-Host "`nLab deployment has issues. See [FAIL] items above." -ForegroundColor Red
        Write-Host "`nCommon repair tips:" -ForegroundColor White
        Write-Host "  - Missing/out-of-sync peering: re-create or run 'az network vnet peering sync'." -ForegroundColor Gray
        Write-Host "  - VM extension Failed: re-run 'az vm extension set ... --force-update'." -ForegroundColor Gray
        Write-Host "  - SQL MI Provisioning: this can take 4+ hours. Re-run validator later." -ForegroundColor Gray
    }
}

if (-not $report.allHealthy) { exit 1 } else { exit 0 }
