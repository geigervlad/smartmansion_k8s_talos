#!/usr/bin/env bash
# Applies the per-node Talos machine configs generated in step 02 (discovering
# each VM's temporary DHCP "maintenance mode" IP by MAC address), bootstraps
# etcd on the first control-plane node, and fetches kubeconfig/talosconfig.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

OUT_DIR="${REPO_ROOT}/${TALOS_OUT_DIR}"

apply_one_node() {
  local i="$1"
  local name; name="$(node_name "${i}")"
  local target_ip="${NODE_IPS[$i]}"
  local cfg="${OUT_DIR}/${name}.yaml"
  [[ -f "${cfg}" ]] || die "${cfg} missing — run ./scripts/02-generate-talos-config.sh first."

  if talosctl_ctx -n "${target_ip}" -e "${target_ip}" version --short >/dev/null 2>&1; then
    log_info "${name} already reachable at ${target_ip} — config already applied, skipping."
    return 0
  fi

  log_step "Applying Talos config to ${name}"
  local mac; mac="$(node_mac_colon "${i}")"
  log_info "Looking for ${name} (MAC ${mac}) in DHCP maintenance mode on ${NETWORK_SUBNET_CIDR}..."
  local maint_ip
  if ! maint_ip="$(discover_ip_for_mac "${mac}" 300)"; then
    die "Could not find ${name} (MAC ${mac}) on the LAN. Is the VM running (VBoxManage list runningvms) and VBOX_BRIDGE_ADAPTER correct?"
  fi
  log_info "${name} is at ${maint_ip} (maintenance mode)."

  talosctl apply-config --insecure --nodes "${maint_ip}" --file "${cfg}"
  log_info "Config applied — ${name} will reboot and come up at its static IP ${target_ip}."

  wait_for "${name} to respond at ${target_ip}" 300 talosctl_ctx -n "${target_ip}" -e "${target_ip}" version --short
}

for_each_node apply_one_node

log_step "Recording control-plane endpoints in talosconfig"
CP_IPS=()
for i in "${!NODE_ROLES[@]}"; do
  [[ "${NODE_ROLES[$i]}" == "controlplane" ]] && CP_IPS+=("${NODE_IPS[$i]}")
done
talosctl_ctx config endpoint "${CP_IPS[@]}"
talosctl_ctx config node "${CP_IPS[@]}"

log_step "Bootstrapping etcd"
FIRST_CP_IDX="$(first_controlplane_index)"
FIRST_CP_IP="${NODE_IPS[$FIRST_CP_IDX]}"

if talosctl_ctx -n "${FIRST_CP_IP}" -e "${FIRST_CP_IP}" etcd status >/dev/null 2>&1; then
  log_info "etcd already bootstrapped."
else
  talosctl_ctx -n "${FIRST_CP_IP}" -e "${FIRST_CP_IP}" bootstrap
  wait_for "etcd to come up on ${FIRST_CP_IP}" 300 talosctl_ctx -n "${FIRST_CP_IP}" -e "${FIRST_CP_IP}" etcd status
fi

log_step "Fetching kubeconfig"
talosctl_ctx -n "${FIRST_CP_IP}" -e "${FIRST_CP_IP}" kubeconfig "${KUBECONFIG_PATH}" --force
log_info "Wrote ${KUBECONFIG_PATH} and ${TALOSCONFIG_PATH}"

log_warn "Nodes will show NotReady until Cilium (the CNI) is installed — that's expected, not an error."
log_info "Next: ./scripts/04-install-cilium.sh"
