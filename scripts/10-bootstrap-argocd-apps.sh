#!/usr/bin/env bash
# Final step: bakes the real GitHub URL into every Application manifest,
# commits + pushes this repo, then applies the one Application that has to
# be created by hand — gitops/bootstrap/root-app.yaml (the app-of-apps).
# Everything after this point is pure GitOps: ArgoCD reads from the pushed
# remote, not from this local checkout.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if [[ "${GITOPS_REPO_URL}" == *"REPLACE_ME"* ]]; then
  die "GITOPS_REPO_URL in config/cluster.env is still a placeholder — set it to your real (public) GitHub project URL and re-run."
fi

log_step "Templating __GITOPS_REPO_URL__ -> ${GITOPS_REPO_URL}"
while IFS= read -r -d '' f; do
  sed -i "s#__GITOPS_REPO_URL__#${GITOPS_REPO_URL}#g" "${f}"
  log_info "patched ${f#"${REPO_ROOT}"/}"
done < <(grep -rlZ '__GITOPS_REPO_URL__' "${REPO_ROOT}/gitops" 2>/dev/null || true)

cd "${REPO_ROOT}"

log_step "Staging changes"
git add -A -- . ':!secrets-vault' ':!kubeconfig' ':!talosconfig' ':!talos/_out'
git status --short

if git diff --cached --quiet; then
  log_info "Nothing new to commit."
else
  if confirm "Commit the above changes?"; then
    git commit -m "Configure SmartMansion GitOps stack"
  else
    die "Aborted — nothing committed, nothing pushed."
  fi
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "${GITOPS_REPO_URL}"
  log_info "Added git remote origin -> ${GITOPS_REPO_URL}"
else
  current_origin="$(git remote get-url origin)"
  if [[ "${current_origin}" != "${GITOPS_REPO_URL}" ]]; then
    log_warn "git remote 'origin' is currently ${current_origin}, config/cluster.env says ${GITOPS_REPO_URL}."
    if confirm "Update origin to ${GITOPS_REPO_URL}?"; then
      git remote set-url origin "${GITOPS_REPO_URL}"
    fi
  fi
fi

log_warn "About to push branch '${GITOPS_REPO_BRANCH}' to $(git remote get-url origin)."
if ! confirm "Push now?"; then
  log_warn "Skipped push. Nothing further will happen until you push manually — ArgoCD reads from the remote, not this checkout."
  exit 0
fi
git push -u origin "HEAD:${GITOPS_REPO_BRANCH}"

log_step "Applying the ArgoCD root app-of-apps"
kubectl_ctx apply -f "${REPO_ROOT}/gitops/bootstrap/root-app.yaml"

log_info "Root app applied. Watch everything sync with:"
log_info "  kubectl --kubeconfig kubeconfig -n argocd get applications -w"
log_info ""
log_info "Once synced: https://${DOMAIN_NEXTCLOUD}  https://${DOMAIN_HOMEASSISTANT}  https://${DOMAIN_ONLYOFFICE}  https://${DOMAIN_ARGOCD}"
log_info "(only reachable once DNS/cert-manager are fully set up — see docu/09-cert-manager-dns.md)"
log_info ""
log_info "All done. See docu/00-overview.md for the full walkthrough and docu/11-troubleshooting.md if anything's stuck."
