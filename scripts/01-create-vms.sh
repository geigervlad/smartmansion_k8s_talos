#!/usr/bin/env bash
# Creates the 6 VirtualBox VMs (3 controlplane + 3 worker) defined in
# config/cluster.env and boots them from a Talos Image Factory ISO that has
# the iscsi-tools + util-linux-tools extensions baked in (required by
# Longhorn later). Idempotent: existing VMs are left untouched.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

log_step "Resolving Talos Image Factory schematic (Longhorn extensions)"
SCHEMATIC_ID="$(ensure_talos_schematic_id)"
log_info "Schematic ID: ${SCHEMATIC_ID}"
ISO_PATH="$(talos_iso_path "${SCHEMATIC_ID}")"

if file_exists_nonempty "${ISO_PATH}"; then
  log_info "ISO already downloaded: ${ISO_PATH}"
else
  log_step "Downloading Talos ISO (this includes iscsi-tools + util-linux-tools)"
  ISO_URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/metal-amd64.iso"
  curl -fSL --progress-bar -o "${ISO_PATH}.part" "${ISO_URL}"
  mv "${ISO_PATH}.part" "${ISO_PATH}"
  log_info "Saved to ${ISO_PATH}"
fi

create_one_vm() {
  local i="$1"
  local name; name="$(node_full_name "${i}")"

  if vm_exists "${i}"; then
    log_info "VM ${name} already exists, skipping creation."
    return 0
  fi

  log_step "Creating VM ${name} (${NODE_ROLES[$i]}, ${NODE_CPUS[$i]} vCPU, ${NODE_RAM_MB[$i]}MB RAM)"

  local vmdir; vmdir="$(VBoxManage list systemproperties | awk -F: '/Default machine folder/ {gsub(/^[ \t]+/,"",$2); print $2}')"
  local osdisk="${vmdir}/${name}/${name}-os.vdi"
  local lhdisk="${vmdir}/${name}/${name}-longhorn.vdi"

  VBoxManage createvm --name "${name}" --ostype Linux_64 --register

  VBoxManage modifyvm "${name}" \
    --cpus "${NODE_CPUS[$i]}" \
    --memory "${NODE_RAM_MB[$i]}" \
    --nic1 bridged --bridgeadapter1 "${VBOX_BRIDGE_ADAPTER}" \
    --macaddress1 "$(node_mac_nocolon "${i}")" \
    --boot1 dvd --boot2 disk --boot3 none --boot4 none \
    --audio-driver none \
    --usb off --usbehci off

  VBoxManage storagectl "${name}" --name SATA --add sata --controller IntelAhci --portcount 4

  VBoxManage createmedium disk --filename "${osdisk}" --size "$(( NODE_OS_DISK_GB[i] * 1024 ))" --format VDI
  VBoxManage storageattach "${name}" --storagectl SATA --port 0 --device 0 --type hdd --medium "${osdisk}"

  VBoxManage storageattach "${name}" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "${ISO_PATH}"

  if [[ "${NODE_LONGHORN_DISK_GB[$i]}" -gt 0 ]]; then
    VBoxManage createmedium disk --filename "${lhdisk}" --size "$(( NODE_LONGHORN_DISK_GB[i] * 1024 ))" --format VDI
    VBoxManage storageattach "${name}" --storagectl SATA --port 2 --device 0 --type hdd --medium "${lhdisk}"
    log_info "Attached ${NODE_LONGHORN_DISK_GB[$i]}GB Longhorn disk to ${name}."
  fi

  log_info "Starting ${name} headless..."
  VBoxManage startvm "${name}" --type headless
}

for_each_node create_one_vm

log_step "All VMs created/started"
log_info "Bridge adapter in use: ${VBOX_BRIDGE_ADAPTER} (verify with 'VBoxManage list bridgedifs' if VMs don't get LAN IPs)"
log_info "Next: ./scripts/02-generate-talos-config.sh"
