// =============================================================================
// modules/network.bicep
// Hardened private VNet with isolated subnets for system and GPU workloads,
// per-subnet NSGs (deny inbound from Internet), and an (initially empty) route
// table associated to the workload subnets for forced-tunnel egress.
// =============================================================================

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Virtual network name.')
param vnetName string

@description('Route table name (created empty here; default route added post-firewall).')
param routeTableName string

@description('VNet address space.')
param vnetAddressSpace string = '10.0.0.0/16'

var subnets = {
  system: {
    name: 'snet-system'
    prefix: '10.0.1.0/24'
  }
  gpu: {
    name: 'snet-gpu'
    prefix: '10.0.8.0/22'
  }
  firewall: {
    name: 'AzureFirewallSubnet'
    prefix: '10.0.63.0/26'
  }
  privatelink: {
    name: 'snet-privatelink'
    prefix: '10.0.2.0/24'
  }
}

// ------------------------------ NSGs -----------------------------------------

resource systemNsg 'Microsoft.Network/networkSecurityGroups@2024-10-01' = {
  name: '${subnets.system.name}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'DenyInternetInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource gpuNsg 'Microsoft.Network/networkSecurityGroups@2024-10-01' = {
  name: '${subnets.gpu.name}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowVnetInferenceInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '8000'
        }
      }
      {
        name: 'DenyInternetInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ------------------------------ Route table ----------------------------------
// Created empty; the 0.0.0.0/0 -> firewall route is added by modules/routes.bicep
// after the firewall private IP is known. Associated only to workload subnets
// (never to AzureFirewallSubnet).

resource routeTable 'Microsoft.Network/routeTables@2024-10-01' = {
  name: routeTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
  }
}

// ------------------------------ VNet + subnets -------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2024-10-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
    subnets: [
      {
        name: subnets.system.name
        properties: {
          addressPrefix: subnets.system.prefix
          networkSecurityGroup: {
            id: systemNsg.id
          }
          routeTable: {
            id: routeTable.id
          }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: subnets.gpu.name
        properties: {
          addressPrefix: subnets.gpu.prefix
          networkSecurityGroup: {
            id: gpuNsg.id
          }
          routeTable: {
            id: routeTable.id
          }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: subnets.firewall.name
        properties: {
          addressPrefix: subnets.firewall.prefix
        }
      }
      {
        name: subnets.privatelink.name
        properties: {
          addressPrefix: subnets.privatelink.prefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ------------------------------ Outputs --------------------------------------

output vnetId string = vnet.id
output systemSubnetId string = '${vnet.id}/subnets/${subnets.system.name}'
output gpuSubnetId string = '${vnet.id}/subnets/${subnets.gpu.name}'
output firewallSubnetId string = '${vnet.id}/subnets/${subnets.firewall.name}'
output privateLinkSubnetId string = '${vnet.id}/subnets/${subnets.privatelink.name}'
output routeTableId string = routeTable.id
output routeTableName string = routeTable.name
