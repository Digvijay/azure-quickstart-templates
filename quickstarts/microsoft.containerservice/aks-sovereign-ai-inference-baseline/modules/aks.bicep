// =============================================================================
// modules/aks.bicep
// Private AKS cluster hardened for air-gapped SLM inference:
//  - Private API server, userDefinedRouting (forced tunnel through firewall)
//  - Azure CNI Overlay + Cilium dataplane + Cilium network policy
//  - System pool (D16ds_v5) tainted CriticalAddonsOnly
//  - MI300X GPU user pool with gpuProfile.driver = 'None' (AMD GPU Operator owns
//    the driver lifecycle), scale-to-zero autoscaling
//  - KAITO (aiToolchainOperatorProfile) + KEDA (workloadAutoScalerProfile)
//  - Managed Prometheus + Container Insights, Workload Identity/OIDC, AAD RBAC
// =============================================================================

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('AKS cluster name.')
param clusterName string

@description('Kubernetes version.')
param kubernetesVersion string

@description('User-assigned managed identity resource ID.')
param userAssignedIdentityId string

@description('System node pool subnet resource ID.')
param systemSubnetId string

@description('GPU node pool subnet resource ID.')
param gpuSubnetId string

@description('System node pool VM SKU.')
param systemVmSize string

@description('GPU node pool VM SKU (MI300X).')
param gpuVmSize string

@description('GPU pool minimum node count (0 enables scale-to-zero).')
param gpuNodeCountMin int

@description('GPU pool maximum node count.')
param gpuNodeCountMax int

@description('Entra ID group object ID for cluster-admin via Azure RBAC.')
param clusterAdminGroupObjectId string

@description('Log Analytics workspace resource ID.')
param logAnalyticsWorkspaceId string

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-02-preview' = {
  name: clusterName
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Standard'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: '${clusterName}-dns'
    enableRBAC: true
    disableLocalAccounts: true
    nodeResourceGroup: 'MC_${clusterName}'

    aadProfile: {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: [
        clusterAdminGroupObjectId
      ]
      tenantID: subscription().tenantId
    }

    apiServerAccessProfile: {
      enablePrivateCluster: true
      privateDNSZone: 'system'
      enablePrivateClusterPublicFQDN: false
    }

    oidcIssuerProfile: {
      enabled: true
    }

    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }

    // KAITO: AI toolchain operator (equivalent of --enable-ai-toolchain-operator)
    aiToolchainOperatorProfile: {
      enabled: true
    }

    // KEDA: event-driven autoscaler (equivalent of --enable-keda)
    workloadAutoScalerProfile: {
      keda: {
        enabled: true
      }
    }

    // Managed Prometheus metrics are wired post-deploy by scripts/deploy.sh via
    // `az aks update --enable-azure-monitor-metrics`, which creates the required
    // Data Collection Rule/Endpoint associations to the Azure Monitor workspace.

    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
          useAADAuth: 'true'
        }
      }
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
        }
      }
    }

    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'cilium'
      networkDataplane: 'cilium'
      loadBalancerSku: 'standard'
      outboundType: 'userDefinedRouting'
      serviceCidr: '172.16.0.0/16'
      dnsServiceIP: '172.16.0.10'
      podCidr: '10.244.0.0/16'
    }

    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        type: 'VirtualMachineScaleSets'
        vmSize: systemVmSize
        count: 3
        enableAutoScaling: true
        minCount: 3
        maxCount: 5
        vnetSubnetID: systemSubnetId
        maxPods: 60
        availabilityZones: [
          '1'
          '2'
          '3'
        ]
        nodeTaints: [
          'CriticalAddonsOnly=true:NoSchedule'
        ]
        upgradeSettings: {
          maxSurge: '33%'
        }
      }
      {
        name: 'mi300x'
        mode: 'User'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        type: 'VirtualMachineScaleSets'
        vmSize: gpuVmSize
        count: gpuNodeCountMin
        enableAutoScaling: true
        minCount: gpuNodeCountMin
        maxCount: gpuNodeCountMax
        vnetSubnetID: gpuSubnetId
        maxPods: 30
        // Delegate GPU driver lifecycle to the AMD GPU Operator (driver mgmt = None).
        gpuProfile: {
          installGPUDriver: false
        }
        nodeLabels: {
          'amd.com/gpu': 'true'
          workload: 'slm-inference'
          accelerator: 'mi300x'
        }
        nodeTaints: [
          'sku=gpu:NoSchedule'
        ]
        upgradeSettings: {
          maxSurge: '1'
        }
      }
    ]
  }
}

output clusterName string = aks.name
output clusterId string = aks.id
output nodeResourceGroup string = aks.properties.nodeResourceGroup
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output kubeletIdentityObjectId string = aks.properties.identityProfile.kubeletidentity.objectId
