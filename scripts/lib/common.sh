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

# ------------------------------------------------------------------ logging --
COLOR_RESET='\033[0m'
COLOR_BLUE='\033[1;34m'
COLOR_GREEN='\033[1;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[1;31m'

log_step()  { printf "\n${COLOR_BLUE}==> %s${COLOR_RESET}\n" "$*"; }
log_info()  { printf "${COLOR_GREEN}[info]${COLOR_RESET} %s\n" "$*"; }
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
  # Longhorn needs the iscsi-tools + util-linux-tools system extensions baked
  # into the Talos image (both the boot ISO and the installed disk image use
  # the same schematic ID). Cached to disk so we only hit factory.talos.dev once.
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

# ------------------------------------------------------------- IP discovery --
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

discover_ip_for_mac() {
  # Polls the host ARP table for a given MAC (colon form) until it shows up,
  # used to find a freshly-booted VM's DHCP "maintenance mode" IP before it
  # has any Talos config applied. Requires nmap to actively populate ARP.
  local mac="$1" timeout="${2:-300}" waited=0 ip=""
  while (( waited < timeout )); do
    nmap -sn "${NETWORK_SUBNET_CIDR}" >/dev/null 2>&1 || true
    ip="$(ip neigh show | awk -v m="${mac,,}" 'tolower($0) ~ m {print $1; exit}')"
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
