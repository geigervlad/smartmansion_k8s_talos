#!/usr/bin/env bash
# The cluster-wide tail end, run once ALL 6 nodes are individually up
# (scripts/01-create-vms.sh creates + configures each node in turn before
# moving to the next, and already bootstraps etcd on the first
# control-plane node as soon as IT is up — see that script's header comment
# for why that isn't done here). This script just finalizes the
# talosconfig endpoint list to all 3 control-plane IPs (01 only needed
# cp1's) and fetches kubeconfig.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

log_step "Checking all nodes are reachable at their static IPs"
check_node_reachable() {
  local i="$1" name; name="$(node_name "${i}")"
  talosctl_ctx -n "${NODE_IPS[$i]}" -e "${NODE_IPS[$i]}" version --short >/dev/null 2>&1 \
    || die "${name} (${NODE_IPS[$i]}) is not reachable — run ./scripts/01-create-vms.sh first (it creates AND configures each node, and bootstraps etcd on the first control-plane node)."
}
for_each_node check_node_reachable
log_info "All ${NODE_COUNT} nodes reachable."

log_step "Recording all control-plane endpoints in talosconfig"
CP_IPS=()
for i in "${!NODE_ROLES[@]}"; do
  [[ "${NODE_ROLES[$i]}" == "controlplane" ]] && CP_IPS+=("${NODE_IPS[$i]}")
done
talosctl_ctx config endpoint "${CP_IPS[@]}"
talosctl_ctx config node "${CP_IPS[@]}"

FIRST_CP_IDX="$(first_controlplane_index)"
FIRST_CP_IP="${NODE_IPS[$FIRST_CP_IDX]}"

if ! talosctl_ctx_t -n "${FIRST_CP_IP}" -e "${FIRST_CP_IP}" etcd status >/dev/null 2>&1; then
  die "etcd is not bootstrapped on ${NODE_NAMES[$FIRST_CP_IDX]} (${FIRST_CP_IP}) — run ./scripts/01-create-vms.sh first, it bootstraps etcd on the first control-plane node automatically."
fi

log_step "Fetching kubeconfig"
talosctl_ctx -n "${FIRST_CP_IP}" -e "${FIRST_CP_IP}" kubeconfig "${KUBECONFIG_PATH}" --force
log_info "Wrote ${KUBECONFIG_PATH} and ${TALOSCONFIG_PATH}"

log_warn "Nodes will show NotReady until Cilium (the CNI) is installed — that's expected, not an error."
log_info "Next: ./scripts/04-install-cilium.sh"
