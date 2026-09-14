#!/usr/bin/env bash
# Installs Longhorn (distributed block storage) via Helm. Requires the
# iscsi-tools/util-linux-tools Talos extensions (baked into the image in
# step 01) and the per-node disk mount set up in step 02 — if this fails with
# nodes stuck in a degraded state, check `kubectl -n longhorn-system get
# nodes.longhorn.io` and docu/02-talos-setup.md first.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

LH_NAMESPACE="longhorn-system"

log_step "Installing Longhorn"

helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo update longhorn >/dev/null

helm upgrade --install longhorn longhorn/longhorn \
  --version 1.7.2 \
  --namespace "${LH_NAMESPACE}" --create-namespace \
  --kubeconfig "${KUBECONFIG_PATH}" \
  -f "${REPO_ROOT}/gitops/infrastructure/longhorn/values.yaml" \
  --wait --timeout 5m

kubectl_ctx -n "${LH_NAMESPACE}" rollout status deployment/longhorn-driver-deployer --timeout=180s

log_info "Longhorn installed."
log_info "UI (for later, optional): kubectl --kubeconfig kubeconfig -n ${LH_NAMESPACE} port-forward svc/longhorn-frontend 8080:80"
log_info "Next: ./scripts/08-install-argocd.sh"
