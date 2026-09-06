// =============================================================================
// modules/firewall.bicep
// Azure Firewall + Firewall Policy that allow-lists ONLY the FQDNs an AKS node
// requires to bootstrap and pull the ROCm/vLLM images. All other outbound
// traffic is denied, enforcing the air-gap for model weights and prompt data.
// =============================================================================

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Azure Firewall name.')
param firewallName string

@description('Firewall public IP name.')
param publicIpName string

@description('Firewall policy name.')
param firewallPolicyName string

@description('Resource ID of AzureFirewallSubnet.')
param firewallSubnetId string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: firewallPolicyName
  location: location
  tags: tags
  properties: {
    sku: {
      tier: 'Standard'
    }
    threatIntelMode: 'Deny'
  }
}

// Minimal AKS egress allow-list. Extend with your private ACR / model mirror.
resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: firewallPolicy
  name: 'aks-egress'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'aks-required-fqdns'
        priority: 210
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'aks-control-plane'
            sourceAddresses: [
              '10.0.0.0/16'
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.hcp.${location}.azmk8s.io'
              'mcr.microsoft.com'
              '*.data.mcr.microsoft.com'
              #disable-next-line no-hardcoded-env-urls
              'management.azure.com'
              #disable-next-line no-hardcoded-env-urls
              'login.microsoftonline.com'
              'packages.microsoft.com'
              'acs-mirror.azureedge.net'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'aks-optional-tooling'
            sourceAddresses: [
              '10.0.0.0/16'
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            targetFqdns: [
              '*.ods.opinsights.azure.com'
              '*.oms.opinsights.azure.com'
              '*.monitoring.azure.com'
              'dc.services.visualstudio.com'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'aks-required-network'
        priority: 220
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'ntp'
            sourceAddresses: [
              '10.0.0.0/16'
            ]
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '123'
            ]
            ipProtocols: [
              'UDP'
            ]
          }
          {
            ruleType: 'NetworkRule'
            name: 'api-udp-tcp'
            sourceAddresses: [
              '10.0.0.0/16'
            ]
            destinationAddresses: [
              'AzureCloud.${location}'
            ]
            destinationPorts: [
              '1194'
              '9000'
            ]
            ipProtocols: [
              'UDP'
              'TCP'
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: firewallName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          subnet: {
            id: firewallSubnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
  dependsOn: [
    ruleCollectionGroup
  ]
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: firewall
  name: 'fw-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output firewallId string = firewall.id
