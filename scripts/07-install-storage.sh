#!/usr/bin/env bash
# Installs local-path-provisioner (distributed storage's simpler, single-
# node-pinned replacement — see docu/11-troubleshooting.md and the project's
# own history for why Longhorn was dropped in favor of this). No Helm chart
# exists for it, so this is a plain `kubectl apply` of the vendored manifest
# — same file ArgoCD syncs later (gitops/infrastructure/local-path-provisioner/).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

LP_NAMESPACE="local-path-storage"

log_step "Installing local-path-provisioner"

kubectl_ctx apply -f "${REPO_ROOT}/gitops/infrastructure/local-path-provisioner/manifests.yaml"

kubectl_ctx -n "${LP_NAMESPACE}" rollout status deployment/local-path-provisioner --timeout=120s

log_info "local-path-provisioner installed. StorageClass 'local-path' is ready to use."
log_info "Next: ./scripts/08-install-argocd.sh"
