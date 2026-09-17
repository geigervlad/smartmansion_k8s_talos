#!/usr/bin/env bash
# Installs cert-manager, then the ClusterIssuers
# (gitops/infrastructure/cert-manager/manifests/cluster-issuers.yaml) — just
# one, a self-signed internal CA. No ACME account, no DNS-01 webhook, no
# public DNS involved at all — see docu/09-cert-manager-dns.md for why.
#
# Also exports the CA's public certificate to secrets-vault/smartmansion-ca.crt
# once it issues, so it's ready to import into your OS/browser trust store
# (a manual step, by design — see docu/09-cert-manager-dns.md; this script
# never touches your system trust store itself).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

CM_NAMESPACE="cert-manager"

log_step "Installing cert-manager"

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo update jetstack >/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  --version v1.21.2 \
  --namespace "${CM_NAMESPACE}" --create-namespace \
  --kubeconfig "${KUBECONFIG_PATH}" \
  -f "${REPO_ROOT}/gitops/infrastructure/cert-manager/values.yaml" \
  --wait --timeout 3m

kubectl_ctx -n "${CM_NAMESPACE}" rollout status deployment/cert-manager --timeout=180s
kubectl_ctx -n "${CM_NAMESPACE}" rollout status deployment/cert-manager-webhook --timeout=180s
kubectl_ctx -n "${CM_NAMESPACE}" rollout status deployment/cert-manager-cainjector --timeout=180s

log_step "Applying the internal CA ClusterIssuer"
kubectl_ctx apply -f "${REPO_ROOT}/gitops/infrastructure/cert-manager/manifests/cluster-issuers.yaml"

log_info "Waiting for the internal CA certificate to be issued..."
internal_ca_ready() {
  kubectl_ctx -n "${CM_NAMESPACE}" get certificate smartmansion-internal-ca \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True
}
wait_for "smartmansion-internal-ca certificate Ready" 120 internal_ca_ready

log_step "Exporting the internal CA certificate"
mkdir -p "${REPO_ROOT}/secrets-vault"
kubectl_ctx -n "${CM_NAMESPACE}" get secret smartmansion-internal-ca -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > "${REPO_ROOT}/secrets-vault/smartmansion-ca.crt"
log_warn "Wrote secrets-vault/smartmansion-ca.crt (gitignored — it's your device's trust decision, not something to commit)."
log_warn "Import it into your OS/browser trust store to avoid TLS warnings on *.localhost — see docu/09-cert-manager-dns.md. Not done automatically."
log_info "Next: ./scripts/07-install-storage.sh"
