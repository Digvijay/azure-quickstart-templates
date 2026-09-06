#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Idempotent end-to-end deployment of the sovereign, air-gapped SLM
# inference platform. Safe to re-run: infrastructure uses ARM incremental mode
# and every kubectl/helm step is apply/upgrade-based.
#
# Because the AKS API server is PRIVATE, in-cluster steps are executed through
# `az aks command invoke`, which runs kubectl/helm from inside the cluster.
#
# Prerequisites: az CLI (logged in), Bicep, and permissions to create the
# resource group and role assignments.
#
# Usage:
#   RESOURCE_GROUP=rg-slm-sweden \
#   LOCATION=swedencentral \
#   CLUSTER_ADMIN_GROUP_OBJECT_ID=<entra-group-guid> \
#   ./deploy.sh
# =============================================================================
set -euo pipefail

# ------------------------------ Configuration --------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-slm-sovereign}"
LOCATION="${LOCATION:-swedencentral}"
NAME_PREFIX="${NAME_PREFIX:-slmair}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
CLUSTER_ADMIN_GROUP_OBJECT_ID="${CLUSTER_ADMIN_GROUP_OBJECT_ID:?Set CLUSTER_ADMIN_GROUP_OBJECT_ID to your Entra admin group object ID}"
GPU_OPERATOR_CHART="${GPU_OPERATOR_CHART:-rocm/gpu-operator-charts}"
GPU_OPERATOR_REPO="${GPU_OPERATOR_REPO:-https://rocm.github.io/gpu-operator-charts}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CORE="${ROOT_DIR}/manifests/core"
WORKLOADS="${ROOT_DIR}/manifests/workloads"

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[deploy:error]\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------ Phase 1: Infra -------------------------------
log "Ensuring resource group ${RESOURCE_GROUP} in ${LOCATION}"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none

log "Deploying infrastructure (Bicep, incremental)"
az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "slm-infra" \
  --template-file "${ROOT_DIR}/main.bicep" \
  --parameters \
      location="${LOCATION}" \
      namePrefix="${NAME_PREFIX}" \
      environment="${ENVIRONMENT}" \
      clusterAdminGroupObjectId="${CLUSTER_ADMIN_GROUP_OBJECT_ID}" \
  --output none

log "Reading deployment outputs"
read_output() { az deployment group show -g "${RESOURCE_GROUP}" -n slm-infra --query "properties.outputs.$1.value" -o tsv; }
CLUSTER_NAME="$(read_output aksClusterName)"
NODE_RG="$(read_output aksNodeResourceGroup)"
AMW_ID="$(read_output azureMonitorWorkspaceId)"
AMW_QUERY_ENDPOINT="$(read_output azureMonitorQueryEndpoint)"
IDENTITY_CLIENT_ID="$(read_output aksIdentityClientId)"
OIDC_ISSUER="$(read_output aksOidcIssuerUrl)"
log "Cluster=${CLUSTER_NAME} NodeRG=${NODE_RG}"

# Helper: run a command inside the private cluster, optionally uploading files.
aks_invoke() {
  local cmd="$1"; shift
  if [[ "$#" -gt 0 ]]; then
    az aks command invoke -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --command "${cmd}" --file "$@" -o tsv
  else
    az aks command invoke -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --command "${cmd}" -o tsv
  fi
}

# ------------------------------ Phase 2: Managed Prometheus ------------------
log "Enabling Azure Monitor managed Prometheus (creates DCR/DCRA to the AMW)"
az aks update -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" \
  --enable-azure-monitor-metrics \
  --azure-monitor-workspace-resource-id "${AMW_ID}" \
  --output none || log "Managed Prometheus already enabled; continuing"

# ------------------------------ Phase 3: AMD GPU Operator --------------------
log "Installing/upgrading the AMD GPU Operator (owns ROCm driver lifecycle)"
aks_invoke "helm repo add rocm ${GPU_OPERATOR_REPO} && helm repo update && \
  helm upgrade --install amd-gpu-operator ${GPU_OPERATOR_CHART} \
  --namespace kube-amd-gpu --create-namespace \
  --values amd-gpu-operator-values.yaml --wait --timeout 15m" \
  "${CORE}/amd-gpu-operator-values.yaml"

log "Applying AMD DeviceConfig"
aks_invoke "kubectl apply -f amd-gpu-operator-release.yaml" "${CORE}/amd-gpu-operator-release.yaml"

# ------------------------------ Phase 4: Namespace + Zero-trust --------------
log "Applying namespace and zero-trust NetworkPolicies"
aks_invoke "kubectl apply -f namespace.yaml" "${CORE}/namespace.yaml"
aks_invoke "kubectl apply -f netpol-default-deny.yaml -f netpol-allow-dns.yaml -f netpol-allow-internal.yaml" \
  "${CORE}/netpol-default-deny.yaml" "${CORE}/netpol-allow-dns.yaml" "${CORE}/netpol-allow-internal.yaml"

# ------------------------------ Phase 5: KEDA Workload Identity --------------
log "Federating KEDA operator to the managed identity for Prometheus reads"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
IDENTITY_NAME="${NAME_PREFIX}-${ENVIRONMENT}-aks-mi"
az identity federated-credential create \
  --name "keda-operator-fedcred" \
  --identity-name "${IDENTITY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --issuer "${OIDC_ISSUER}" \
  --subject "system:serviceaccount:kube-system:keda-operator" \
  --audience "api://AzureADTokenExchange" \
  --output none || log "Federated credential already exists; continuing"

IDENTITY_PRINCIPAL_ID="$(az identity show -g "${RESOURCE_GROUP}" -n "${IDENTITY_NAME}" --query principalId -o tsv)"
log "Granting Monitoring Data Reader on the Azure Monitor workspace"
az role assignment create \
  --assignee-object-id "${IDENTITY_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Monitoring Data Reader" \
  --scope "${AMW_ID}" \
  --output none || log "Role assignment already exists; continuing"

# Annotate the keda-operator service account for workload identity.
aks_invoke "kubectl annotate serviceaccount keda-operator -n kube-system \
  azure.workload.identity/client-id=${IDENTITY_CLIENT_ID} --overwrite && \
  kubectl rollout restart deployment/keda-operator -n kube-system"

# ------------------------------ Phase 6: KAITO + KEDA workloads --------------
log "Deploying KAITO Workspace (phi-4 on ROCm vLLM / MI300X)"
aks_invoke "kubectl apply -f kaito-workspace.yaml" "${WORKLOADS}/kaito-workspace.yaml"
aks_invoke "kubectl apply -f consumer-probe.yaml" "${WORKLOADS}/consumer-probe.yaml"

log "Rendering and applying KEDA TriggerAuthentication + ScaledObject"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
export KEDA_IDENTITY_CLIENT_ID="${IDENTITY_CLIENT_ID}"
export AZURE_MONITOR_QUERY_ENDPOINT="${AMW_QUERY_ENDPOINT}"
envsubst < "${WORKLOADS}/keda-trigger-auth.yaml" > "${TMP_DIR}/keda-trigger-auth.yaml"
envsubst < "${WORKLOADS}/keda-scaledobject.yaml" > "${TMP_DIR}/keda-scaledobject.yaml"
aks_invoke "kubectl apply -f keda-trigger-auth.yaml -f keda-scaledobject.yaml" \
  "${TMP_DIR}/keda-trigger-auth.yaml" "${TMP_DIR}/keda-scaledobject.yaml"

log "Waiting for the KAITO workspace to become ready (model provisioning can take ~15m)"
aks_invoke "kubectl wait --for=condition=WorkspaceSucceeded workspace/workspace-phi-4 -n inference --timeout=1800s" || \
  log "Workspace not yet ready; check 'kubectl get workspace -n inference'"

log "Deployment complete. Validate with scripts/test_inference.sh"
