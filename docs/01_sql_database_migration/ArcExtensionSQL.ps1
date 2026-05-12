<#
.SYNOPSIS
    Onboards a (simulated) on-premises SQL Server VM to Azure Arc and installs the
    Azure Extension for SQL Server.

.DESCRIPTION
    This script is intended to be run on the lab's "on-prem" SQL Server VM. Because
    that VM is actually hosted in Azure for the purposes of this workshop, the standard
    Azure Connected Machine Agent refuses to install with the error:

        "Cannot install Azure Connected Machine agent on an Azure Virtual Machine.
         Azure Connected Machine Agent is designed for use outside Azure."

    To make the installer treat the machine as on-prem, this script:

      1. Sets the machine-level environment variable MSFT_ARC_TEST=true (documented
         workaround in https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine#step-by-step-guide).
      2. Adds a Windows Firewall outbound rule blocking access to the Azure IMDS
         endpoint (169.254.169.254) so the agent cannot detect that it is running
         on an Azure VM.

    Both steps are idempotent and safe to re-run.

.PARAMETER SubscriptionId
    Azure subscription id where the Arc-enabled server / SQL extension will be created.

.PARAMETER TenantId
    Microsoft Entra tenant id used by interactive (or service-principal) sign-in.

.PARAMETER ResourceGroup
    Resource group that will host the Arc-enabled machine resource.

.PARAMETER Location
    Azure region for the Arc machine resource (e.g. swedencentral, eastus).

.PARAMETER MachineName
    Optional. Name of the Arc machine resource. Defaults to 'TailspinSql' to match the lab.

.PARAMETER LicenseType
    Optional. SQL Server license type passed to the extension. Defaults to 'PAYG'.

.PARAMETER Proxy
    Optional. HTTP proxy URL (used for both the MSI download and the agent).

.PARAMETER ServicePrincipalAppId
.PARAMETER ServicePrincipalTenantId
.PARAMETER ServicePrincipalSecret
    Optional. Service principal credentials for unattended onboarding (registration-at-scale).
    See https://learn.microsoft.com/sql/sql-server/azure-arc/connect-at-scale.

.EXAMPLE
    pwsh ./ArcExtensionSQL.ps1 -SubscriptionId <sub> -TenantId <tenant> -ResourceGroup rg-tailspin -Location swedencentral
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$SubscriptionId,
    [Parameter(Mandatory = $true)] [string]$TenantId,
    [Parameter(Mandatory = $true)] [string]$ResourceGroup,
    [Parameter(Mandatory = $true)] [string]$Location,
    [string]$MachineName = 'TailspinSql',
    [ValidateSet('Paid','PAYG','LicenseOnly')]
    [string]$LicenseType = 'PAYG',
    [string]$Proxy = '',
    [string]$ServicePrincipalAppId,
    [string]$ServicePrincipalTenantId,
    [string]$ServicePrincipalSecret
)

$ErrorActionPreference = 'Stop'

$currentDir = Get-Location
$unattended = $ServicePrincipalAppId -and $ServicePrincipalTenantId -and $ServicePrincipalSecret

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Step 0. Allow Arc agent install on an Azure VM (lab-only workaround)
# Docs: https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine#step-by-step-guide
# ---------------------------------------------------------------------------
try {
    Write-Host "[1/3] Preparing host so Arc agent treats this VM as on-prem..." -ForegroundColor Cyan

    # (a) Tell the agent we know what we're doing (test/eval scenario).
    if ([Environment]::GetEnvironmentVariable('MSFT_ARC_TEST', 'Machine') -ne 'true') {
        [Environment]::SetEnvironmentVariable('MSFT_ARC_TEST', 'true', 'Machine')
        # Reflect into the current process so any child processes started below see it.
        $env:MSFT_ARC_TEST = 'true'
        Write-Host "      Set machine-level MSFT_ARC_TEST=true." -ForegroundColor Gray
    } else {
        Write-Host "      MSFT_ARC_TEST already set." -ForegroundColor Gray
    }

    # (b) Block outbound traffic to Azure IMDS so the agent cannot detect the Azure host.
    $imdsRuleName = 'BlockAzureIMDS'
    $existing = Get-NetFirewallRule -Name $imdsRuleName -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -Name $imdsRuleName `
            -DisplayName 'Block access to Azure IMDS (Arc onboarding workaround)' `
            -Enabled True -Profile Any -Direction Outbound `
            -Action Block -RemoteAddress 169.254.169.254 | Out-Null
        Write-Host "      Added firewall rule '$imdsRuleName' blocking 169.254.169.254." -ForegroundColor Gray
    } else {
        Write-Host "      Firewall rule '$imdsRuleName' already present." -ForegroundColor Gray
    }
}
catch {
    throw "Pre-flight setup failed (MSFT_ARC_TEST / IMDS block): $_"
}

# ---------------------------------------------------------------------------
# Step 1. Download the Azure Extension for SQL Server installer
# ---------------------------------------------------------------------------
try {
    Write-Host "[2/3] Downloading Azure Extension for SQL Server..." -ForegroundColor Cyan
    $iwrParams = @{ Uri = 'https://aka.ms/AzureExtensionForSQLServer'; OutFile = 'AzureExtensionForSQLServer.msi' }
    if ($Proxy) { $iwrParams['Proxy'] = $Proxy }
    Invoke-WebRequest @iwrParams
}
catch {
    throw "Invoke-WebRequest failed while downloading the MSI: $_"
}

# ---------------------------------------------------------------------------
# Step 2. Install the MSI and run the onboarding executable
# ---------------------------------------------------------------------------
try {
    Write-Host "[3/3] Installing and registering the SQL Server with Azure Arc..." -ForegroundColor Cyan

    $exitcode = (Start-Process -FilePath msiexec.exe `
        -ArgumentList @('/i', 'AzureExtensionForSQLServer.msi', '/l*v', 'installationlog.txt', '/qn') `
        -Wait -PassThru).ExitCode

    if ($exitcode -ne 0) {
        Write-Host -ForegroundColor Red "Installation failed: see $currentDir\installationlog.txt for details."
        return
    }

    $agent = "$env:ProgramW6432\AzureExtensionForSQLServer\AzureExtensionForSQLServer.exe"

    if ($unattended) {
        & $agent --subId $SubscriptionId `
                 --resourceGroup $ResourceGroup `
                 --location $Location `
                 --tenantid $ServicePrincipalTenantId `
                 --service-principal-app-id $ServicePrincipalAppId `
                 --service-principal-secret $ServicePrincipalSecret `
                 --proxy $Proxy `
                 --licenseType $LicenseType `
                 --machineName $MachineName
    } else {
        & $agent --subId $SubscriptionId `
                 --resourceGroup $ResourceGroup `
                 --location $Location `
                 --tenantid $TenantId `
                 --proxy $Proxy `
                 --licenseType $LicenseType `
                 --machineName $MachineName
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host -ForegroundColor Green "Azure Extension for SQL Server installed successfully."
        Write-Host -ForegroundColor Green "The SQL Server enabled by Azure Arc resource(s) will be visible in the Azure portal within a minute (newly started instances may take up to an hour)."
    } else {
        Write-Host -ForegroundColor Red "Failed to install Azure Extension for SQL Server. See $currentDir\AzureExtensionForSQLServerInstallation.log."
    }
}
catch {
    Write-Host -ForegroundColor Red $_.Exception
    throw
}