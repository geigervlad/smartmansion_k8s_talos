#!/usr/bin/env bash
# The single entry point: runs every step in scripts/ in order, end to end —
# creates the 6 VirtualBox VMs, bootstraps Talos + Kubernetes, installs
# Cilium/SealedSecrets/cert-manager/Longhorn/ArgoCD, generates and seals all
# secrets, and pushes this repo so ArgoCD can take over via GitOps.
#
# Safe to re-run: every scripts/NN-*.sh is written to check current state
# first and skip what's already done (see scripts/lib/common.sh). If a step
# fails, fix the underlying issue and just run MASTER.sh again — or resume
# from a specific step with --from.
#
# Usage:
#   ./MASTER.sh              # run everything, 00 through 10
#   ./MASTER.sh --from 06    # resume starting at scripts/06-install-cert-manager.sh
#   ./MASTER.sh --only 09    # run just scripts/09-generate-app-secrets.sh
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STEPS=(
  00-check-prereqs
  01-create-vms
  02-generate-talos-config
  03-bootstrap-cluster
  04-install-cilium
  05-install-sealed-secrets
  06-install-cert-manager
  07-install-longhorn
  08-install-argocd
  09-generate-app-secrets
  10-bootstrap-argocd-apps
)

from="00"
only=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) from="$2"; shift 2 ;;
    --only) only="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

for step in "${STEPS[@]}"; do
  step_num="${step%%-*}"
  if [[ -n "${only}" ]]; then
    [[ "${step_num}" != "${only}" ]] && continue
  else
    [[ "${step_num}" < "${from}" ]] && continue
  fi

  script="scripts/${step}.sh"
  printf '\n\033[1;35m############################################################\033[0m\n'
  printf '\033[1;35m# %s\033[0m\n' "${script}"
  printf '\033[1;35m############################################################\033[0m\n'
  bash "${script}"
done

echo
echo "MASTER.sh complete."
