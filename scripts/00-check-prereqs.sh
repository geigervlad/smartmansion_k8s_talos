#!/usr/bin/env bash
# Verifies every CLI tool the rest of the pipeline depends on is installed
# before we touch VirtualBox or the cluster.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

log_step "Checking prerequisites"

require_cmd VBoxManage talosctl kubectl helm kubeseal argocd git openssl jq curl nmap

log_info "Found: VBoxManage $(VBoxManage --version 2>/dev/null || echo '?')"
log_info "Found: talosctl $(talosctl version --client --short 2>/dev/null | head -n1 || echo '?')"
log_info "Found: kubectl $(kubectl version --client -o=json 2>/dev/null | jq -r .clientVersion.gitVersion || echo '?')"
log_info "Found: helm $(helm version --short 2>/dev/null || echo '?')"
log_info "Found: kubeseal $(kubeseal --version 2>/dev/null || echo '?')"
log_info "Found: argocd $(argocd version --client --short 2>/dev/null || echo '?')"

if [[ "${#NODE_NAMES[@]}" -ne "${#NODE_ROLES[@]}" || "${#NODE_NAMES[@]}" -ne "${#NODE_IPS[@]}" \
   || "${#NODE_NAMES[@]}" -ne "${#NODE_CPUS[@]}" || "${#NODE_NAMES[@]}" -ne "${#NODE_RAM_MB[@]}" \
   || "${#NODE_NAMES[@]}" -ne "${#NODE_OS_DISK_GB[@]}" || "${#NODE_NAMES[@]}" -ne "${#NODE_LONGHORN_DISK_GB[@]}" ]]; then
  die "config/cluster.env: NODE_* arrays must all have the same length (currently: ${#NODE_NAMES[@]} names, ${#NODE_ROLES[@]} roles, ${#NODE_IPS[@]} ips, ${#NODE_CPUS[@]} cpus, ${#NODE_RAM_MB[@]} ram, ${#NODE_OS_DISK_GB[@]} os-disks, ${#NODE_LONGHORN_DISK_GB[@]} longhorn-disks)"
fi

cp_count=0
for role in "${NODE_ROLES[@]}"; do
  [[ "${role}" == "controlplane" ]] && cp_count=$((cp_count + 1))
done
if [[ "${cp_count}" -eq 0 ]]; then
  die "config/cluster.env: no node has role=controlplane"
fi
log_info "Node layout OK: ${NODE_COUNT} nodes total, ${cp_count} controlplane."

if [[ "${GITOPS_REPO_URL}" == *"REPLACE_ME"* ]]; then
  log_warn "GITOPS_REPO_URL in config/cluster.env is still a placeholder (${GITOPS_REPO_URL})."
  log_warn "10-bootstrap-argocd-apps.sh will refuse to push until you set the real GitHub URL."
fi

mkdir -p "${REPO_ROOT}/${TALOS_OUT_DIR}" "${REPO_ROOT}/secrets-vault"

log_info "Prerequisite check passed."
