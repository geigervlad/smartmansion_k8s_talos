#!/usr/bin/env bash
# Adds one hosts-file entry per DOMAIN_* in config/cluster.env, all pointing
# at INGRESS_VIP — this is the ONLY thing that makes
# https://nextcloud.localhost/etc. resolve at all, since this project uses
# no real DNS (see docu/09-cert-manager-dns.md).
#
# Idempotent and safe to re-run: everything this script writes lives inside
# one clearly marked block, replaced wholesale on every run (so an IP change
# in config/cluster.env just needs a re-run) — nothing outside that block is
# ever touched.
#
# Needs an elevated (Administrator) shell — C:\Windows\System32\drivers\etc\hosts
# is not writable otherwise. This is a genuine one-off exception to "run
# everything as yourself, not as admin" for this repo: editing that file
# has no non-admin equivalent on Windows.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

HOSTS_FILE="/c/Windows/System32/drivers/etc/hosts"
MARKER_BEGIN="# BEGIN smartmansion-k8s-talos (managed by scripts/11-configure-hosts.sh — do not edit by hand)"
MARKER_END="# END smartmansion-k8s-talos"

[[ -f "${HOSTS_FILE}" ]] || die "Hosts file not found at ${HOSTS_FILE} — this script assumes Windows. Add the entries manually if you're on a different OS."
[[ -w "${HOSTS_FILE}" ]] || die "Cannot write ${HOSTS_FILE} — re-run this script from an Administrator shell (right-click Git Bash/your terminal -> \"Run as administrator\")."

log_step "Updating ${HOSTS_FILE}"

tmp_stripped="$(mktemp)"
# Strip any previously-managed block first (idempotent re-run) — everything
# else in the file is left byte-for-byte untouched.
awk -v b="${MARKER_BEGIN}" -v e="${MARKER_END}" '
  $0 == b {skip=1; next}
  $0 == e {skip=0; next}
  !skip {print}
' "${HOSTS_FILE}" > "${tmp_stripped}"

tmp_new="$(mktemp)"
{
  cat "${tmp_stripped}"
  echo "${MARKER_BEGIN}"
  echo "${INGRESS_VIP} ${DOMAIN_NEXTCLOUD}"
  echo "${INGRESS_VIP} ${DOMAIN_HOMEASSISTANT}"
  echo "${INGRESS_VIP} ${DOMAIN_ONLYOFFICE}"
  echo "${INGRESS_VIP} ${DOMAIN_ARGOCD}"
  echo "${MARKER_END}"
} > "${tmp_new}"

cp "${tmp_new}" "${HOSTS_FILE}"
rm -f "${tmp_stripped}" "${tmp_new}"

log_info "Wrote:"
log_info "  ${INGRESS_VIP} ${DOMAIN_NEXTCLOUD}"
log_info "  ${INGRESS_VIP} ${DOMAIN_HOMEASSISTANT}"
log_info "  ${INGRESS_VIP} ${DOMAIN_ONLYOFFICE}"
log_info "  ${INGRESS_VIP} ${DOMAIN_ARGOCD}"

log_warn "If a domain doesn't resolve right away, Windows may have cached the old (missing) answer — run: ipconfig /flushdns"
log_warn "NOTE on .localhost specifically: some browsers/resolvers hardcode the whole *.localhost TLD to 127.0.0.1 and ignore the hosts file for it entirely (RFC 6761) — Windows itself respects the hosts file first, but if a specific browser doesn't reach ${INGRESS_VIP} for these domains, that's why. See docu/09-cert-manager-dns.md for the fix (switch to a non-reserved suffix)."
log_info "Pipeline complete. Browse to https://${DOMAIN_NEXTCLOUD}, https://${DOMAIN_HOMEASSISTANT}, https://${DOMAIN_ONLYOFFICE}, https://${DOMAIN_ARGOCD}"
log_info "First visit to each will show a certificate warning until you import secrets-vault/smartmansion-ca.crt — see docu/09-cert-manager-dns.md."
