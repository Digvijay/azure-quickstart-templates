using './main.bicep'

// Example parameter file. Replace clusterAdminGroupObjectId with the object ID
// of the Entra ID group that should receive cluster-admin via Azure RBAC.
param location = 'swedencentral'
param namePrefix = 'slmair'
param environment = 'prod'
param kubernetesVersion = '1.30.4'
param gpuNodeCountMin = 0
param gpuNodeCountMax = 4
param gpuVmSize = 'Standard_ND96isr_MI300X_v5'
param systemVmSize = 'Standard_D16ds_v5'
param clusterAdminGroupObjectId = '00000000-0000-0000-0000-000000000000'
