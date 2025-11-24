<# 
 What does this script do?
	- Creates Backup, Data and Logs directories
	- Sets SQL Configs: Directories made as defaults, Enables TCP, Eables Mixed Authentication SA Account
	- Downloads the Customer360 Database as a Backup Device, then Restores the Database
	- Adds the Domain Built-In Administrators to the SYSADMIN group
	- Changes to Recovery type of the DB to "Full Recovery" and then performs a Backup to meet the requirements of AOG
	- Opens three Firewall ports in support of the AOG:  1433 (default SQL), 5022 (HADR Listener), 59999 (Internal Loadbalacer Probe)
#>

Configuration Main {
    Param(
        [Parameter(Mandatory)]
        [String]$DbBackupFileUrl,

        [Parameter(Mandatory)]
        [String]$DatabasePassword,
        
        [Parameter(Mandatory)]
        [String]$ArcOnboardingScriptUrl,

        [Parameter(Mandatory)]
        [String]$Location
        #>
    )
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

    Node "localhost" {
        # Disable the Server Manager from starting on login
        Script DisableServerManager {
            GetScript = {
                $task = Get-ScheduledTask -TaskName 'ServerManager'
                @{ Result = $task.State }
            }
            TestScript = {
                $task = Get-ScheduledTask -TaskName 'ServerManager'
                return ($task.State -eq 'Disabled')
            }
            SetScript = {
                Get-ScheduledTask -TaskName 'ServerManager' | Disable-ScheduledTask -ErrorAction SilentlyContinue
                Write-Verbose "Server Manager scheduled task disabled..."
            }
        }

        # Disable Microsoft Edge features
        Script DisableEdgeFeatures {
            GetScript = {
                $EdgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"

                if (Test-Path $EdgePolicyPath) {
                    $props = Get-ItemProperty -Path $EdgePolicyPath -ErrorAction SilentlyContinue
                    @{
                        HideFirstRunExperience       = $props.HideFirstRunExperience
                        DefaultBrowserSettingEnabled = $props.DefaultBrowserSettingEnabled
                        HubsSidebarEnabled           = $props.HubsSidebarEnabled
                    }
                }
                else { @{ Result = "Edge policy key not present" } }
            }
            TestScript = {
                $EdgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
                if (-not (Test-Path $EdgePolicyPath)) { return $false }

                $props = Get-ItemProperty -Path $EdgePolicyPath -ErrorAction SilentlyContinue
                return (
                    ($props.HideFirstRunExperience -eq 1) -and
                    ($props.DefaultBrowserSettingEnabled -eq 0) -and
                    ($props.HubsSidebarEnabled -eq 0)
                )
            }
            SetScript = {
                $EdgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
                if (-not (Test-Path $EdgePolicyPath)) {
                    New-Item -Path $EdgePolicyPath -Force | Out-Null
                }

                Set-ItemProperty -Path $EdgePolicyPath -Name "HideFirstRunExperience" -Type DWord -Value 1 -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $EdgePolicyPath -Name "DefaultBrowserSettingEnabled" -Type DWord -Value 0 -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $EdgePolicyPath -Name "HubsSidebarEnabled" -Type DWord -Value 0 -ErrorAction SilentlyContinue
                Write-Verbose "Microsoft Edge First Run Experience disabled."
            }
        }

        # Ensure directories exist
        foreach ($dirName in @('Logs','Data','Backup')) {
            File ("${dirName}_Directory") {
                Ensure          = 'Present'
                Type            = 'Directory'
                DestinationPath = "C:\Database\$dirName"
            }
        }

        Script InstallSqlServerModule {
            GetScript = {
                $module = Get-Module -ListAvailable -Name SqlServer
                @{ Result = if ($module) { "SqlServer available" } else { "SqlServer missing" } }
            }
            TestScript = {
                (Get-Module -ListAvailable -Name SqlServer) -ne $null
            }
            SetScript = {
                Write-Verbose "Installing SqlServer PowerShell module..."
                if (-not (Get-Module -ListAvailable -Name SqlServer)) {
                    Install-Module -Name SqlServer -Force -Scope AllUsers -AllowClobber
                }
                Write-Verbose "SqlServer module installed or already present."
            }
        }

        # Ensure SQL service is running
        Service SqlService {
            Name        = 'MSSQLSERVER'
            StartupType = 'Automatic'
            State       = 'Running'
        }

        # Configure SQL defaults and Mixed Auth
        Script ConfigureSqlDefaults {
            DependsOn = '[Script]InstallSqlServerModule', '[Service]SqlService'
            GetScript = { @{ Result = "SQLDefaults" } }
            TestScript = {
                Import-Module SqlServer -ErrorAction Stop
                $server = New-Object Microsoft.SqlServer.Management.Smo.Server Localhost
                $loginModeOk = ($server.Settings.LoginMode -eq [Microsoft.SqlServer.Management.Smo.ServerLoginMode]::Mixed)
                $defaultsOk  = ($server.Settings.DefaultFile -eq "C:\Database\Data" -and
                                $server.Settings.DefaultLog -eq "C:\Database\Logs" -and
                                $server.Settings.BackupDirectory -eq "C:\Database\Backup")
                $loginModeOk -and $defaultsOk
            }
            SetScript = {
                Write-Verbose "Configuring SQL defaults and enabling Mixed Authentication..."
                Import-Module SqlServer -ErrorAction Stop
                $server = New-Object Microsoft.SqlServer.Management.Smo.Server Localhost
                $server.Settings.LoginMode = [Microsoft.SqlServer.Management.Smo.ServerLoginMode]::Mixed
                $server.Settings.DefaultFile = "C:\Database\Data"
                $server.Settings.DefaultLog = "C:\Database\Logs"
                $server.Settings.BackupDirectory = "C:\Database\Backup"
                $server.Alter()
                Write-Verbose "SQL defaults configured and Mixed Authentication enabled."
            }
        }

        # Enable TCP protocol
        Script EnableSqlTcp {
            DependsOn = '[Script]InstallSqlServerModule'
            GetScript = { @{ Result = "SqlTcp" } }
            TestScript = {
                Import-Module SqlServer -ErrorAction Stop
                $smo = 'Microsoft.SqlServer.Management.Smo.'
                $wmi = New-Object ($smo + 'Wmi.ManagedComputer')
                $uri = "ManagedComputer[@Name='" + (Get-Item env:\computername).Value + "']/ServerInstance[@Name='MSSQLSERVER']/ServerProtocol[@Name='Tcp']"
                $Tcp = $wmi.GetSmoObject($uri)
                $Tcp.IsEnabled
            }
            SetScript = {
                Write-Verbose "Enabling TCP protocol for SQL Server..."
                Import-Module SqlServer -ErrorAction Stop
                $smo = 'Microsoft.SqlServer.Management.Smo.'
                $wmi = New-Object ($smo + 'Wmi.ManagedComputer')
                $uri = "ManagedComputer[@Name='" + (Get-Item env:\computername).Value + "']/ServerInstance[@Name='MSSQLSERVER']/ServerProtocol[@Name='Tcp']"
                $Tcp = $wmi.GetSmoObject($uri)
                $Tcp.IsEnabled = $true
                $Tcp.Alter()
                Write-Verbose "TCP protocol for SQL Server enabled."
            }
        }

        # Enable Always On availability groups
        Script EnableAlwaysOn {
            DependsOn = '[Script]InstallSqlServerModule', '[Service]SqlService'
            GetScript = {
                $result = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled"
                @{ Result = $result.IsHadrEnabled }
            }
            TestScript = {
                $status = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled"
                ($status.IsHadrEnabled -eq 1)
            }
            SetScript = {
                Write-Verbose "Importing SqlServer module..."
                Import-Module SqlServer
                Write-Verbose "Enabling Always On Availability Groups..."
                Enable-SqlAlwaysOn -ServerInstance "Localhost" -Force
                Write-Verbose "Always On Availability Groups enabled. SQL service restart required."
            }
        }

        # Enable travel flags to improve replication performance
        Script EnableAgTraceFlags {
            GetScript = {
                $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\Parameters"
                $params = Get-ItemProperty -Path $regPath
                @{ Result = ($params.PSObject.Properties | Where-Object { $_.Name -like "SQLArg*" } | Select-Object -ExpandProperty Value) }
            }
            TestScript = {
                $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\Parameters"
                $params = Get-ItemProperty -Path $regPath
                ($params.PSObject.Properties.Value -contains "-T1800") -and
                ($params.PSObject.Properties.Value -contains "-T9567")
            }
            SetScript = {
                $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\Parameters"
                $params = Get-ItemProperty -Path $regPath
                $existing = $params.PSObject.Properties | Where-Object { $_.Name -like "SQLArg*" } | Select-Object -ExpandProperty Value
                $nextIndex = ($params.PSObject.Properties | Where-Object { $_.Name -like "SQLArg*" }).Count

                if (-not ($existing -contains "-T1800")) {
                    New-ItemProperty -Path $regPath -Name "SQLArg$nextIndex" -Value "-T1800" -PropertyType String -Force
                    $nextIndex++
                }
                if (-not ($existing -contains "-T9567")) {
                    New-ItemProperty -Path $regPath -Name "SQLArg$nextIndex" -Value "-T9567" -PropertyType String -Force
                }

                Write-Verbose "Trace flags added via registry. SQL Server service restart required."
            }
        }

        # Restart SQL Server service
        Script RestartSqlAfterConfig {
            DependsOn = '[Script]ConfigureSqlDefaults','[Script]EnableSqlTcp','[Script]EnableAlwaysOn'
            GetScript  = { @{ Result = "Restart required" } }
            TestScript = { $false }  # Always run
            SetScript  = {
                Write-Verbose "Restarting SQL Server service to apply configuration changes..."
                Restart-Service -Name 'MSSQLSERVER' -Force
            }
        }

        # Configure SA account
        Script ConfigureSqlSaAccount {
            DependsOn = '[Service]SqlService','[Script]RestartSqlAfterConfig'
            GetScript = {
                $result = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "SELECT name, is_disabled FROM sys.sql_logins WHERE name = 'sa'"
                @{ Result = $result }
            }
            TestScript = {
                $login = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "SELECT is_disabled FROM sys.sql_logins WHERE name = 'sa'"
                ($login.is_disabled -eq 0)
            }
            SetScript = {
                Write-Verbose "Enabling SA account and setting password..."
                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "ALTER LOGIN sa ENABLE"
                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "ALTER LOGIN sa WITH PASSWORD = '$using:DatabasePassword'"
                Write-Verbose "SA account enabled with new password."
            }
        }

        # Create a master key in the master database
        Script CreateMasterKey {
            DependsOn = '[Service]SqlService','[Script]RestartSqlAfterConfig'
            GetScript = {
                $result = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "SELECT name FROM sys.symmetric_keys WHERE name LIKE '%DatabaseMasterKey%'"
                @{ Result = $result }
            }

            TestScript = {
                $hasMasterKey = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "SELECT COUNT(*) AS KeyCount FROM sys.symmetric_keys WHERE name LIKE '%DatabaseMasterKey%'"
                ($hasMasterKey.KeyCount -gt 0)
            }
            SetScript = {
                Write-Verbose "Creating master key..."
                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$using:DatabasePassword'"
                Write-Verbose "Master key created."
            }
        }

        Script DownloadAzureRootCerts {
            GetScript = {
                $digicert = Test-Path "C:\certs\DigiCertGlobalRootG2.crt"
                $mscert   = Test-Path "C:\certs\Microsoft RSA Root Certificate Authority 2017.crt"
                @{ Result = "DigiCert=$digicert; Microsoft=$mscert" }
            }
            TestScript = {
                (Test-Path "C:\certs\DigiCertGlobalRootG2.crt") -and (Test-Path "C:\certs\Microsoft RSA Root Certificate Authority 2017.crt")
            }
            SetScript = {
                Write-Verbose "Downloading Azure trusted root certificates..."
                New-Item -ItemType Directory -Path "C:\certs" -Force | Out-Null

                Invoke-WebRequest `
                    -Uri "https://cacerts.digicert.com/DigiCertGlobalRootG2.crt" `
                    -OutFile "C:\certs\DigiCertGlobalRootG2.crt"

                Invoke-WebRequest `
                    -Uri "https://www.microsoft.com/pkiops/certs/Microsoft%20RSA%20Root%20Certificate%20Authority%202017.crt" `
                    -OutFile "C:\certs\Microsoft RSA Root Certificate Authority 2017.crt"

                Write-Verbose "Certificates downloaded to C:\certs."
            }
        }

        Script ImportAzureRootCerts {
            DependsOn = '[Service]SqlService', '[Script]DownloadAzureRootCerts'
            GetScript = {
                $result = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "SELECT name FROM sys.certificates WHERE name IN ('DigiCertPKI','MicrosoftPKI')"
                @{ Result = $result }
            }
            TestScript = {
                $certs = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "SELECT name FROM sys.certificates WHERE name IN ('DigiCertPKI','MicrosoftPKI')"
                ($certs.Count -eq 2)
            }
            SetScript = {
                Write-Verbose "Importing Azure-trusted root certificates into SQL Server..."
                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query @"
CREATE CERTIFICATE [DigiCertPKI] FROM FILE = 'C:\certs\DigiCertGlobalRootG2.crt';
DECLARE @CERTID int;
SELECT @CERTID = CERT_ID('DigiCertPKI');
EXEC sp_certificate_add_issuer @CERTID, N'*.database.windows.net';
"@

                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query @"
CREATE CERTIFICATE [MicrosoftPKI] FROM FILE = 'C:\certs\Microsoft RSA Root Certificate Authority 2017.crt';
DECLARE @CERTID int;
SELECT @CERTID = CERT_ID('MicrosoftPKI');
EXEC sp_certificate_add_issuer @CERTID, N'*.database.windows.net';
"@
                Write-Verbose "Certificates imported successfully."
            }
        }

        # Download database backup
        Script DownloadDbBackup {
            GetScript = {
                $backupFileName = Split-Path $using:DbBackupFileUrl -Leaf
                $dbDestination = "C:\$backupFileName"
                @{ Result = (Test-Path $dbDestination) }
            }
            TestScript = {
                $backupFileName = Split-Path $using:DbBackupFileUrl -Leaf
                $dbDestination = "C:\$backupFileName"
                Test-Path $dbDestination
            }
            SetScript = {
                $backupFileName = Split-Path $using:DbBackupFileUrl -Leaf
                $dbDestination = "C:\$backupFileName"
                Write-Verbose "Downloading database backup from $using:DbBackupFileUrl..."
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $using:DbBackupFileUrl -OutFile $dbDestination -ErrorAction Stop
                Write-Verbose "Database backup downloaded to $dbDestination."
            }
        }

        # Restore ToyStore database
        Script RestoreToyStore {
            DependsOn = '[Script]DownloadDbBackup', '[Service]SqlService'
            GetScript = {
                $dbExists = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    SELECT name FROM sys.databases WHERE name = 'ToyStore'"
                @{ Result = $dbExists }
            }
            TestScript = {
                $dbExists = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    SELECT name FROM sys.databases WHERE name = 'ToyStore'"
                $dbExists.Count -gt 0
            }
            SetScript = {
                $backupFileName = Split-Path $using:DbBackupFileUrl -Leaf
                $dbDestination = "C:\$backupFileName"
                Write-Verbose "Restoring ToyStore database..."
                $files = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    RESTORE FILELISTONLY FROM DISK = '$dbDestination'"
                $relocateFiles = @()
                foreach ($file in $files) {
                    if ($file.Type -eq 'D') {
                        $relocateFiles += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
                            $file.LogicalName, "C:\Database\Data\ToyStore.mdf")
                    }
                    elseif ($file.Type -eq 'L') {
                        $relocateFiles += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
                            $file.LogicalName, "C:\Database\Logs\ToyStore.ldf")
                    }
                }
                Restore-SqlDatabase -ServerInstance Localhost `
                    -Database ToyStore `
                    -BackupFile $dbDestination `
                    -RelocateFile $relocateFiles `
                    -ReplaceDatabase -Verbose

                Write-Verbose "ToyStore database restored."
            }
        }

        # Restore Customer360 database
        Script RestoreCustomer360 {
            DependsOn = '[Script]DownloadDbBackup', '[Service]SqlService'
            GetScript = {
                $dbExists = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    SELECT name FROM sys.databases WHERE name = 'Customer360'"
                @{ Result = $dbExists }
            }
            TestScript = {
                $dbExists = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    SELECT name FROM sys.databases WHERE name = 'Customer360'"
                $dbExists.Count -gt 0
            }
            SetScript = {
                $backupFileName = Split-Path $using:DbBackupFileUrl -Leaf
                $dbDestination = "C:\$backupFileName"
                Write-Verbose "Restoring Customer360 database..."
                $files = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    RESTORE FILELISTONLY FROM DISK = '$dbDestination'"
                $relocateFiles = @()
                foreach ($file in $files) {
                    if ($file.Type -eq 'D') {
                        $relocateFiles += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
                            $file.LogicalName, "C:\Database\Data\Customer360.mdf")
                    }
                    elseif ($file.Type -eq 'L') {
                        $relocateFiles += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
                            $file.LogicalName, "C:\Database\Logs\Customer360.ldf")
                    }
                }
                Restore-SqlDatabase -ServerInstance Localhost `
                    -Database Customer360 `
                    -BackupFile $dbDestination `
                    -RelocateFile $relocateFiles `
                    -ReplaceDatabase -Verbose

                Write-Verbose "Customer360 database restored."
            }
        }

        # Add built-in admins to SQL databases
        Script AddBuiltinAdmins {
            DependsOn = '[Script]RestoreCustomer360','[Script]RestoreToyStore'
            GetScript = {
                $loginExists = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    SELECT name FROM sys.server_principals WHERE name = 'BUILTIN\Administrators'"
                @{ Result = $loginExists }
            }
            TestScript = {
                $loginExists = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    SELECT name FROM sys.server_principals WHERE name = 'BUILTIN\Administrators'"
                $loginExists.Count -gt 0
            }
            SetScript = {
                Write-Verbose "Adding BUILTIN\Administrators to sysadmin role..."
                $loginExists = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    SELECT name FROM sys.server_principals WHERE name = 'BUILTIN\Administrators'"
                if (-not $loginExists) {
                    Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                        CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS"
                }
                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    ALTER SERVER ROLE sysadmin ADD MEMBER [BUILTIN\Administrators]"
                Write-Verbose "BUILTIN\Administrators added to sysadmin role."
            }
        }

        # Set FULL recovery mode on ToyStore database
        Script SetToyStoreRecoveryMode {
            DependsOn = '[Script]RestoreToyStore'
            GetScript = {
                $model = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    SELECT recovery_model_desc FROM sys.databases WHERE name = 'ToyStore'"
                @{ Result = $model }
            }
            TestScript = {
                $model = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    SELECT recovery_model_desc FROM sys.databases WHERE name = 'ToyStore'"
                $model.recovery_model_desc -eq 'FULL'
            }
            SetScript = {
                Write-Verbose "Setting ToyStore recovery model to FULL and running backup..."
                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -TrustServerCertificate -Query "
                    ALTER DATABASE ToyStore SET RECOVERY FULL"
                Backup-SqlDatabase -ServerInstance Localhost -Database ToyStore
                Write-Verbose "ToyStore recovery model set to FULL."
            }
        }

        # Set SIMPLE recovery mode on ToyStore database
        Script SetCustomer360RecoveryMode {
            DependsOn = '[Script]RestoreCustomer360'
            GetScript = {
                # Check current recovery model
                $query = "SELECT recovery_model_desc FROM sys.databases WHERE name = 'Customer360';"
                $result = Invoke-Sqlcmd -ServerInstance 'localhost' -Database 'master' -TrustServerCertificate -Query $query -ErrorAction SilentlyContinue
                @{ Result = $result.recovery_model_desc }
            }
            TestScript = {
                $query = "SELECT recovery_model_desc FROM sys.databases WHERE name = 'Customer360';"
                $result = Invoke-Sqlcmd -ServerInstance 'localhost' -Database 'master' -TrustServerCertificate -Query $query -ErrorAction SilentlyContinue
                return ($result.recovery_model_desc -eq 'SIMPLE')
            }
            SetScript = {
                Write-Verbose "Setting Customer360 recovery model to SIMPLE..."
                $query = "ALTER DATABASE [Customer360] SET RECOVERY SIMPLE;"
                Invoke-Sqlcmd -ServerInstance 'localhost' -Database 'master' -TrustServerCertificate -Query $query -ErrorAction Stop
                Write-Verbose "Customer360 recovery model set to SIMPLE."
            }
        }

        # Create full backup of ToyStore database
        Script BackupToyStoreDatabase {
            DependsOn = '[Script]RestoreToyStore'
            GetScript = {
                $backupPath = "C:\Database\Backup\ToyStore_full.bak"
                if (Test-Path $backupPath) {
                    @{ Result = "Backup exists at $backupPath" }
                } else {
                    @{ Result = "No backup found" }
                }
            }
            TestScript = {
                $backupPath = "C:\Database\Backup\ToyStore_full.bak"
                return (Test-Path $backupPath)
            }
            SetScript = {
                Write-Verbose "Performing full backup of ToyStore database..."
                $backupDir = "C:\Database\Backup"
                $backupPath = "$backupDir\ToyStore_full.bak"

                if (-not (Test-Path $backupDir)) {
                    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                }

                $query = "BACKUP DATABASE [ToyStore] TO DISK = N'$backupPath' WITH INIT, FORMAT, NAME = 'ToyStore-FullBackup';"
                Invoke-Sqlcmd -ServerInstance 'localhost' -Database 'master' -TrustServerCertificate -Query $query -ErrorAction Stop
                Write-Verbose "Full backup of ToyStore database completed."
            }
        }

        # AddFirewallRules
        Script AddFirewallRules {
            GetScript = { @{ Result = "FirewallRulesAdded" } }
            TestScript = { return $false }
            SetScript = {
                Write-Host "Configuring firewall rules for Arc, SQL, and AOG..."
                if (-not (Get-NetFirewallRule -Name "block_azure_imds" -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name block_azure_imds -DisplayName "Block Azure IMDS" -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254
                    Write-Verbose "Firewall rule added: Block Azure IMDS"
                }
                if (-not (Get-NetFirewallRule -Name "sql_server_inbound" -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name sql_server_inbound -DisplayName "SQL Server Inbound" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
                    Write-Host "Firewall rule added: SQL Server Inbound (1433)"
                }
                if (-not (Get-NetFirewallRule -Name "sql_server_outbound" -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name sql_server_outbound -DisplayName "SQL Server Outbound" -Direction Outbound -Protocol TCP -LocalPort 1433 -Action Allow -Profile Any
                    Write-Host "Firewall rule added: SQL Server Outbound (1433)"
                }
                if (-not (Get-NetFirewallRule -Name "sql_ag_endpoint_inbound" -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name sql_ag_endpoint_inbound -DisplayName "SQL AG Endpoint Inbound" -Direction Inbound -Profile Any -Action Allow -LocalPort 5022 -Protocol TCP
                    Write-Host "Firewall rule added: SQL AG Endpoint Inbound (5022)"
                }
                if (-not (Get-NetFirewallRule -Name "sql_ag_endpoint_outbound" -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name sql_ag_endpoint_outbound -DisplayName "SQL AG Endpoint Outbound" -Direction Outbound -Profile Any -Action Allow -LocalPort 5022 -Protocol TCP
                    Write-Host "Firewall rule added: SQL AG Endpoint Outbound (5022)"
                }
                if (-not (Get-NetFirewallRule -Name "sql_ag_lb_probe_inbound" -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name sql_ag_lb_probe_inbound -DisplayName "SQL AG Load Balancer Probe Port" -Direction Inbound -Protocol TCP -LocalPort 59999 -Action Allow
                    Write-Host "Firewall rule added: SQL AG Load Balancer Probe Port (59999)"
                }
                if (-not (Get-NetFirewallRule -Name "sql_tds_redirect_outbound" -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name sql_tds_redirect_outbound -DisplayName "SQL TDS Redirect Outbound" -Direction Outbound -Profile Any -Action Allow -LocalPort 11000-11999 -Protocol TCP
                    Write-Host "Firewall rule added: SQL TDS Redirect Outbound (11000-11999)"
                }
                if (-not (Get-NetFirewallRule -Name "azure_arc_outbound_https" -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name azure_arc_outbound_https -DisplayName "Azure Arc Outbound HTTPS" -Direction Outbound -Protocol TCP -LocalPort 443 -Action Allow -Profile Any
                    Write-Host "Firewall rule added: Azure Arc Outbound HTTPS (443)"
                }
            }
        }

        # Set environment variable to override the ARC on an Azure VM installation
        Script SetArcTestEnvVar {
            GetScript = {
                $val = [System.Environment]::GetEnvironmentVariable("MSFT_ARC_TEST",'Machine')
                @{ Result = $val }
            }
            TestScript = {
                [System.Environment]::GetEnvironmentVariable("MSFT_ARC_TEST",'Machine') -eq 'true'
            }
            SetScript = {
                Write-Verbose "Setting MSFT_ARC_TEST environment variable..."
                [System.Environment]::SetEnvironmentVariable("MSFT_ARC_TEST",'true',[System.EnvironmentVariableTarget]::Machine)
                Write-Verbose "MSFT_ARC_TEST environment variable set."
            }
        }

        # Download Arc onboarding script
        Script DownloadDbBackup {
            GetScript = {
                $arcOnboardingScriptFileName = Split-Path $using:ArcOnboardingScriptUrl -Leaf
                $dbDestination = "C:\scripts\$arcOnboardingScriptFileName"
                @{ Result = (Test-Path $dbDestination) }
            }
            TestScript = {
                $arcOnboardingScriptFileName = Split-Path $using:ArcOnboardingScriptUrl -Leaf
                $dbDestination = "C:\scripts\$arcOnboardingScriptFileName"
                Test-Path $dbDestination
            }
            SetScript = {
                $arcOnboardingScriptFileName = Split-Path $using:ArcOnboardingScriptUrl -Leaf
                $dbDestination = "C:\scripts\$arcOnboardingScriptFileName"
                Write-Verbose "Downloading Arc onboarding script from $using:ArcOnboardingScriptUrl..."
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $using:ArcOnboardingScriptUrl -OutFile $dbDestination -ErrorAction Stop
                Write-Verbose "Arc onboarding script downloaded to $dbDestination."
            }
        }

        # Disable Windows Azure guest agent to allow Azure Arc installation
        Script ScheduleDisableGuestAgent {
            DependsOn = '[Script]SetArcTestEnvVar'
            GetScript = {
                $task = Get-ScheduledTask -TaskName 'DisableGuestAgentAfterDSC' -ErrorAction SilentlyContinue
                if ($null -ne $task) { @{ Result = "Scheduled" } } else { @{ Result = "NotScheduled" } }
            }
            TestScript = {
                $task = Get-ScheduledTask -TaskName 'DisableGuestAgentAfterDSC' -ErrorAction SilentlyContinue
                return ($null -ne $task)
            }
            SetScript = {
                try {
                    Write-Verbose "Preparing path for scheduled task payload..."
                    $prepDir    = 'C:\ArcPrep'
                    $scriptPath = Join-Path $prepDir 'DisableGuestAgent.ps1'

                    if (-not (Test-Path -LiteralPath $prepDir)) {
                        New-Item -Path $prepDir -ItemType Directory -Force | Out-Null
                    }

                    # Write payload script
                    @"
Start-Transcript -Path 'C:\ArcPrep\DisableGuestAgent.log' -Append
try {
    Write-Output 'Disabling WindowsAzureGuestAgent...'
    Stop-Service WindowsAzureGuestAgent -Force -ErrorAction SilentlyContinue
    Set-Service WindowsAzureGuestAgent -StartupType Disabled
    Write-Output 'Guest Agent disabled.'
} catch {
    Write-Error "Failed to disable Guest Agent: `$($_.Exception.Message)"
}
try {
    Write-Output 'Self-deleting scheduled task...'
    schtasks /Delete /TN 'DisableGuestAgentAfterDSC' /F | Out-Null
} catch {
    Write-Warning "Task self-delete failed: `$($_.Exception.Message)"
}
Stop-Transcript
"@ | Set-Content -Path $scriptPath -Encoding UTF8 -Force

                    Write-Verbose "Creating scheduled task to run payload..."
                    $taskAction    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
                    $taskTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
                    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
                    $taskSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

                    Register-ScheduledTask -TaskName 'DisableGuestAgentAfterDSC' `
                        -Action $taskAction `
                        -Trigger $taskTrigger `
                        -Principal $taskPrincipal `
                        -Settings $taskSettings -Force | Out-Null

                    Write-Verbose "Scheduled task created. It will disable Guest Agent and then delete itself."
                } catch {
                    Write-Error "Failed to schedule Guest Agent disable task: $($_.Exception.Message)"
                    throw
                }
            }
        }

        <#
        # Register SQL Server with Azure Arc after Guest Agent is disabled
        Script ScheduleRegisterSqlServerArc {
            DependsOn = '[Script]ScheduleDisableGuestAgent'
            GetScript = {
                $task = Get-ScheduledTask -TaskName 'RegisterSqlServerArcAfterDSC' -ErrorAction SilentlyContinue
                if ($null -ne $task) { @{ Result = "Scheduled" } } else { @{ Result = "NotScheduled" } }
            }
            TestScript = {
                $task = Get-ScheduledTask -TaskName 'RegisterSqlServerArcAfterDSC' -ErrorAction SilentlyContinue
                return ($null -ne $task)
            }
            SetScript = {
                try {
                    Write-Verbose "Preparing scheduled task for SQL Server Arc registration..."

                    $arcOnboardingScriptFileName = Split-Path $using:ArcOnboardingScriptUrl -Leaf
                    $scriptPath = "C:\scripts\$arcOnboardingScriptFileName"

                    if (-not (Test-Path -LiteralPath $scriptPath)) {
                        throw "Registration script not found at $scriptPath"
                    }

                    # Define parameters (these should be securely parameterized in DSC configuration)
                    $servicePrincipalAppId    = $using:servicePrincipalAppId
                    $servicePrincipalTenantId = $using:servicePrincipalTenantId
                    $servicePrincipalSecret   = $using:servicePrincipalSecret

                    $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" " +
                                "-servicePrincipalAppId `"$using:ServicePrincipalAppId`" " +
                                "-servicePrincipalTenantId `"$using:ServicePrincipalTenantId`" " +
                                "-servicePrincipalSecret `"$using:ServicePrincipalSecret`" " +
                                "-tenantId `"$using:TenantId`" " +
                                "-subId `"$using:SubscriptionId`" " +
                                "-resourceGroup `"$using:ResourceGroup`" " +
                                "-location `"$using:Location`""

                    $taskAction    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argString
                    $taskTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3)  # run ~2 minutes after DisableGuestAgent
                    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
                    $taskSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

                    Register-ScheduledTask -TaskName 'RegisterSqlServerArcAfterDSC' `
                        -Action $taskAction `
                        -Trigger $taskTrigger `
                        -Principal $taskPrincipal `
                        -Settings $taskSettings -Force | Out-Null

                    Write-Verbose "Scheduled task created. It will run RegisterSqlServerArc.ps1 with parameters and then delete itself."

                    # Optional: add self-delete logic inside RegisterSqlServerArc.ps1
                    # schtasks /Delete /TN 'RegisterSqlServerArcAfterDSC' /F
                } catch {
                    Write-Error "Failed to schedule SQL Server Arc registration task: $($_.Exception.Message)"
                    throw
                }
            }
        }
        #>
    }
}
