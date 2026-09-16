#!/usr/bin/env bash
# Bootstraps Cilium as the cluster CNI (kube-proxy replacement + ingress
# controller) via Helm, directly against the freshly-bootstrapped cluster —
# ArgoCD can't run yet because nothing can schedule without a CNI. Once
# ArgoCD is installed (step 08), gitops/infrastructure/cilium/application.yaml
# adopts this same release for ongoing GitOps management, using the exact
# same values.yaml so there's no drift.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

CILIUM_VERSION="1.20.2"   # keep in sync with gitops/infrastructure/cilium/application.yaml
CILIUM_NAMESPACE="kube-system"

log_step "Installing Cilium CNI"

helm repo add cilium https://helm.cilium.io/ --force-update >/dev/null
helm repo update cilium >/dev/null

helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace "${CILIUM_NAMESPACE}" \
  --kubeconfig "${KUBECONFIG_PATH}" \
  -f "${REPO_ROOT}/gitops/infrastructure/cilium/values.yaml" \
  --wait --timeout 5m

log_step "Waiting for Cilium to be ready"
kubectl_ctx -n "${CILIUM_NAMESPACE}" rollout status daemonset/cilium --timeout=300s
kubectl_ctx -n "${CILIUM_NAMESPACE}" rollout status deployment/cilium-operator --timeout=300s

all_nodes_ready() {
  local total ready
  total=$(kubectl_ctx get nodes --no-headers | wc -l)
  ready=$(kubectl_ctx get nodes --no-headers | awk '$2=="Ready"' | wc -l)
  [[ "${total}" -gt 0 && "${total}" -eq "${ready}" ]]
}
wait_for "all ${NODE_COUNT} nodes Ready" 300 all_nodes_ready

log_info "Cilium is up, all nodes Ready:"
kubectl_ctx get nodes -o wide
log_info "Next: ./scripts/05-install-sealed-secrets.sh"
