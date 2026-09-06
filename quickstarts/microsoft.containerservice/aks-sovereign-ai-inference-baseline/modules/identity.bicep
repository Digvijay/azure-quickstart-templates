// =============================================================================
// modules/identity.bicep
// User-assigned managed identity for the AKS cluster, granted least-privilege
// Network Contributor on ONLY the route table and VNet (required for
// userDefinedRouting + internal load balancer), scoped — never subscription-wide.
// =============================================================================

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Managed identity name.')
param identityName string

@description('Route table resource ID (role assignment scope).')
param routeTableId string

@description('VNet resource ID (role assignment scope).')
param vnetId string

// Built-in role: Network Contributor
var networkContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: identityName
  location: location
  tags: tags
}

resource routeTable 'Microsoft.Network/routeTables@2024-10-01' existing = {
  name: last(split(routeTableId, '/'))
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-10-01' existing = {
  name: last(split(vnetId, '/'))
}

resource routeTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: routeTable
  name: guid(routeTableId, identity.id, 'network-contributor')
  properties: {
    roleDefinitionId: networkContributorRoleId
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource vnetRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vnet
  name: guid(vnetId, identity.id, 'network-contributor')
  properties: {
    roleDefinitionId: networkContributorRoleId
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output identityId string = identity.id
output identityPrincipalId string = identity.properties.principalId
output identityClientId string = identity.properties.clientId
