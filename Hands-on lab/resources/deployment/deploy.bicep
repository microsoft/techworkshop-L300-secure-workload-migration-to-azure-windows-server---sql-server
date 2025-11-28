var prefix string = 'tailspin'
var suffix = take(uniqueString(resourceGroup().id), 6)

var resourceNameBase = '${prefix}${suffix}'

@description('The Id of the Azure AD User.')
param azureAdUserId string
@description('The Login of the Azure AD User (ex: username@domain.onmicrosoft.com).')
param azureAdUserLogin string

@description('The VM size for the virtual machines. Allows Intel and AMD 4-core options with premium and non-premium storage.')
@allowed([
    'Standard_D4s_v4' // Default value
    'Standard_D4s_v5'
    'Standard_D4as_v5' // AMD-based, 4 vCPUs, premium storage
    'Standard_D4_v5' // Intel-based, 4 vCPUs, non-premium storage
    'Standard_D4a_v4' // AMD-based, 4 vCPUs, non-premium storage
    'Standard_D4d_v5' // Intel-based, 4 vCPUs, premium storage
    'Standard_D4ds_v5' // Intel-based, 4 vCPUs, premium storage
    'Standard_D4as_v4' // AMD-based, 4 vCPUs, non-premium storage
])
param onpremVMSize string = 'Standard_D4s_v4'

@description('The SKU of the SQL Managed Instance.')
@allowed([
    'GP_Gen4'
    'GP_Gen5'
])
param sqlMiSku string = 'GP_Gen5'

@description('The number of vCores for the SQL Managed Instance.')
@allowed([
    4
    8
])
param sqlMiVCores int = 4

@description('The branch of the GitHub repository to use for deployment scripts.')
param repositoryBranch string = 'main'
@description('The name of the GitHub repository containing deployment scripts.')
param repositoryName string = 'microsoft-tw-l300-secure-workload-migration-to-azure-windows-sql-server'
@description('The owner of the GitHub repository containing deployment scripts.')
@allowed([
    'microsoft'
    'Tahubu-AI'
])
param repositoryOwner string = 'Tahubu-AI'

var location = resourceGroup().location

@description('Restore the service instead of creating a new instance. This is useful if you previously soft-deleted the service and want to restore it. If you are restoring a service, set this to true. Otherwise, leave this as false.')
param restore bool = false

var hubNamePrefix = '${resourceNameBase}-hub'
var spokeNamePrefix = '${resourceNameBase}-spoke'
var sqlMiPrefix = '${resourceNameBase}-sqlmi'
var sqlMiStorageName = '${resourceNameBase}sqlmistor'

var onPremPrefix = '${resourceNameBase}-onprem'
var onPremSqlVmPrefix = '${onPremPrefix}-sql'
var onPremWindowsVmPrefix = '${onPremPrefix}-win'

var openAIName = '${resourceNameBase}-oai'

var gitHubRepo = '${repositoryOwner}/${repositoryName}'
var gitHubRepoScriptPath = 'Hands-on%20lab/resources/deployment/onprem'
var gitHubRepoUrl = 'https://github.com/${gitHubRepo}/raw/refs/heads/${repositoryBranch}/${gitHubRepoScriptPath}'

var databaseBackupFile = 'database.bak'
var databaseBackupFileUrl = '${gitHubRepoUrl}/${databaseBackupFile}'

var sqlVmScriptName = 'sql-vm-config.ps1'
var sqlVmScriptArchive = 'sql-vm-config.zip'
var sqlVmScriptArchiveUrl = '${gitHubRepoUrl}/${sqlVmScriptArchive}'

var windowsVmScriptName = 'windows-vm-config.ps1'
var windowsVmScriptArchive = 'windows-vm-config.zip'
var windowsVmScriptArchiveUrl = '${gitHubRepoUrl}/${windowsVmScriptArchive}'

var labUsername = 'demouser'
var labPassword = 'demo!pass123'
var labSqlMiPassword = 'demo!pass1234567'

var tags = {
    purpose: 'tech-workshop'
    createdBy: azureAdUserLogin
}

/* ****************************
Virtual Networks
**************************** */
resource onprem_vnet 'Microsoft.Network/virtualNetworks@2025-01-01' = {
    name: '${onPremPrefix}-vnet'
    location: location
    tags: tags
    properties: {
        addressSpace: {
            addressPrefixes: [
                '10.0.0.0/16'
            ]
        }
    }
}

resource onprem_subnet 'Microsoft.Network/virtualNetworks/subnets@2025-01-01' = {
  parent: onprem_vnet
  name: 'default'
  properties: {
    addressPrefix: '10.0.0.0/24'
  }
}

resource hub_vnet 'Microsoft.Network/virtualNetworks@2025-01-01' = {
    name: '${hubNamePrefix}-vnet'
    location: location
    tags: tags
    properties: {
        addressSpace: {
            addressPrefixes: [
                '10.1.0.0/16'
            ]
        }
        subnets: [
            {
                name: 'hub'
                properties: {
                    addressPrefix: '10.1.0.0/24'
                }
            }
            {
                name: 'AzureBastionSubnet'
                properties: {
                    addressPrefix: '10.1.1.0/24'
                }
            }
        ]
    }
}

resource spoke_vnet 'Microsoft.Network/virtualNetworks@2025-01-01' = {
    name: '${spokeNamePrefix}-vnet'
    location: location
    tags: tags
    properties: {
        addressSpace: {
            addressPrefixes: [
                '10.2.0.0/16'
            ]
        }
        subnets: [
            {
                name: 'default'
                properties: {
                    addressPrefix: '10.2.0.0/24'
                }
            }
            {
                name: 'AzureSqlMI'
                properties: {
                    addressPrefix: '10.2.1.0/24'
                    networkSecurityGroup: {
                        id: sqlMi_subnet_nsg.id
                    }
                    routeTable: {
                        id: sqlMi_subnet_routetable.id
                    }
                    delegations: [
                        {
                            name: 'AzureSqlMI'
                            properties: {
                                serviceName: 'Microsoft.Sql/managedInstances'
                            }
                            type: 'Microsoft.Network/virtualNetworks/subnets/delegations'
                        }
                    ]
                }
            }
        ]
    }
}

/* ****************************
Virtual Network Peerings
**************************** */
resource hub_onprem_vnet_peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-01-01' = {
    parent: hub_vnet
    name: 'hub-onprem'
    properties: {
        remoteVirtualNetwork: {
            id: onprem_vnet.id
        }
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: true
    }
}

resource onprem_hub_vnet_peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-01-01' = {
    parent: onprem_vnet
    name: 'onprem-hub'
    properties: {
        remoteVirtualNetwork: {
            id: hub_vnet.id
        }
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: true
    }
}

resource hub_spoke_vnet_peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-01-01' = {
    parent: hub_vnet
    name: 'hub-spoke'
    properties: {
        remoteVirtualNetwork: {
            id: spoke_vnet.id
        }
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: true
    }
}

resource spoke_hub_vnet_peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-01-01' = {
    parent: spoke_vnet
    name: 'spoke-hub'
    properties: {
        remoteVirtualNetwork: {
            id: hub_vnet.id
        }
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: true
    }
}

resource spoke_onprem_vnet_peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-01-01' = {
  parent: spoke_vnet
  name: 'spoke-onprem'
  properties: {
    remoteVirtualNetwork: {
      id: onprem_vnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

resource onprem_spoke_vnet_peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-01-01' = {
  parent: onprem_vnet
  name: 'onprem-spoke'
  properties: {
    remoteVirtualNetwork: {
      id: spoke_vnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

/* ****************************
Azure OpenAI
**************************** */
@description('Creates an Azure OpenAI resource.')
resource openAI 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' = {
  name: openAIName
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
    tier: 'Standard'
  }
  properties: {
    customSubDomainName: openAIName
    publicNetworkAccess: 'Enabled'
    restore: restore
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = {
  parent: openAI
  name: 'text-embedding-ada-002'
  sku: {
    name: 'Standard'
    capacity: 120
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-ada-002'
      version: '2'
    }
  }
}

/* ****************************
Azure SQL Managed Instance
**************************** */
resource sqlMi_storage 'Microsoft.Storage/storageAccounts@2025-06-01' = {
    name: sqlMiStorageName
    location: location
    sku: {
        name: 'Standard_RAGRS'
    }
    kind: 'StorageV2'
    properties: {
        accessTier: 'Hot'
    }
}

resource sqlMi_storage_container 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01' = {
    name: '${sqlMi_storage.name}/default/sql-backup'
    properties: {
        publicAccess: 'None'
    }
}

resource sqlMi 'Microsoft.Sql/managedInstances@2024-11-01-preview' = {
    name: sqlMiPrefix
    location: location
    sku: {
        name: sqlMiSku
        tier: 'GeneralPurpose'
    }
    identity: {
        type: 'SystemAssigned'
    }
    properties: {
        subnetId: '${spoke_vnet.id}/subnets/AzureSqlMI'
        storageSizeInGB: 64
        vCores: sqlMiVCores
        licenseType: 'LicenseIncluded'
        zoneRedundant: false
        minimalTlsVersion: '1.2'
        requestedBackupStorageRedundancy: 'Geo'
        administratorLogin: labUsername
        administratorLoginPassword: labSqlMiPassword
        administrators: {
            administratorType: 'ActiveDirectory'
            principalType: 'User'
            login: azureAdUserLogin
            sid: azureAdUserId
            tenantId: subscription().tenantId
            azureADOnlyAuthentication: false
        }
        databaseFormat: 'AlwaysUpToDate'
    }
}

// Assign the "Azure Connected Machine Onboarding" role to the identity fo the deployment user
resource sqlMiRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().name, azureAdUserId, 'SqlMiContributorRole')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4939a1f6-9ae0-4e48-a1e0-f2cbe897382d' // SQL Managed Instance Contributor role
    )
    principalId: azureAdUserId
    principalType: 'User'
  }
}

resource sqlMi_subnet_routetable 'Microsoft.Network/routeTables@2025-01-01'= {
    name: '${sqlMiPrefix}-rt'
    location: location
    properties: {
        routes: [
            {
                name: 'SqlManagement_0'
                properties: {
                    addressPrefix: '65.55.188.0/24'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_1'
                properties: {
                    addressPrefix: '207.68.190.32/27'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_2'
                properties: {
                    addressPrefix: '13.106.78.32/27'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_3'
                properties: {
                    addressPrefix: '13.106.174.32/27'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_4'
                properties: {
                    addressPrefix: '13.106.4.96/27'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_5'
                properties: {
                    addressPrefix: '104.214.108.80/32'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_6'
                properties: {
                    addressPrefix: '52.179.184.76/32'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_7'
                properties: {
                    addressPrefix: '52.187.116.202/32'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_8'
                properties: {
                    addressPrefix: '52.177.202.6/32'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_9'
                properties: {
                    addressPrefix: '23.98.55.75/32'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_10'
                properties: {
                    addressPrefix: '23.96.178.199/32'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_11'
                properties: {
                    addressPrefix: '52.162.107.128/27'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_12'
                properties: {
                    addressPrefix: '40.74.254.227/32'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_13'
                properties: {
                    addressPrefix: '23.96.185.63/32'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_14'
                properties: {
                    addressPrefix: '65.52.59.57/32'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'SqlManagement_15'
                properties: {
                    addressPrefix: '168.62.244.242/32'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_subnet-10-2-1-0-24-to-vnetlocal'
                properties: {
                    addressPrefix: '10.2.1.0/24'
                    nextHopType: 'VnetLocal'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-Storage'
                properties: {
                    addressPrefix: 'Storage'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-SqlManagement'
                properties: {
                    addressPrefix: 'SqlManagement'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-AzureMonitor'
                properties: {
                    addressPrefix: 'AzureMonitor'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-CorpNetSaw'
                properties: {
                    addressPrefix: 'CorpNetSaw'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-CorpNetPublic'
                properties: {
                    addressPrefix: 'CorpNetPublic'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-AzureActiveDirectory'
                properties: {
                    addressPrefix: 'AzureActiveDirectory'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-AzureCloud.northcentralus'
                properties: {
                    addressPrefix: 'AzureCloud.northcentralus'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-AzureCloud.southcentralus'
                properties: {
                    addressPrefix: 'AzureCloud.southcentralus'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-Storage.northcentralus'
                properties: {
                    addressPrefix: 'Storage.northcentralus'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-Storage.southcentralus'
                properties: {
                    addressPrefix: 'Storage.southcentralus'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-EventHub.northcentralus'
                properties: {
                    addressPrefix: 'EventHub.northcentralus'
                    nextHopType: 'Internet'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-EventHub.southcentralus'
                properties: {
                    addressPrefix: 'EventHub.southcentralus'
                    nextHopType: 'Internet'
                }
            }
        ]
    }
}

resource sqlMi_subnet_nsg 'Microsoft.Network/networkSecurityGroups@2025-01-01' = {
    name: '${sqlMiPrefix}-nsg'
    location: location
    properties: {
        securityRules: [
            {
                name: 'allow_tds_inbound'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    destinationPortRange: '1433'
                    sourceAddressPrefix: 'VirtualNetwork'
                    destinationAddressPrefix: '*'
                    access: 'Allow'
                    priority: 1000
                    direction: 'Inbound'
                }
            }
            {
                name: 'allow_redirect_inbound'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    destinationPortRange: '11000-11999'
                    sourceAddressPrefix: 'VirtualNetwork'
                    destinationAddressPrefix: '*'
                    access: 'Allow'
                    priority: 1100
                    direction: 'Inbound'
                }
            }
            {
                name: 'allow_geodr_inbound'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    destinationPortRange: '5022'
                    sourceAddressPrefix: 'VirtualNetwork'
                    destinationAddressPrefix: '10.2.1.0/24'
                    access: 'Allow'
                    priority: 1200
                    direction: 'Inbound'
                }
            }
            {
                name: 'deny_all_inbound'
                properties: {
                    protocol: '*'
                    sourcePortRange: '*'
                    destinationPortRange: '*'
                    sourceAddressPrefix: '*'
                    destinationAddressPrefix: '*'
                    access: 'Deny'
                    priority: 4096
                    direction: 'Inbound'
                }
            }
            {
                name: 'allow_linkedserver_outbound'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    destinationPortRange: '1433'
                    sourceAddressPrefix: '*'
                    destinationAddressPrefix: 'VirtualNetwork'
                    access: 'Allow'
                    priority: 1000
                    direction: 'Outbound'
                }
            }
            {
                name: 'allow_redirect_outbound'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    destinationPortRange: '11000-11999'
                    sourceAddressPrefix: '10.2.1.0/24'
                    destinationAddressPrefix: 'VirtualNetwork'
                    access: 'Allow'
                    priority: 1100
                    direction: 'Outbound'
                }
            }
            {
                name: 'allow_geodr_outbound'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    destinationPortRange: '5022'
                    sourceAddressPrefix: '*'
                    destinationAddressPrefix: 'VirtualNetwork'
                    access: 'Allow'
                    priority: 1200
                    direction: 'Outbound'
                }
            }
            {
                name: 'allow_privatelink_outbound'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    destinationPortRange: '443'
                    sourceAddressPrefix: '*'
                    destinationAddressPrefix: 'VirtualNetwork'
                    access: 'Allow'
                    priority: 1300
                    direction: 'Outbound'
                }
            }
            {
                name: 'allow_azurecloud_outbound'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    destinationPortRange: '443'
                    sourceAddressPrefix: '*'
                    destinationAddressPrefix: 'VirtualNetwork'
                    access: 'Allow'
                    priority: 1400
                    direction: 'Outbound'
                    sourcePortRanges: []
                    destinationPortRanges: []
                    sourceAddressPrefixes: []
                    destinationAddressPrefixes: []
                }
            }
            {
                name: 'deny_all_outbound'
                properties: {
                    protocol: '*'
                    sourcePortRange: '*'
                    destinationPortRange: '*'
                    sourceAddressPrefix: '*'
                    destinationAddressPrefix: '*'
                    access: 'Deny'
                    priority: 4096
                    direction: 'Outbound'
                    sourcePortRanges: []
                    destinationPortRanges: []
                    sourceAddressPrefixes: []
                    destinationAddressPrefixes: []
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-sqlmgmt-in-10-2-1-0-24-v10'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    sourceAddressPrefix: 'SqlManagement'
                    destinationAddressPrefix: '*'
                    access: 'Allow'
                    priority: 100
                    direction: 'Inbound'
                    destinationPortRanges: [
                        '9000'
                        '9003'
                        '1438'
                        '1440'
                        '1452'
                    ]
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-corpsaw-in-10-2-1-0-24-v10'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    sourceAddressPrefix: 'CorpNetSaw'
                    destinationAddressPrefix: '*'
                    access: 'Allow'
                    priority: 101
                    direction: 'Inbound'
                    destinationPortRanges: [
                        '9000'
                        '9003'
                        '1440'
                    ]
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-corppublic-in-10-2-1-0-24-v10'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    sourceAddressPrefix: 'CorpNetPublic'
                    destinationAddressPrefix: '10.2.1.0/24'
                    access: 'Allow'
                    priority: 102
                    direction: 'Inbound'
                    sourcePortRanges: []
                    destinationPortRanges: [
                        '9000'
                        '9003'
                    ]
                    sourceAddressPrefixes: []
                    destinationAddressPrefixes: []
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-healthprobe-in-10-2-1-0-24-v10'
                properties: {
                    protocol: '*'
                    sourcePortRange: '*'
                    destinationPortRange: '*'
                    sourceAddressPrefix: 'AzureLoadBalancer'
                    destinationAddressPrefix: '10.2.1.0/24'
                    access: 'Allow'
                    priority: 103
                    direction: 'Inbound'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-internal-in-10-2-1-0-24-v10'
                properties: {
                    protocol: '*'
                    sourcePortRange: '*'
                    destinationPortRange: '*'
                    sourceAddressPrefix: '10.2.1.0/24'
                    destinationAddressPrefix: '10.2.1.0/24'
                    access: 'Allow'
                    priority: 104
                    direction: 'Inbound'
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-services-out-10-2-1-0-24-v10'
                properties: {
                    protocol: 'Tcp'
                    sourcePortRange: '*'
                    sourceAddressPrefix: '10.2.1.0/24'
                    destinationAddressPrefix: 'AzureCloud'
                    access: 'Allow'
                    priority: 100
                    direction: 'Outbound'
                    destinationPortRanges: [
                        '443'
                        '12000'
                    ]
                }
            }
            {
                name: 'Microsoft.Sql-managedInstances_UseOnly_mi-internal-out-10-2-1-0-24-v10'
                properties: {
                    protocol: '*'
                    sourcePortRange: '*'
                    destinationPortRange: '*'
                    sourceAddressPrefix: '10.2.1.0/24'
                    destinationAddressPrefix: '10.2.1.0/24'
                    access: 'Allow'
                    priority: 101
                    direction: 'Outbound'
                }
            }
        ]
    }
}

/* ****************************
Azure Bastion
**************************** */
resource bastion 'Microsoft.Network/bastionHosts@2025-01-01' = {
    name: '${hubNamePrefix}-bastion'
    location: location
    tags: tags
    sku: {
        name: 'Basic'
    }
    properties: {
        ipConfigurations: [
            {
                name: 'IpConf'
                properties: {
                    privateIPAllocationMethod: 'Dynamic'
                    publicIPAddress: {
                        id: bastion_public_ip.id
                    }
                    subnet: {
                        id: '${hub_vnet.id}/subnets/AzureBastionSubnet'
                    }
                }
            }
        ]
    }
}

resource bastion_public_ip 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
    name: '${hubNamePrefix}-bastion-pip'
    location: location
    tags: tags
    sku: {
        name: 'Standard'
        tier: 'Regional'
    }
    properties: {
        publicIPAddressVersion: 'IPv4'
        publicIPAllocationMethod: 'Static'
    }
}

/* ****************************
On-premises Windows VM
**************************** */
resource onprem_windows_vm 'Microsoft.Compute/virtualMachines@2025-04-01' = {
    name: '${onPremWindowsVmPrefix}-vm'
    location: location
    tags: tags
    properties: {
        hardwareProfile: {
            vmSize: onpremVMSize
        }
        additionalCapabilities: {
            hibernationEnabled: false
        }
        storageProfile: {
            
            osDisk: {
                createOption: 'fromImage'
            }
            imageReference: {
                communityGalleryImageId: '/CommunityGalleries/Tahubu-607896e6-c4b5-4245-bfb6-c6b57aa9aa62/Images/WS2012R2_SQL2014_Base/Versions/latest'
            }
        }
        networkProfile: {
            networkInterfaces: [
                {
                    id: onprem_windows_nic.id
                }
            ]
        }
        osProfile: {
            computerName: 'WinServer'
            #disable-next-line adminusername-should-not-be-literal
            adminUsername: labUsername
            #disable-next-line use-secure-value-for-secure-inputs
            adminPassword: labPassword
        }
    }
}

resource onprem_windows_nic 'Microsoft.Network/networkInterfaces@2025-01-01' = {
    name: '${onPremWindowsVmPrefix}-nic'
    location: location
    tags: tags
    properties: {
        ipConfigurations: [
            {
                name: 'ipconfig1'
                properties: {
                    subnet: {
                        id: onprem_subnet.id
                    }
                    privateIPAllocationMethod: 'Dynamic'
                }
            }
        ]
    }
}

resource onprem_windows_vm_ext 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = {
    parent: onprem_windows_vm
    name: 'WindowsVmConfig'
    location: location
    tags: tags
    properties: {
        publisher: 'Microsoft.Powershell'
        type: 'DSC'
        typeHandlerVersion: '2.9'
        autoUpgradeMinorVersion: true
        settings: {
            wmfVersion: 'latest'
            configuration: {
                url: windowsVmScriptArchiveUrl
                script: windowsVmScriptName
                function: 'ArcConnect'
            }
        }
    }
}

/* ****************************
On-premises SQL VM
**************************** */
resource onprem_sql_vm 'Microsoft.Compute/virtualMachines@2025-04-01' = {
    name: '${onPremSqlVmPrefix}-vm'
    location: location
    tags: tags
    properties: {
        hardwareProfile: {
            vmSize: onpremVMSize
        }
        additionalCapabilities: {
            hibernationEnabled: false
        }
        storageProfile: {
            osDisk: {
                createOption: 'fromImage'
            }
            imageReference: {
                publisher: 'MicrosoftSQLServer'
                offer: 'SQL2019-WS2022'
                sku: 'Standard'
                version: 'latest'
            }
        }
        networkProfile: {
            networkInterfaces: [
                {
                    id: onprem_sql_nic.id
                }
            ]
        }
        osProfile: {
            computerName: 'SqlServer'
            #disable-next-line adminusername-should-not-be-literal
            adminUsername: labUsername
            #disable-next-line use-secure-value-for-secure-inputs
            adminPassword: labPassword
        }
    }
}

resource onprem_sql_nsg 'Microsoft.Network/networkSecurityGroups@2025-01-01' = {
  name: '${onPremSqlVmPrefix}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'SQL-Inbound'
        properties: {
          protocol: 'TCP'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: '10.2.1.0/24'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'SQL-Outbound'
        properties: {
          protocol: 'TCP'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '10.2.1.0/24'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
        }
      }
      {
        name: 'AG-Endpoint-Inbound'
        properties: {
          protocol: 'TCP'
          sourcePortRange: '*'
          destinationPortRange: '5022'
          sourceAddressPrefix: '10.2.1.0/24'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 120
          direction: 'Inbound'
        }
      }
      {
        name: 'AG-Endpoint-Outbound'
        properties: {
          protocol: 'TCP'
          sourcePortRange: '*'
          destinationPortRange: '5022'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '10.2.1.0/24'
          access: 'Allow'
          priority: 130
          direction: 'Outbound'
        }
      }
      {
        name: 'TDS-Redirect-Outbound'
        properties: {
          protocol: 'TCP'
          sourcePortRange: '*'
          destinationPortRange: '11000-11999'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '10.2.1.0/24'
          access: 'Allow'
          priority: 140
          direction: 'Outbound'
        }
      }
    ]
  }
}

resource onprem_sql_nic 'Microsoft.Network/networkInterfaces@2025-01-01' = {
    name: '${onPremSqlVmPrefix}-nic'
    location: location
    tags: tags
    properties: {
        ipConfigurations: [
            {
                name: 'ipconfig1'
                properties: {
                    subnet: {
                        id: onprem_subnet.id
                    }
                    privateIPAllocationMethod: 'Dynamic'
                }
            }
        ]
        networkSecurityGroup: {
            id: onprem_sql_nsg.id
        }
    }
}

resource onprem_sql_vm_ext 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = {
    parent: onprem_sql_vm
    name: 'SqlVmConfig'
    location: location
    tags: tags
    properties: {
        publisher: 'Microsoft.Powershell'
        type: 'DSC'
        typeHandlerVersion: '2.9'
        autoUpgradeMinorVersion: true
        settings: {
            configuration: {
                url: sqlVmScriptArchiveUrl
                script: sqlVmScriptName
                function: 'Main'
            }
            configurationArguments: {
                DbBackupFileUrl: databaseBackupFileUrl
                DatabasePassword: labPassword
            }
        }
    }
}
