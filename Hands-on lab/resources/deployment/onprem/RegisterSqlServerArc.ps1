param (
	$servicePrincipalAppId,
	$servicePrincipalSecret,
	$tenantId,
	$subId,
	$resourceGroup,
	$location
)

$servicePrincipalTenantId=$location
$licenseType="PAYG"
$machineName="TailspinSql"
$proxy=""

$currentDir = Get-Location
$unattended = $servicePrincipalAppId -And $tenantId -And $servicePrincipalSecret

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
	Invoke-WebRequest -Uri https://aka.ms/AzureExtensionForSQLServer -OutFile AzureExtensionForSQLServer.msi
}
catch {
    throw "Invoke-WebRequest failed: $_"
}

try {
	$exitcode = (Start-Process -FilePath msiexec.exe -ArgumentList @("/i", "AzureExtensionForSQLServer.msi","/l*v", "installationlog.txt", "/qn") -Wait -Passthru).ExitCode

	if ($exitcode -ne 0) {
		$message = "Installation failed: Please see $currentDir\installationlog.txt file for more information."
		Write-Host -ForegroundColor red $message
		return
	}

	if ($unattended) {
		& "$env:ProgramW6432\AzureExtensionForSQLServer\AzureExtensionForSQLServer.exe" --subId $subId --resourceGroup $resourceGroup --location $location --tenantid $servicePrincipalTenantId --service-principal-app-id $servicePrincipalAppId --service-principal-secret $servicePrincipalSecret --proxy $proxy --licenseType $licenseType --machineName $machineName
	} else {
		& "$env:ProgramW6432\AzureExtensionForSQLServer\AzureExtensionForSQLServer.exe" --subId $subId --resourceGroup $resourceGroup --location $location --tenantid $tenantId --proxy $proxy --licenseType $licenseType --machineName $machineName
	}

	if($LASTEXITCODE -eq 0){
		Write-Host -ForegroundColor green "Azure extension for SQL Server is successfully installed. If one or more SQL Server instances are up and running on the server, SQL Server enabled by Azure Arc instance resource(s) will be visible within a minute on the portal. Newly installed instances or instances started now will show within an hour."
	}
	else{
		$message = "Failed to install Azure extension for SQL Server. Please see $currentDir\AzureExtensionForSQLServerInstallation.log file for more information."
		Write-Host -ForegroundColor red $message
	}
}
catch {
	Write-Host -ForegroundColor red $_.Exception
	throw
}