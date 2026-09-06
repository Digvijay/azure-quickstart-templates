#!/usr/bin/env bash
# =============================================================================
# test_inference.sh — Validation harness for the sovereign SLM platform.
# Runs against the PRIVATE cluster via `az aks command invoke` and asserts:
#   1. GPU allocation  — MI300X amd.com/gpu resources are advertised & scheduled.
#   2. Inference        — /v1/completions returns 200 and latency < budget.
#   3. Egress air-gap   — a pod's attempt to reach the public internet is DROPPED
#                         (the test PASSES only when exfiltration FAILS).
#   4. Scale-to-zero    — KEDA returns replicas to 0 when idle (best-effort).
#
# Exits non-zero on the first failed assertion.
#
# Usage:
#   RESOURCE_GROUP=rg-slm-sovereign ./test_inference.sh
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-slm-sovereign}"
NAME_PREFIX="${NAME_PREFIX:-slmair}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
CLUSTER_NAME="${CLUSTER_NAME:-${NAME_PREFIX}-${ENVIRONMENT}-aks}"
LATENCY_BUDGET_MS="${LATENCY_BUDGET_MS:-15000}"
SERVICE="http://workspace-phi-4.inference.svc.cluster.local:8000"

pass() { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m[test]\033[0m %s\n' "$*"; }

invoke() { az aks command invoke -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --command "$1" -o tsv; }

# ------------------------------ 1. GPU allocation ----------------------------
info "Asserting MI300X GPUs are advertised as amd.com/gpu"
GPU_ALLOC="$(invoke "kubectl get nodes -l accelerator=mi300x -o jsonpath='{.items[*].status.allocatable.amd\.com/gpu}'" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -rn | head -n1 || true)"
if [[ -z "${GPU_ALLOC:-}" || "${GPU_ALLOC}" -lt 1 ]]; then
  fail "No allocatable amd.com/gpu found on MI300X nodes (operator/driver not ready)."
fi
pass "MI300X node advertises ${GPU_ALLOC} allocatable GPU(s)."

info "Asserting the vLLM pod is scheduled on an MI300X node"
POD_NODE="$(invoke "kubectl get pods -n inference -l kaito.sh/workspace=workspace-phi-4 -o jsonpath='{.items[0].spec.nodeName}'" || true)"
[[ -n "${POD_NODE}" ]] || fail "No running vLLM pod for workspace-phi-4."
NODE_ACCEL="$(invoke "kubectl get node ${POD_NODE} -o jsonpath='{.metadata.labels.accelerator}'" || true)"
[[ "${NODE_ACCEL}" == "mi300x" ]] || fail "vLLM pod is not on an MI300X node (found '${NODE_ACCEL}')."
pass "vLLM pod running on MI300X node ${POD_NODE}."

# ------------------------------ 2. Inference latency -------------------------
info "Issuing an inference request from the in-VNet consumer and measuring latency"
REQ='{"model":"phi-4","prompt":"In one sentence, what is data sovereignty?","max_tokens":32}'
RESULT="$(invoke "kubectl exec -n inference deploy/inference-consumer -- \
  sh -c 'wget -q -O /dev/null -S --header=\"Content-Type: application/json\" \
  --post-data='\''${REQ}'\'' --timeout=60 \"${SERVICE}/v1/completions\" 2>&1; \
  echo EXIT=\$?; \
  s=\$(date +%s%3N); wget -q -O /dev/null --header=\"Content-Type: application/json\" \
  --post-data='\''${REQ}'\'' --timeout=60 \"${SERVICE}/v1/completions\"; \
  e=\$(date +%s%3N); echo LATENCY_MS=\$((e-s))'" || true)"
echo "${RESULT}"
echo "${RESULT}" | grep -Eq 'HTTP/1\.[01] 200' || fail "Inference endpoint did not return HTTP 200."
LATENCY_MS="$(echo "${RESULT}" | sed -n 's/^LATENCY_MS=\([0-9]\+\).*/\1/p' | tail -n1)"
[[ -n "${LATENCY_MS}" ]] || fail "Could not measure inference latency."
if (( LATENCY_MS > LATENCY_BUDGET_MS )); then
  fail "Inference latency ${LATENCY_MS}ms exceeds budget ${LATENCY_BUDGET_MS}ms."
fi
pass "Inference returned 200 in ${LATENCY_MS}ms (budget ${LATENCY_BUDGET_MS}ms)."

# ------------------------------ 3. Egress air-gap ----------------------------
info "Egress violation test: the inference pod must NOT reach the public internet"
EGRESS="$(invoke "kubectl exec -n inference deploy/inference-consumer -- \
  sh -c 'wget -q -O /dev/null --timeout=8 https://www.microsoft.com; echo EXIT=\$?'" || true)"
echo "${EGRESS}"
EGRESS_CODE="$(echo "${EGRESS}" | sed -n 's/^EXIT=\([0-9]\+\).*/\1/p' | tail -n1)"
if [[ "${EGRESS_CODE:-0}" == "0" ]]; then
  fail "SECURITY: pod reached the public internet — NetworkPolicy air-gap is NOT enforced."
fi
pass "Public internet egress was dropped (exit ${EGRESS_CODE}); air-gap enforced."

# ------------------------------ 4. Scale-to-zero (best-effort) ---------------
info "Checking KEDA ScaledObject is active"
SO_READY="$(invoke "kubectl get scaledobject phi-4-inference -n inference -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" || true)"
[[ "${SO_READY}" == "True" ]] && pass "KEDA ScaledObject is Ready (queue-depth autoscaling active)." \
  || info "KEDA ScaledObject not yet Ready; verify with 'kubectl describe scaledobject -n inference'."

printf '\n\033[1;32mAll critical assertions passed.\033[0m\n'
