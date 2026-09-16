#!/usr/bin/env bash
# Brings up all 6 nodes ONE AT A TIME: create the VM, start it, apply its
# Talos config, wait for it to come up on its static IP — fully finishing
# one node before touching the next. Deliberately NOT "create all 6 VMs,
# then configure all 6" — if a node has a problem, this surfaces and stops
# on it immediately instead of burning time creating 5 more VMs first.
#
# The FIRST control-plane node also gets etcd bootstrapped (`talosctl
# bootstrap`) immediately after it comes up, before the second node is even
# created — not at the very end after all 6 nodes exist. This is safe and
# deliberate, not just for-fun ordering:
#   - etcd bootstrap is a ONE-TIME action on exactly one seed node. Every
#     other control-plane node joins that already-initialized etcd
#     automatically (dynamic membership) once ITS config is applied — there
#     is no separate "bootstrap" step for cp2/cp3, so there's nothing wrong
#     with doing cp1's bootstrap before cp2 exists.
#   - etcd membership changes are safest applied one at a time (this script
#     already brings up nodes sequentially, so this falls out for free).
#   - Cilium (the CNI) is NOT required for any of this: etcd/apiserver/
#     scheduler/controller-manager all run on hostNetwork, independent of
#     any CNI. Cilium only matters for pod-to-pod traffic between nodes and
#     for kubelet reporting Ready instead of NotReady — irrelevant during
#     node bootstrap itself. Cilium install stays a separate, later step
#     (scripts/04-install-cilium.sh), deliberately after all 6 nodes are up.
#
# Downloads a Talos Image Factory ISO with the iscsi-tools + util-linux-tools
# extensions baked in (historical: added for Longhorn, unused now that this
# project runs local-path-provisioner instead — see docu/02-talos-setup.md
# — but already baked into all 6 nodes and harmless to leave) and generates
# the cluster-wide Talos secrets/base config once up front — both are pure
# local file operations with no VM dependency, safe to do before any VM exists.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

log_step "Resolving Talos Image Factory schematic"
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

log_step "Generating base Talos machine config (cluster secrets/CA)"
ensure_base_talos_config

# 0 = reachable and healthy
# 1 = genuinely unreachable (not configured yet, or actually down)
# 2 = reachable but cert not yet valid (clock skew, will self-resolve)
#
# Distinguishes "genuinely not configured yet" from "already installed, just
# briefly clock-skewed" (a freshly-installed node's clock can be a couple of
# minutes ahead of true time until NTP corrects it, making its own
# just-minted cert look "not yet valid" for a little while — confirmed
# harmless and self-resolving). Classifying this precisely, instead of
# treating every failure the same, avoids wastefully running the full
# VM-creation + ARP-discovery dance (100s+) for a node that's actually
# already fine and just needs a few more seconds.
check_node_status() {
  local ip="$1" out rc
  out="$(talosctl_ctx -n "${ip}" -e "${ip}" version --short 2>&1)"
  rc=$?
  [[ ${rc} -eq 0 ]] && return 0
  [[ "${out}" == *"not yet valid"* ]] && return 2
  return 1
}

# Returns once the node is confirmed reachable at its static IP. Does NOT
# eject the ISO or touch etcd — the caller (create_and_configure_one_node)
# does that once, after this returns, regardless of which path got there.
bring_up_one_node() {
  local i="$1"
  local name; name="$(node_full_name "${i}")"
  local node_short; node_short="$(node_name "${i}")"
  local target_ip="${NODE_IPS[$i]}"

  log_step "Node ${node_short} (${i}/${NODE_COUNT}): ${name}"

  # `|| status=$?`, not a bare call: this whole script runs under `set -e`,
  # so an unguarded `check_node_status "${target_ip}"` returning non-zero
  # (status 1, the ordinary "not configured yet" case for most nodes) would
  # kill the entire script right here, before the case below even runs.
  local status=0
  check_node_status "${target_ip}" || status=$?
  case "${status}" in
    0)
      log_info "${node_short} already reachable at ${target_ip} — fully configured, skipping."
      return 0
      ;;
    2)
      log_warn "${node_short} is already installed but its clock is briefly ahead of true time (cert not yet valid) — waiting for it to catch up, NOT re-provisioning. See docu/11-troubleshooting.md if this takes more than ~4 minutes."
      wait_for "${node_short}'s clock to catch up at ${target_ip}" 240 check_node_status "${target_ip}"
      log_info "${node_short} confirmed reachable at ${target_ip} — nothing to apply."
      return 0
      ;;
  esac

  # --- create + start the VM -------------------------------------------------
  local vmdir; vmdir="$(VBoxManage list systemproperties | sed -n 's/^Default machine folder:[[:space:]]*//p')"
  local osdisk="${vmdir}/${name}/${name}-os.vdi"
  local lhdisk="${vmdir}/${name}/${name}-longhorn.vdi"

  if ! vm_running "${i}"; then
    if vm_exists "${i}"; then
      log_info "VM ${name} already exists — re-applying settings (cheap, catches a previous failed/partial run) before starting it."
    else
      log_info "Creating VM ${name} (${NODE_ROLES[$i]}, ${NODE_CPUS[$i]} vCPU, ${NODE_RAM_MB[$i]}MB RAM)"
      VBoxManage createvm --name "${name}" --ostype Linux_64 --register
    fi

    # Safe to re-run on a stopped, already-existing VM — this is what
    # actually fixes a VM that was created with e.g. a wrong bridge adapter
    # name earlier.
    #
    # --boot1 disk --boot2 dvd (disk BEFORE dvd): on first boot the disk is
    # blank, so BIOS falls through to the ISO and Talos installs itself;
    # every boot after that finds a valid install on disk and boots straight
    # from there, never touching the ISO again. scripts/lib/common.sh's
    # eject_iso_if_present() also explicitly ejects the ISO once this node
    # confirms it installed, as a second safety net on top of this.
    #
    # --nicpromisc1 allow-all works around a real, confirmed issue: bridging
    # over Wi-Fi (as opposed to wired Ethernet) can silently blackhole
    # traffic to/from the VMs' own MACs otherwise — see VBOX_BRIDGE_ADAPTER's
    # comment in config/cluster.env. Harmless if you're on wired Ethernet.
    #
    # --graphicscontroller vmsvga --vram 128: without this, VMs have been
    # observed to hang at startup (confirmed on this host) — the default
    # graphics controller is the problem, VMSVGA + enough VRAM avoids it
    # even though these VMs run headless. --accelerate3d is deliberately
    # OFF: turning it on caused a DIFFERENT hang, during shutdown/reboot
    # ("rcu_sched self-detected stall", "sched: DL replenish lagged too
    # much") — VirtualBox's 3D pass-through introducing erratic scheduling
    # latency into the guest, not a host resource problem. A headless Talos
    # node has no use for 3D acceleration anyway.
    #
    # --paravirtprovider hyperv (EXPERIMENTAL, unlike the fixes above which
    # are confirmed): VirtualBox's "default" for a Linux guest exposes a KVM
    # paravirt interface, but on a host with Hyper-V/WSL2/Docker Desktop
    # enabled, VirtualBox itself actually runs guests via the Windows
    # Hypervisor Platform (NEM) — i.e. really on top of Hyper-V. Pretending
    # to be KVM emulates a clocksource that isn't really there; exposing the
    # real Hyper-V paravirt interface (Linux supports it too, CONFIG_HYPERV)
    # may give the guest a more accurate, less jittery clock reference
    # instead, which could reduce the false-positive RCU/scheduler-stall
    # warnings documented in docu/11-troubleshooting.md. Unlike
    # TSCTiedToExecution, VirtualBox does NOT reject this under NEM. If it
    # doesn't help (or makes things worse), drop back to `--paravirtprovider
    # kvm` (or remove the flag — "default" resolves to kvm for Linux guests
    # anyway) and re-run this script.
    VBoxManage modifyvm "${name}" \
      --cpus "${NODE_CPUS[$i]}" \
      --memory "${NODE_RAM_MB[$i]}" \
      --nic1 bridged --bridgeadapter1 "${VBOX_BRIDGE_ADAPTER}" \
      --nicpromisc1 allow-all \
      --macaddress1 "$(node_mac_nocolon "${i}")" \
      --boot1 disk --boot2 dvd --boot3 none --boot4 none \
      --graphicscontroller vmsvga --vram 128 --accelerate3d off \
      --paravirtprovider hyperv \
      --audio-driver none \
      --usb off --usbehci off

    # NOT setting VBoxInternal/TM/TSCTiedToExecution here — tried it as a
    # targeted fix for VMs hanging with "rcu_sched self-detected stall" /
    # "sched: DL replenish lagged too much", but VirtualBox rejects it
    # outright ("not supported in NEM mode") whenever it's running under the
    # Windows Hypervisor Platform execution engine — which it always is on
    # this host, because Hyper-V/WSL2/Docker Desktop being enabled forces
    # VirtualBox into NEM instead of native VT-x. If you're on a host
    # WITHOUT Hyper-V enabled (native VT-x), this setting might genuinely
    # help and is worth trying; check first with
    # `VBoxManage showvminfo <vm> | Select-String Execution` — if it says
    # HM/VT-x rather than NEM, TSCTiedToExecution can actually be set.

    VBoxManage showvminfo "${name}" --machinereadable 2>/dev/null | grep -q '^storagecontrollername0=' \
      || VBoxManage storagectl "${name}" --name SATA --add sata --controller IntelAhci --portcount 4

    if [[ ! -f "${osdisk}" ]]; then
      VBoxManage createmedium disk --filename "${osdisk}" --size "$(( NODE_OS_DISK_GB[i] * 1024 ))" --format VDI
      VBoxManage storageattach "${name}" --storagectl SATA --port 0 --device 0 --type hdd --medium "${osdisk}"
    fi

    VBoxManage storageattach "${name}" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "${ISO_PATH}"

    if [[ "${NODE_LONGHORN_DISK_GB[$i]}" -gt 0 && ! -f "${lhdisk}" ]]; then
      VBoxManage createmedium disk --filename "${lhdisk}" --size "$(( NODE_LONGHORN_DISK_GB[i] * 1024 ))" --format VDI
      VBoxManage storageattach "${name}" --storagectl SATA --port 2 --device 0 --type hdd --medium "${lhdisk}"
      log_info "Attached ${NODE_LONGHORN_DISK_GB[$i]}GB storage disk to ${name}."
    fi

    log_info "Starting ${name} headless..."
    VBoxManage startvm "${name}" --type headless
  else
    log_info "${name} already running."
  fi

  # --- render this node's Talos config ---------------------------------------
  render_node_config_file "${i}"

  # --- find it in DHCP maintenance mode and apply the config ------------------
  local mac; mac="$(node_mac_colon "${i}")"
  log_info "Looking for ${node_short} (MAC ${mac}) in DHCP maintenance mode on ${NETWORK_SUBNET_CIDR}..."
  local maint_ip
  if ! maint_ip="$(discover_ip_for_mac "${mac}" 300)"; then
    die "Could not find ${node_short} (MAC ${mac}) on the LAN. Is the VM running (VBoxManage list runningvms) and VBOX_BRIDGE_ADAPTER correct?"
  fi

  # Rare fallback, not the primary path (check_node_status above handles the
  # common case): if discovery still comes back with the node's own static
  # IP instead of a DHCP address, it isn't really in maintenance mode —
  # re-check securely rather than firing --insecure apply-config at an
  # already-configured node (always rejected, wasting 3 retries on nothing).
  if [[ "${maint_ip}" == "${target_ip}" ]]; then
    log_warn "${node_short}'s discovered IP (${maint_ip}) is its own static IP, not a DHCP address — it's probably already configured."
    wait_for "${node_short} to respond at ${target_ip}" 240 check_node_status "${target_ip}"
    log_info "${node_short} confirmed reachable at ${target_ip} — nothing to apply."
    return 0
  fi
  log_info "${node_short} is at ${maint_ip} (maintenance mode)."

  # Retried: the Wi-Fi bridge workaround makes the occasional transient
  # handshake failure ("context deadline exceeded") more likely than on
  # wired Ethernet — usually succeeds on the 2nd or 3rd attempt with no
  # other change needed.
  local cfg="${TALOS_OUT_DIR_ABS}/${node_short}.yaml" attempt
  for attempt in 1 2 3; do
    if talosctl apply-config --insecure --nodes "${maint_ip}" --file "${cfg}"; then
      break
    fi
    if [[ "${attempt}" -eq 3 ]]; then
      die "apply-config to ${node_short} failed ${attempt}x in a row — likely not just transient network flakiness, see docu/11-troubleshooting.md."
    fi
    log_warn "apply-config to ${node_short} failed (attempt ${attempt}/3), retrying in 10s..."
    sleep 10
  done
  log_info "Config applied — ${node_short} will install to disk and reboot onto its static IP ${target_ip}."

  wait_for "${node_short} to respond at ${target_ip}" 300 talosctl_ctx -n "${target_ip}" -e "${target_ip}" version --short
  log_info "${node_short} is up at ${target_ip}."
}

# Bootstraps etcd on the FIRST control-plane node only — a one-time,
# cluster-wide action, not something repeated per node (see this script's
# header comment for why). No-op idempotency check so re-running this
# script never tries to re-bootstrap an already-initialized etcd.
bootstrap_etcd_if_first_cp() {
  local i="$1"
  [[ "$(first_controlplane_index)" -eq "${i}" ]] || return 0
  local node_short; node_short="$(node_name "${i}")"
  local ip="${NODE_IPS[$i]}"

  talosctl_ctx config endpoint "${ip}"
  talosctl_ctx config node "${ip}"

  # talosctl_ctx_t, not talosctl_ctx: `etcd status` against a node where
  # etcd was never bootstrapped hangs indefinitely (its gRPC endpoint isn't
  # even listening pre-bootstrap) instead of failing fast — confirmed real,
  # this idempotency check must be bounded or it can hang the whole script.
  if talosctl_ctx_t -n "${ip}" -e "${ip}" etcd status >/dev/null 2>&1; then
    log_info "etcd already bootstrapped on ${node_short}."
    return 0
  fi

  log_step "Bootstrapping etcd on ${node_short} (first control-plane node)"
  talosctl_ctx -n "${ip}" -e "${ip}" bootstrap
  wait_for "etcd to come up on ${node_short}" 300 talosctl_ctx_t -n "${ip}" -e "${ip}" etcd status
  log_info "etcd bootstrapped. ${node_short} is the seed node; cp2/cp3 will join it automatically once configured — no separate bootstrap needed for them."
}

create_and_configure_one_node() {
  local i="$1"
  bring_up_one_node "${i}"
  eject_iso_if_present "${i}"
  bootstrap_etcd_if_first_cp "${i}"
  log_info "Node $(node_name "${i}") done. Moving to the next node."
}

for_each_node create_and_configure_one_node

log_step "All 6 nodes created, started and configured"
log_warn "Nodes will show NotReady in kubectl until Cilium (the CNI) is installed — that's expected, not an error."
log_info "Next: ./scripts/03-bootstrap-cluster.sh (finalizes talosconfig endpoints + fetches kubeconfig)"
