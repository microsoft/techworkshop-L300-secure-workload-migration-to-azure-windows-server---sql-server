<#
    Arc-enables a virtual machine.
#>
Configuration ArcConnect {
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

    Node "localhost" {
        # Disable the Server Manager from starting on login
        Script DisableServerManager {
            GetScript = {
                if (-not (Get-Module -Name ScheduledTasks)) {
                    Import-Module ScheduledTasks -ErrorAction Stop
                }
                # Return current state for reporting
                $task = Get-ScheduledTask -TaskName 'ServerManager' -ErrorAction SilentlyContinue
                @{ Result = $task.State }
            }
            TestScript = {
                if (-not (Get-Module -Name ScheduledTasks)) {
                    Import-Module ScheduledTasks -ErrorAction Stop
                }
                # Check if the task is already disabled
                $task = Get-ScheduledTask -TaskName 'ServerManager' -ErrorAction SilentlyContinue
                return ($task -and ($task.State -eq 'Disabled'))
            }
            SetScript = {
                if (-not (Get-Module -Name ScheduledTasks)) {
                    Import-Module ScheduledTasks -ErrorAction Stop
                }
                # Disable the Server Manager scheduled task
                Get-ScheduledTask -TaskName 'ServerManager' | Disable-ScheduledTask -ErrorAction SilentlyContinue
            }
        }

        # AddFirewallRules
        Script AddFirewallRules {
            GetScript = { @{ Result = "FirewallRulesAdded" } }
            TestScript = {
                $rule = Get-NetFirewallRule -Name "block_azure_imds" -ErrorAction SilentlyContinue
                return ($null -ne $rule)
            }
            SetScript = {
                Write-Verbose "Configuring firewall rules Arc..."
                if (-not (Get-NetFirewallRule -Name "block_azure_imds" -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name block_azure_imds -DisplayName "Block Azure IMDS" -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254 -Confirm:$false
                    Write-Verbose "Firewall rule added: Block Azure IMDS"
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
            }
        }

        # Disable Windows Azure guest agent to allow Azure Arc installation
        Script ScheduleDisableGuestAgent {
            DependsOn = '[Script]SetArcTestEnvVar'
            GetScript = {
                if (-not (Get-Module -Name ScheduledTasks)) {
                    Import-Module ScheduledTasks -ErrorAction Stop
                }
                $task = Get-ScheduledTask -TaskName 'DisableGuestAgentAfterDSC' -ErrorAction SilentlyContinue
                if ($null -ne $task) { @{ Result = "Scheduled" } } else { @{ Result = "NotScheduled" } }
            }
            TestScript = {
                if (-not (Get-Module -Name ScheduledTasks)) {
                    Import-Module ScheduledTasks -ErrorAction Stop
                }
                $task = Get-ScheduledTask -TaskName 'DisableGuestAgentAfterDSC' -ErrorAction SilentlyContinue
                return ($null -ne $task)
            }
            SetScript = {
                try {
                    Write-Verbose "Preparing path for scheduled task payload..."
                    if (-not (Get-Module -Name ScheduledTasks)) {
                        Import-Module ScheduledTasks -ErrorAction Stop
                    }
                    $prepDir    = 'C:\ArcPrep'
                    $scriptPath = Join-Path $prepDir 'DisableGuestAgent.ps1'

                    # Ensure directory exists
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
                    $taskTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)
                    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
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
    }
}
