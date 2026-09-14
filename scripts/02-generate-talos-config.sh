#!/usr/bin/env bash
# Generates the cluster-wide Talos secrets/CA + controlplane.yaml/worker.yaml
# (once, idempotent), then renders one final per-node machine config with the
# node's static IP/hostname/install-image baked in.
#
# NOTE: talosctl's exact `machineconfig patch` flags have moved around
# between versions — if this errors, check `talosctl machineconfig patch --help`
# (or `talosctl gen config --help`) against your installed version and adjust.
# See docu/02-talos-setup.md.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

OUT_DIR="${REPO_ROOT}/${TALOS_OUT_DIR}"
mkdir -p "${OUT_DIR}"

SCHEMATIC_ID="$(ensure_talos_schematic_id)"
INSTALL_IMAGE="$(talos_install_image "${SCHEMATIC_ID}")"

log_step "Generating base Talos machine configs (cluster secrets/CA, controlplane.yaml, worker.yaml)"

if [[ -f "${OUT_DIR}/controlplane.yaml" && -f "${OUT_DIR}/worker.yaml" && -f "${OUT_DIR}/talosconfig" ]]; then
  log_info "Base configs already exist in ${OUT_DIR} — not regenerating."
  log_info "(Regenerating would rotate the cluster CA/secrets and break an already-bootstrapped cluster;"
  log_info " delete controlplane.yaml, worker.yaml and talosconfig there yourself if you really want a fresh identity.)"
else
  talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
    --output-dir "${OUT_DIR}" \
    --config-patch "@${REPO_ROOT}/talos/patches/common.yaml" \
    --config-patch-control-plane "@${REPO_ROOT}/talos/patches/controlplane.yaml" \
    --config-patch-worker "@${REPO_ROOT}/talos/patches/worker.yaml"
  log_info "Wrote controlplane.yaml, worker.yaml, talosconfig to ${OUT_DIR}"
fi

cp "${OUT_DIR}/talosconfig" "${TALOSCONFIG_PATH}"

log_step "Rendering per-node machine configs (static IP, hostname, install image, VIP)"

render_node_config() {
  local i="$1"
  local role="${NODE_ROLES[$i]}"
  local name; name="$(node_name "${i}")"
  local base="${OUT_DIR}/controlplane.yaml"
  [[ "${role}" == "worker" ]] && base="${OUT_DIR}/worker.yaml"
  local patch_file="${OUT_DIR}/${name}.patch.yaml"
  local out_file="${OUT_DIR}/${name}.yaml"

  {
    echo "machine:"
    echo "  network:"
    echo "    hostname: ${name}"
    echo "    interfaces:"
    echo "      - interface: eth0"
    echo "        dhcp: false"
    echo "        addresses:"
    echo "          - ${NODE_IPS[$i]}/24"
    echo "        routes:"
    echo "          - network: 0.0.0.0/0"
    echo "            gateway: ${NETWORK_GATEWAY}"
    if [[ "${role}" == "controlplane" ]]; then
      echo "        vip:"
      echo "          ip: ${CLUSTER_VIP}"
    fi
    echo "    nameservers:"
    echo "      - ${NETWORK_DNS_SERVERS}"
    echo "  install:"
    echo "    image: ${INSTALL_IMAGE}"
    echo "    disk: /dev/sda"
    if [[ "${NODE_LONGHORN_DISK_GB[$i]}" -gt 0 ]]; then
      # Second VirtualBox disk (see scripts/01-create-vms.sh) formatted and
      # mounted for Longhorn. Assumes it enumerates as /dev/sdb — verify with
      # `talosctl get disks -n <ip>` if this node's disk layout differs.
      echo "  disks:"
      echo "    - device: /dev/sdb"
      echo "      partitions:"
      echo "        - mountpoint: /var/lib/longhorn"
      echo "  kubelet:"
      echo "    extraMounts:"
      echo "      - destination: /var/lib/longhorn"
      echo "        type: bind"
      echo "        source: /var/lib/longhorn"
      echo "        options:"
      echo "          - bind"
      echo "          - rshared"
      echo "          - rw"
    fi
  } > "${patch_file}"

  talosctl machineconfig patch "${base}" --patch "@${patch_file}" -o "${out_file}"
  log_info "Rendered ${out_file} (${NODE_IPS[$i]}, role=${role})"
}

for_each_node render_node_config

log_info "Per-node configs written to ${OUT_DIR}/<node>.yaml"
log_info "Next: ./scripts/03-bootstrap-cluster.sh"
