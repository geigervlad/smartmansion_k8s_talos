#!/usr/bin/env bash
# The one place that collects/generates every secret this repo needs and
# seals each into the gitops/ tree as a SealedSecret — safe to commit, only
# decryptable by the SealedSecrets controller running in this specific
# cluster (see scripts/05-install-sealed-secrets.sh).
#
# Two kinds of secret:
#   - Manually-provided (deSEC API token, Strato DynDNS login): can't be
#     generated, prompted for interactively once and cached in
#     secrets-vault/manual-credentials.env (gitignored) so re-runs don't ask again.
#   - Auto-generated (Nextcloud/OnlyOffice passwords): random, generated once
#     and cached in secrets-vault/app-secrets.env (gitignored).
#
# Re-running this script is safe: it only ever fills in what's missing, it
# never rotates an existing SealedSecret (that would desync from whatever
# password the app was already provisioned with).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

VAULT="${REPO_ROOT}/secrets-vault"
CREDS_FILE="${VAULT}/manual-credentials.env"
APP_SECRETS_FILE="${VAULT}/app-secrets.env"
mkdir -p "${VAULT}"

[[ -s "${PUB_CERT_PATH}" ]] || die "Missing ${PUB_CERT_PATH} — run ./scripts/05-install-sealed-secrets.sh first."

log_step "Collecting manually-provided credentials"

touch "${CREDS_FILE}"
# shellcheck disable=SC1090
source "${CREDS_FILE}"

prompt_if_missing() {
  local var_name="$1" prompt_text="$2" secret_input="${3:-false}" value
  if [[ -z "${!var_name:-}" ]]; then
    if [[ "${secret_input}" == "true" ]]; then
      read -r -s -p "${prompt_text}: " value; echo
    else
      read -r -p "${prompt_text}: " value
    fi
    printf -v "${var_name}" '%s' "${value}"
    echo "${var_name}=${value}" >> "${CREDS_FILE}"
  fi
}

prompt_if_missing DESEC_API_TOKEN "deSEC API token (see docu/09-cert-manager-dns.md)" true
prompt_if_missing STRATO_DYNDNS_USER "Strato DynDNS username"
prompt_if_missing STRATO_DYNDNS_PASSWORD "Strato DynDNS password" true
chmod 600 "${CREDS_FILE}"

log_step "Sealing infrastructure credentials"

DESEC_SECRET_OUT="${REPO_ROOT}/gitops/infrastructure/cert-manager/manifests/desec-token-sealed-secret.yaml"
if file_exists_nonempty "${DESEC_SECRET_OUT}"; then
  log_info "desec-token SealedSecret already exists, skipping."
else
  seal_secret_literals desec-token cert-manager "${DESEC_SECRET_OUT}" -- "token=${DESEC_API_TOKEN}"
  log_info "Wrote gitops/infrastructure/cert-manager/manifests/desec-token-sealed-secret.yaml"
fi

DYNDNS_SECRET_OUT="${REPO_ROOT}/gitops/infrastructure/dyndns-updater/dyndns-sealed-secret.yaml"
if file_exists_nonempty "${DYNDNS_SECRET_OUT}"; then
  log_info "dyndns-strato-credentials SealedSecret already exists, skipping."
else
  seal_secret_literals dyndns-strato-credentials dyndns-updater "${DYNDNS_SECRET_OUT}" -- \
    "username=${STRATO_DYNDNS_USER}" "password=${STRATO_DYNDNS_PASSWORD}"
  log_info "Wrote gitops/infrastructure/dyndns-updater/dyndns-sealed-secret.yaml"
fi

log_step "Generating app secrets"

touch "${APP_SECRETS_FILE}"
generate_once() {
  local var="$1" len="${2:-24}"
  grep -q "^${var}=" "${APP_SECRETS_FILE}" 2>/dev/null || echo "${var}=$(random_password "${len}")" >> "${APP_SECRETS_FILE}"
}
generate_once NEXTCLOUD_ADMIN_PASSWORD
generate_once NEXTCLOUD_DB_ROOT_PASSWORD
generate_once NEXTCLOUD_DB_PASSWORD
generate_once ONLYOFFICE_JWT_SECRET 32
chmod 600 "${APP_SECRETS_FILE}"
# shellcheck disable=SC1090
source "${APP_SECRETS_FILE}"

log_step "Sealing app secrets"

# Single secret shared by the nextcloud/nextcloud chart's own
# existingSecret (nextcloud-username/nextcloud-password keys) and its bundled
# mariadb subchart's existingSecret (mariadb-root-password/mariadb-password
# keys) — see gitops/apps/nextcloud/values.yaml. onlyoffice-jwt-secret is
# extra data for the one-time manual OnlyOffice connector setup documented in
# docu/08-onlyoffice.md, not read by the Helm chart itself.
NEXTCLOUD_SECRET_OUT="${REPO_ROOT}/gitops/apps/nextcloud/sealed-secret.yaml"
if file_exists_nonempty "${NEXTCLOUD_SECRET_OUT}"; then
  log_info "nextcloud SealedSecret already exists, skipping."
else
  seal_secret_literals nextcloud-secrets nextcloud "${NEXTCLOUD_SECRET_OUT}" -- \
    "nextcloud-username=admin" \
    "nextcloud-password=${NEXTCLOUD_ADMIN_PASSWORD}" \
    "mariadb-root-password=${NEXTCLOUD_DB_ROOT_PASSWORD}" \
    "mariadb-password=${NEXTCLOUD_DB_PASSWORD}" \
    "onlyoffice-jwt-secret=${ONLYOFFICE_JWT_SECRET}"
  log_info "Wrote gitops/apps/nextcloud/sealed-secret.yaml"
fi

ONLYOFFICE_SECRET_OUT="${REPO_ROOT}/gitops/apps/onlyoffice/sealed-secret.yaml"
if file_exists_nonempty "${ONLYOFFICE_SECRET_OUT}"; then
  log_info "onlyoffice SealedSecret already exists, skipping."
else
  seal_secret_literals onlyoffice-secrets onlyoffice "${ONLYOFFICE_SECRET_OUT}" -- \
    "jwt-secret=${ONLYOFFICE_JWT_SECRET}"
  log_info "Wrote gitops/apps/onlyoffice/sealed-secret.yaml"
fi

log_warn "Raw values are in secrets-vault/app-secrets.env and secrets-vault/manual-credentials.env (both gitignored)."
log_warn "Nextcloud admin login will be: admin / (see NEXTCLOUD_ADMIN_PASSWORD in secrets-vault/app-secrets.env)"
log_info "Next: ./scripts/10-bootstrap-argocd-apps.sh"
