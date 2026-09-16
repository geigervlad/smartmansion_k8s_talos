#!/usr/bin/env bash
# Installs cert-manager, then the vendored community deSEC DNS-01 webhook
# (gitops/infrastructure/cert-manager/manifests/desec-webhook.yaml — see
# docu/09-cert-manager-dns.md for why this path was chosen over the
# officially-supported alternatives) and the ClusterIssuers that use it.
#
# This script does NOT create the desec-token secret — that's a manually
# obtained credential, collected and sealed by scripts/09-generate-app-secrets.sh.
# Real certificates won't issue until that secret exists AND the Strato NS
# delegation described in docu/09-cert-manager-dns.md is done; neither
# blocks this script from completing.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

CM_NAMESPACE="cert-manager"

log_step "Installing cert-manager"

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo update jetstack >/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  --version v1.16.2 \
  --namespace "${CM_NAMESPACE}" --create-namespace \
  --kubeconfig "${KUBECONFIG_PATH}" \
  -f "${REPO_ROOT}/gitops/infrastructure/cert-manager/values.yaml" \
  --wait --timeout 3m

kubectl_ctx -n "${CM_NAMESPACE}" rollout status deployment/cert-manager --timeout=180s
kubectl_ctx -n "${CM_NAMESPACE}" rollout status deployment/cert-manager-webhook --timeout=180s
kubectl_ctx -n "${CM_NAMESPACE}" rollout status deployment/cert-manager-cainjector --timeout=180s

log_step "Deploying the deSEC DNS-01 webhook"
kubectl_ctx apply -f "${REPO_ROOT}/gitops/infrastructure/cert-manager/manifests/desec-webhook.yaml"

log_info "Waiting for the desec-webhook APIService to become Available (can take ~1-2min for its self-signed cert chain to issue)..."
apiservice_available() {
  kubectl_ctx get apiservice v1alpha1.acme.ukmetrics.ca \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q True
}
wait_for "desec-webhook APIService Available" 180 apiservice_available

log_step "Applying ClusterIssuers (letsencrypt-staging, letsencrypt-prod, selfsigned fallback)"
kubectl_ctx apply -f "${REPO_ROOT}/gitops/infrastructure/cert-manager/manifests/cluster-issuers.yaml"

log_warn "Real Let's Encrypt certs won't issue yet — two things are still needed:"
log_warn "  1. scripts/09-generate-app-secrets.sh must seal your deSEC API token into"
log_warn "     gitops/infrastructure/cert-manager/manifests/desec-token-sealed-secret.yaml"
log_warn "  2. The one-time Strato NS delegation for _acme-challenge.<domain> -> deSEC."
log_warn "See docu/09-cert-manager-dns.md for the exact steps. Neither blocks the rest of this pipeline."
log_info "Next: ./scripts/07-install-storage.sh"
