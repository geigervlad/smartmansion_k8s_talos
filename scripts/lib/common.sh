#!/usr/bin/env bash
# Shared helpers sourced by every script in scripts/. Not meant to be run directly.
set -euo pipefail

COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_SH_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/config/cluster.env"

NODE_COUNT=${#NODE_NAMES[@]}
KUBECONFIG_PATH="${REPO_ROOT}/kubeconfig"
TALOSCONFIG_PATH="${REPO_ROOT}/talosconfig"

# VirtualBox's installer doesn't reliably put VBoxManage on Git Bash's PATH
# on Windows (even though it's on the Windows PATH) — this pipeline was
# originally scoped for a dedicated Debian 12 host, but works the same way
# run directly on a Windows machine with VirtualBox installed locally; this
# is a no-op there (loop just finds no match, VBoxManage is already on PATH).
if ! command -v VBoxManage >/dev/null 2>&1; then
  for vbox_dir in \
    "/c/Program Files/Oracle/VirtualBox" \
    "${PROGRAMFILES:-}/Oracle/VirtualBox"; do
    if [[ -x "${vbox_dir}/VBoxManage.exe" ]]; then
      export PATH="${PATH}:${vbox_dir}"
      break
    fi
  done
fi

# ------------------------------------------------------------------ logging --
COLOR_RESET='\033[0m'
COLOR_BLUE='\033[1;34m'
COLOR_GREEN='\033[1;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[1;31m'

# All to stderr, deliberately — several functions (discover_ip_for_mac,
# ensure_talos_schematic_id, etc.) log progress AND return a value via a
# final `echo` for the caller to capture with $(...). If any log function
# wrote to stdout, that capture would silently include the log lines too —
# confirmed in practice: discover_ip_for_mac's "waiting..." message ended up
# inside $maint_ip once the IP wasn't found on the very first attempt,
# breaking the apply-config URL it was used to build.
log_step()  { printf "\n${COLOR_BLUE}==> %s${COLOR_RESET}\n" "$*" >&2; }
log_info()  { printf "${COLOR_GREEN}[info]${COLOR_RESET} %s\n" "$*" >&2; }
log_warn()  { printf "${COLOR_YELLOW}[warn]${COLOR_RESET} %s\n" "$*" >&2; }
log_error() { printf "${COLOR_RED}[error]${COLOR_RESET} %s\n" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

confirm() {
  # confirm "question text" -> 0 (true) on yes, 1 on no. Never exits the script.
  local prompt="${1:-Continue?}" reply
  read -r -p "${prompt} [y/N] " reply || true
  [[ "${reply}" =~ ^[Yy]$ ]]
}

pause_for_manual_step() {
  # Blocks until the user confirms they've completed an out-of-band step
  # (e.g. adding DNS records in the Strato panel) that this script cannot do.
  local prompt="${1:-Press Enter once you have completed the step above.}"
  read -r -p "${prompt} " _ || true
}

require_cmd() {
  local missing=()
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required command(s): ${missing[*]}. See docu/00-overview.md for install links."
  fi
}

# --------------------------------------------------------------- node info --
node_name()      { echo "${NODE_NAMES[$1]}"; }
node_full_name() { echo "${VBOX_VM_PREFIX}-${NODE_NAMES[$1]}"; }
node_ip()        { echo "${NODE_IPS[$1]}"; }
node_role()      { echo "${NODE_ROLES[$1]}"; }
is_controlplane() { [[ "${NODE_ROLES[$1]}" == "controlplane" ]]; }
is_worker()        { [[ "${NODE_ROLES[$1]}" == "worker" ]]; }

first_controlplane_index() {
  local i
  for ((i = 0; i < NODE_COUNT; i++)); do
    if is_controlplane "${i}"; then
      echo "${i}"
      return 0
    fi
  done
  die "No controlplane node defined in config/cluster.env"
}

for_each_node() {
  # for_each_node <function-name> — calls fn(<index>) for every configured node
  local fn="$1" i
  for ((i = 0; i < NODE_COUNT; i++)); do
    "${fn}" "${i}"
  done
}

# ------------------------------------------------------------ idempotency --
vm_exists() {
  VBoxManage list vms 2>/dev/null | grep -qF "\"$(node_full_name "$1")\""
}

vm_running() {
  VBoxManage list runningvms 2>/dev/null | grep -qF "\"$(node_full_name "$1")\""
}

kubectl_ctx() { kubectl --kubeconfig "${KUBECONFIG_PATH}" "$@"; }
talosctl_ctx() { talosctl --talosconfig "${TALOSCONFIG_PATH}" "$@"; }

talosctl_ctx_t() {
  # Same as talosctl_ctx but bounded with a timeout. Confirmed real need:
  # `talosctl ... etcd status` against a node where etcd was never
  # bootstrapped hangs indefinitely instead of failing fast (the etcd gRPC
  # endpoint isn't listening at all pre-bootstrap, so the call just blocks).
  # Use this instead of talosctl_ctx for any check that must fail fast
  # rather than potentially hang forever — e.g. an idempotency check before
  # deciding whether to bootstrap.
  timeout 15 talosctl --talosconfig "${TALOSCONFIG_PATH}" "$@"
}

helm_release_exists() {
  # helm_release_exists <release> <namespace>
  helm status "$1" -n "$2" >/dev/null 2>&1
}

namespace_exists() {
  kubectl_ctx get namespace "$1" >/dev/null 2>&1
}

secret_exists() {
  # secret_exists <name> <namespace>
  kubectl_ctx get secret "$1" -n "$2" >/dev/null 2>&1
}

file_exists_nonempty() {
  [[ -s "$1" ]]
}

wait_for() {
  # wait_for "description" <timeout-seconds> <command...>
  local desc="$1" timeout="$2"; shift 2
  local waited=0
  until "$@" >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      die "Timed out after ${timeout}s waiting for: ${desc}"
    fi
    sleep 5
    waited=$((waited + 5))
    log_info "waiting for ${desc}... (${waited}s/${timeout}s)"
  done
}

random_password() {
  # random_password [length]
  openssl rand -base64 "${1:-24}" | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"
}

# ------------------------------------------------------------- talos factory --
# Deterministic MAC per node (VirtualBox's own vendor prefix 08:00:27), so we
# never have to persist/look up which MAC belongs to which VM — any script can
# recompute it from the node index alone.
node_mac_colon() {
  printf '08:00:27:AA:00:%02X' "$1"
}
node_mac_nocolon() {
  printf '080027AA00%02X' "$1"
}

TALOS_SCHEMATIC_FILE="${REPO_ROOT}/${TALOS_OUT_DIR}/schematic-id.txt"

ensure_talos_schematic_id() {
  # iscsi-tools + util-linux-tools system extensions, baked into the Talos
  # image (both the boot ISO and the installed disk image use the same
  # schematic ID). Historical: added for Longhorn, which this project no
  # longer uses (see docu/02-talos-setup.md) — harmless to leave baked into
  # all 6 already-installed nodes. Cached to disk so we only hit
  # factory.talos.dev once.
  if [[ -s "${TALOS_SCHEMATIC_FILE}" ]]; then
    cat "${TALOS_SCHEMATIC_FILE}"
    return 0
  fi
  mkdir -p "$(dirname "${TALOS_SCHEMATIC_FILE}")"
  local schematic_yaml id
  schematic_yaml=$'customization:\n  systemExtensions:\n    officialExtensions:\n      - siderolabs/iscsi-tools\n      - siderolabs/util-linux-tools\n'
  id="$(curl -fsSL -X POST --data-binary "${schematic_yaml}" https://factory.talos.dev/schematics | jq -r .id)"
  [[ -n "${id}" && "${id}" != "null" ]] || die "Failed to obtain schematic ID from factory.talos.dev (check internet connectivity)"
  echo "${id}" > "${TALOS_SCHEMATIC_FILE}"
  echo "${id}"
}

talos_iso_path() {
  local schematic_id="$1"
  echo "${REPO_ROOT}/${TALOS_OUT_DIR}/talos-${TALOS_VERSION}-${schematic_id}-metal-amd64.iso"
}

talos_install_image() {
  # Reference used in machine config .machine.install.image so the extensions
  # survive `talosctl apply-config` -> install-to-disk, not just the live ISO.
  local schematic_id="$1"
  echo "factory.talos.dev/installer/${schematic_id}:${TALOS_VERSION}"
}

TALOS_OUT_DIR_ABS="${REPO_ROOT}/${TALOS_OUT_DIR}"

ensure_base_talos_config() {
  # Generates the cluster-wide secrets/CA + controlplane.yaml/worker.yaml
  # ONCE (idempotent — skips if already present, since re-running would
  # rotate the cluster CA and break an already-bootstrapped cluster). Pure
  # local file generation, no VM/network dependency — safe to call before
  # any VM exists.
  mkdir -p "${TALOS_OUT_DIR_ABS}"
  if [[ -f "${TALOS_OUT_DIR_ABS}/controlplane.yaml" && -f "${TALOS_OUT_DIR_ABS}/worker.yaml" && -f "${TALOS_OUT_DIR_ABS}/talosconfig" ]]; then
    log_info "Base Talos configs already exist in ${TALOS_OUT_DIR_ABS} — not regenerating."
    return 0
  fi
  ensure_talos_schematic_id >/dev/null   # cached to disk, just make sure it exists
  # --config-patch-worker deliberately omitted: talos/patches/worker.yaml is
  # currently an empty placeholder, and passing an "empty" patch file to
  # `gen config` — no matter how it's spelled (a truly empty file, or an
  # explicit `{}`) — has been unreliable across talosctl versions, both
  # confirmed to fail outright (see docu/11-troubleshooting.md and
  # https://github.com/siderolabs/talos/issues/13029). Simplest robust fix:
  # only pass the flag when there's an actual patch to apply. Add it back
  # (`--config-patch-worker "@${REPO_ROOT}/talos/patches/worker.yaml"`) the
  # day worker.yaml gets real content.
  talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
    --output-dir "${TALOS_OUT_DIR_ABS}" \
    --config-patch "@${REPO_ROOT}/talos/patches/common.yaml" \
    --config-patch-control-plane "@${REPO_ROOT}/talos/patches/controlplane.yaml"
  log_info "Wrote controlplane.yaml, worker.yaml, talosconfig to ${TALOS_OUT_DIR_ABS}"
  cp "${TALOS_OUT_DIR_ABS}/talosconfig" "${TALOSCONFIG_PATH}"
}

render_node_config_file() {
  # render_node_config_file <index> -> writes talos/_out/<name>.yaml, the
  # final per-node machine config (static IP, hostname, install image, VIP,
  # storage volume) ready for `talosctl apply-config`. Requires
  # ensure_base_talos_config to have run first.
  local i="$1"
  local role="${NODE_ROLES[$i]}"
  local name; name="$(node_name "${i}")"
  local base="${TALOS_OUT_DIR_ABS}/controlplane.yaml"
  [[ "${role}" == "worker" ]] && base="${TALOS_OUT_DIR_ABS}/worker.yaml"
  [[ -f "${base}" ]] || die "${base} missing — ensure_base_talos_config must run first."
  local schematic_id install_image
  schematic_id="$(ensure_talos_schematic_id)"
  install_image="$(talos_install_image "${schematic_id}")"
  local patch_file="${TALOS_OUT_DIR_ABS}/${name}.patch.yaml"
  local out_file="${TALOS_OUT_DIR_ABS}/${name}.yaml"

  {
    echo "machine:"
    echo "  network:"
    echo "    interfaces:"
    # Empirically confirmed via `talosctl get link --insecure` against a
    # node still in maintenance mode: VirtualBox's emulated NIC (e1000,
    # "82540EM") comes up as enp0s3 under Talos on every node in this
    # cluster, NOT eth0. Getting this wrong means the static IP/route below
    # silently never applies (the node just keeps whatever DHCP gave it,
    # with no obvious error) — if you ever change the VM's NIC type/count,
    # re-verify with the same command before assuming this still matches.
    echo "      - interface: enp0s3"
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
    echo "    image: ${install_image}"
    echo "    disk: /dev/sda"
    if [[ "${NODE_LONGHORN_DISK_GB[$i]}" -gt 0 ]]; then
      # Second VirtualBox disk (see scripts/01-create-vms.sh), dedicated
      # whole-disk to storage — name/volumeType are TOP-LEVEL fields on this
      # document, NOT nested under metadata:/provisioning:. Mount path is
      # NOT configurable: Talos always uses /var/mnt/<name>. Volume name
      # deliberately still "longhorn" (this project switched to
      # local-path-provisioner, which points its nodePathMap at this same
      # /var/mnt/longhorn path — see
      # gitops/infrastructure/local-path-provisioner/manifests.yaml — rather
      # than rename and force Talos to reprovision the disk on all 6
      # already-running nodes for pure cosmetics, see docu/02-talos-setup.md).
      # Assumes the disk enumerates as /dev/sdb — verify with
      # `talosctl get disks -n <ip>` if this node's layout differs.
      echo "---"
      echo "apiVersion: v1alpha1"
      echo "kind: UserVolumeConfig"
      echo "name: longhorn"
      echo "volumeType: disk"
      echo "provisioning:"
      echo "  diskSelector:"
      echo "    match: disk.dev_path == '/dev/sdb'"
    fi
    # Talos v1.10+ config is multi-document: hostname moved out of the
    # classic machine.network.hostname field into its own HostnameConfig
    # document. Setting both errors with "static hostname is already set".
    echo "---"
    echo "apiVersion: v1alpha1"
    echo "kind: HostnameConfig"
    # Base config defaults to auto: stable — must be explicitly switched to
    # "off" (the only other valid AutoHostnameKind value), Talos rejects
    # 'auto' and 'hostname' both being set otherwise.
    echo "auto: \"off\""
    echo "hostname: ${name}"
  } > "${patch_file}"

  talosctl machineconfig patch "${base}" --patch "@${patch_file}" -o "${out_file}"
  log_info "Rendered ${out_file} (${NODE_IPS[$i]}, role=${role})"
}

eject_iso_if_present() {
  # Talos installs itself to disk and reboots automatically once config is
  # applied — VBoxManage's own boot order (disk before dvd, see
  # scripts/01-create-vms.sh) is what makes that reboot actually land on the
  # installed system rather than the ISO again. This ejects the ISO on top
  # of that as a second safety net, once a node proves it's running from its
  # real install (reachable at its static IP).
  local i="$1"
  local vm_name; vm_name="$(node_full_name "${i}")"
  local current
  current="$(VBoxManage showvminfo "${vm_name}" --machinereadable 2>/dev/null | sed -n 's/^"SATA-1-0"="\(.*\)"$/\1/p')"
  if [[ -n "${current}" && "${current}" != "none" && "${current}" != "emptydrive" ]]; then
    log_info "Ejecting install ISO from ${vm_name} (install completed — this is belt-and-suspenders on top of the disk-first boot order)."
    VBoxManage storageattach "${vm_name}" --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive
  fi
}

# ------------------------------------------------------------- sealed secrets --
PUB_CERT_PATH="${REPO_ROOT}/gitops/infrastructure/sealed-secrets/pub-cert.pem"

seal_secret_literals() {
  # seal_secret_literals <k8s-secret-name> <namespace> <output-file> -- key1=val1 [key2=val2 ...]
  local name="$1" ns="$2" out="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  [[ -s "${PUB_CERT_PATH}" ]] || die "Missing ${PUB_CERT_PATH} — run ./scripts/05-install-sealed-secrets.sh first."
  local literal_args=()
  for kv in "$@"; do
    literal_args+=(--from-literal="${kv}")
  done
  mkdir -p "$(dirname "${out}")"
  kubectl create secret generic "${name}" -n "${ns}" \
    "${literal_args[@]}" \
    --dry-run=client -o yaml \
  | kubeseal --cert "${PUB_CERT_PATH}" --format yaml > "${out}"
}

# ------------------------------------------------------------- IP discovery --
discover_ip_for_mac() {
  # Polls the host ARP table for a given MAC (colon form) until it shows up,
  # used to find a freshly-booted VM's DHCP "maintenance mode" IP before it
  # has any Talos config applied. Requires nmap to actively populate ARP.
  #
  # `ip neigh` (iproute2) is Linux-only — on Windows/Git Bash it doesn't
  # exist, so fall back to the native `arp -a` (present on both, but with a
  # hyphen-separated MAC format there instead of colons).
  local mac="$1" timeout="${2:-300}" waited=0 ip="" mac_lower="${mac,,}"
  while (( waited < timeout )); do
    nmap -sn "${NETWORK_SUBNET_CIDR}" >/dev/null 2>&1 || true
    if command -v ip >/dev/null 2>&1; then
      ip="$(ip neigh show | awk -v m="${mac_lower}" 'tolower($0) ~ m {print $1; exit}')"
    else
      ip="$(arp -a | awk -v m="${mac_lower//:/-}" 'tolower($0) ~ m {print $1; exit}')"
    fi
    if [[ -n "${ip}" ]]; then
      echo "${ip}"
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
    log_info "waiting for VM with MAC ${mac} to appear on the LAN... (${waited}s/${timeout}s)"
  done
  return 1
}
