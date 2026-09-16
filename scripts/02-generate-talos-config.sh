#!/usr/bin/env bash
# OPTIONAL standalone utility — scripts/01-create-vms.sh already does this
# inline for each node as part of its create-VM-then-configure-it loop, so
# you don't need to run this as part of the normal pipeline.
#
# Use this when you want to re-render the per-node Talos configs WITHOUT
# touching any VM — e.g. after editing config/cluster.env (a changed IP,
# a different NTP server) or talos/patches/*.yaml, and you just want to see
# the resulting talos/_out/<node>.yaml before deciding whether to re-apply
# it to an already-running node by hand.
#
# NOTE: talosctl's exact `machineconfig patch` flags have moved around
# between versions — if this errors, check `talosctl machineconfig patch --help`
# (or `talosctl gen config --help`) against your installed version and adjust.
# See docu/02-talos-setup.md.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

log_step "Ensuring base Talos machine config exists (cluster secrets/CA, controlplane.yaml, worker.yaml)"
ensure_base_talos_config

log_step "Rendering per-node machine configs (static IP, hostname, install image, VIP)"
for_each_node render_node_config_file

log_info "Per-node configs written to ${TALOS_OUT_DIR_ABS}/<node>.yaml"
log_info "These are NOT automatically applied to any running node — see this script's header comment."
