// =============================================================================
// main.bicep
// Air-gapped, event-driven SLM inference platform on AKS + AMD Instinct MI300X.
// Provisions: hardened private VNet, Azure Firewall (locked egress via UDR),
// user-assigned identity, and a private AKS cluster with KAITO (AI toolchain
// operator) and KEDA enabled, plus Log Analytics + managed Prometheus.
//
// Scope:  resourceGroup
// Deploy: az deployment group create -g <rg> -f main.bicep -p @azuredeploy.parameters.json
// =============================================================================

targetScope = 'resourceGroup'

// ------------------------------ Parameters -----------------------------------

@description('Azure region for all resources. Must offer the ND MI300X v5 SKU (e.g. swedencentral).')
param location string = resourceGroup().location

@description('Short, lowercase workload/environment prefix used for resource naming.')
@minLength(3)
@maxLength(12)
param namePrefix string = 'slmair'

@description('Environment moniker used in naming and tags.')
@allowed([
  'prod'
  'stage'
  'dev'
])
param environment string = 'prod'

@description('Kubernetes control-plane version.')
param kubernetesVersion string = '1.30.4'

@description('Baseline number of MI300X GPU nodes. KEDA scales pods; cluster-autoscaler scales nodes between min and max.')
@minValue(0)
param gpuNodeCountMin int = 0

@description('Maximum MI300X GPU nodes the cluster-autoscaler may provision.')
@minValue(1)
param gpuNodeCountMax int = 4

@description('VM SKU for the AMD Instinct MI300X GPU user node pool (8x MI300X 192GB).')
param gpuVmSize string = 'Standard_ND96isr_MI300X_v5'

@description('VM SKU for the system node pool.')
param systemVmSize string = 'Standard_D16ds_v5'

@description('Object ID of the Entra ID group granted cluster-admin via AKS-managed Azure RBAC.')
param clusterAdminGroupObjectId string

@description('Resource tags applied to every resource.')
param tags object = {
  workload: 'airgapped-slm-inference'
  platform: 'aks-mi300x'
  environment: environment
  dataClassification: 'sovereign'
  costCenter: 'ai-platform'
}

// ------------------------------ Variables ------------------------------------

var suffix = uniqueString(resourceGroup().id, namePrefix, environment)
var names = {
  vnet: '${namePrefix}-${environment}-vnet'
  firewall: '${namePrefix}-${environment}-afw'
  firewallPip: '${namePrefix}-${environment}-afw-pip'
  firewallPolicy: '${namePrefix}-${environment}-afwpolicy'
  routeTable: '${namePrefix}-${environment}-rt'
  aks: '${namePrefix}-${environment}-aks'
  aksIdentity: '${namePrefix}-${environment}-aks-mi'
  logAnalytics: '${namePrefix}-${environment}-law-${suffix}'
  azureMonitorWorkspace: '${namePrefix}-${environment}-amw'
}

// ------------------------------ Observability --------------------------------

resource azureMonitorWorkspace 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: names.azureMonitorWorkspace
  location: location
  tags: tags
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.logAnalytics
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ------------------------------ Networking -----------------------------------

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    tags: tags
    vnetName: names.vnet
    routeTableName: names.routeTable
  }
}

module firewall 'modules/firewall.bicep' = {
  name: 'firewall'
  params: {
    location: location
    tags: tags
    firewallName: names.firewall
    publicIpName: names.firewallPip
    firewallPolicyName: names.firewallPolicy
    firewallSubnetId: network.outputs.firewallSubnetId
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

// Add the forced-tunnel default route (0.0.0.0/0 -> firewall) only after the
// firewall private IP exists. Creating the route table empty in the network
// module and populating it here deliberately breaks the subnet<->firewall cycle.
module routes 'modules/routes.bicep' = {
  name: 'routes'
  params: {
    routeTableName: network.outputs.routeTableName
    firewallPrivateIp: firewall.outputs.firewallPrivateIp
  }
}

// ------------------------------ Identity -------------------------------------

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    tags: tags
    identityName: names.aksIdentity
    routeTableId: network.outputs.routeTableId
    vnetId: network.outputs.vnetId
  }
}

// ------------------------------ AKS ------------------------------------------

module aks 'modules/aks.bicep' = {
  name: 'aks'
  dependsOn: [
    routes // ensure the egress route is present before nodes bootstrap
  ]
  params: {
    location: location
    tags: tags
    clusterName: names.aks
    kubernetesVersion: kubernetesVersion
    userAssignedIdentityId: identity.outputs.identityId
    systemSubnetId: network.outputs.systemSubnetId
    gpuSubnetId: network.outputs.gpuSubnetId
    systemVmSize: systemVmSize
    gpuVmSize: gpuVmSize
    gpuNodeCountMin: gpuNodeCountMin
    gpuNodeCountMax: gpuNodeCountMax
    clusterAdminGroupObjectId: clusterAdminGroupObjectId
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

// ------------------------------ Outputs --------------------------------------

output aksClusterName string = aks.outputs.clusterName
output aksNodeResourceGroup string = aks.outputs.nodeResourceGroup
output kubeletIdentityObjectId string = aks.outputs.kubeletIdentityObjectId
output firewallPrivateIp string = firewall.outputs.firewallPrivateIp
output vnetId string = network.outputs.vnetId
output logAnalyticsWorkspaceId string = logAnalytics.id
output azureMonitorWorkspaceId string = azureMonitorWorkspace.id
output azureMonitorQueryEndpoint string = azureMonitorWorkspace.properties.metrics.prometheusQueryEndpoint
output aksIdentityClientId string = identity.outputs.identityClientId
output aksOidcIssuerUrl string = aks.outputs.oidcIssuerUrl
