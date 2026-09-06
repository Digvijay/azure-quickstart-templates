// =============================================================================
// modules/routes.bicep
// Adds the forced-tunnel default route (0.0.0.0/0 -> Azure Firewall) to the
// pre-existing route table. Deployed AFTER the firewall so the private IP is
// known, avoiding a subnet<->firewall circular dependency.
// =============================================================================

@description('Name of the existing route table created by modules/network.bicep.')
param routeTableName string

@description('Private IP address of the Azure Firewall (next hop).')
param firewallPrivateIp string

resource routeTable 'Microsoft.Network/routeTables@2024-10-01' existing = {
  name: routeTableName
}

resource defaultRoute 'Microsoft.Network/routeTables/routes@2024-10-01' = {
  parent: routeTable
  name: 'default-to-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewallPrivateIp
  }
}

output routeId string = defaultRoute.id
