#!/usr/bin/env bash
# Installs the Bitnami SealedSecrets controller, then immediately backs up
# its auto-generated private key — losing that key means every SealedSecret
# ever created (including the ones scripts/09-generate-app-secrets.sh is
# about to write) becomes permanently undecryptable.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SS_NAMESPACE="sealed-secrets"
SS_RELEASE="sealed-secrets"

log_step "Installing SealedSecrets controller"

helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
helm repo update sealed-secrets >/dev/null

helm upgrade --install "${SS_RELEASE}" sealed-secrets/sealed-secrets \
  --namespace "${SS_NAMESPACE}" --create-namespace \
  --kubeconfig "${KUBECONFIG_PATH}" \
  -f "${REPO_ROOT}/gitops/infrastructure/sealed-secrets/values.yaml" \
  --wait --timeout 3m

kubectl_ctx -n "${SS_NAMESPACE}" rollout status deployment/"${SS_RELEASE}" --timeout=180s

log_step "Backing up the SealedSecrets private key (CRITICAL)"
mkdir -p "${REPO_ROOT}/secrets-vault"
kubectl_ctx get secret -n "${SS_NAMESPACE}" \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o yaml > "${REPO_ROOT}/secrets-vault/sealed-secrets-key-backup.yaml"
log_warn "Backed up to secrets-vault/sealed-secrets-key-backup.yaml"
log_warn "Copy this file somewhere safe OUTSIDE this machine (USB stick, password manager vault, offline backup)."
log_warn "It is gitignored on purpose — never commit it."

log_step "Exporting the public cert (safe to commit — lets you seal secrets offline without cluster access)"
kubeseal --fetch-cert \
  --kubeconfig "${KUBECONFIG_PATH}" \
  --controller-name "${SS_RELEASE}" \
  --controller-namespace "${SS_NAMESPACE}" \
  > "${REPO_ROOT}/gitops/infrastructure/sealed-secrets/pub-cert.pem"
log_info "Wrote gitops/infrastructure/sealed-secrets/pub-cert.pem"

log_info "Next: ./scripts/06-install-cert-manager.sh"
