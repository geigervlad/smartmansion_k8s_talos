#!/usr/bin/env bash
# Installs ArgoCD via Helm. Does NOT apply the root app-of-apps yet — that
# needs the GitOps repo to actually contain the manifests we're generating in
# this same pipeline, which only happens once scripts/10-bootstrap-argocd-apps.sh
# commits and pushes. ArgoCD itself is intentionally never re-adopted as a
# GitOps-managed Application (see gitops/infrastructure/argocd/values.yaml).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ARGOCD_RELEASE="argocd"

log_step "Installing ArgoCD"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

helm upgrade --install "${ARGOCD_RELEASE}" argo/argo-cd \
  --version 7.7.11 \
  --namespace "${ARGOCD_NAMESPACE}" --create-namespace \
  --kubeconfig "${KUBECONFIG_PATH}" \
  -f "${REPO_ROOT}/gitops/infrastructure/argocd/values.yaml" \
  --wait --timeout 5m

kubectl_ctx -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server --timeout=180s

log_step "Saving initial admin password"
mkdir -p "${REPO_ROOT}/secrets-vault"
kubectl_ctx -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d > "${REPO_ROOT}/secrets-vault/argocd-admin-password.txt"
log_warn "ArgoCD admin password saved to secrets-vault/argocd-admin-password.txt (gitignored). Change it after first login."

log_info "ArgoCD UI: https://${DOMAIN_ARGOCD} (once DNS/cert are set up) or:"
log_info "  kubectl --kubeconfig kubeconfig -n ${ARGOCD_NAMESPACE} port-forward svc/argocd-server 8080:443"
log_info "Login: admin / \$(cat secrets-vault/argocd-admin-password.txt)"
log_info "Next: ./scripts/09-generate-app-secrets.sh"
