# ArgoCD & GitOps

## The app-of-apps pattern used here

There is exactly one Application ever applied by hand:
[`gitops/bootstrap/root-app.yaml`](../gitops/bootstrap/root-app.yaml), by
`scripts/10-bootstrap-argocd-apps.sh`. It watches the whole `gitops/`
directory recursively but only picks up files matching `**/application*.yaml`
(`directory.include`) — i.e. exactly the `application.yaml` /
`application-config.yaml` files colocated with each component, never the
`values.yaml` / `namespace.yaml` / `sealed-secret.yaml` / raw manifests
sitting next to them. Those get synced by the *child* Applications that
root-app creates, into their own destinations — root-app itself only ever
creates more `Application` resources in the `argocd` namespace.

```
root-app.yaml
  ├─ gitops/infrastructure/cilium/application.yaml              (wave -10)
  ├─ gitops/infrastructure/cilium/application-config.yaml       (wave -9, LB-IPAM pool + L2 policy, needs Cilium CRDs)
  ├─ gitops/infrastructure/sealed-secrets/application.yaml      (wave -5)
  ├─ gitops/infrastructure/cert-manager/application.yaml        (wave -5)
  ├─ gitops/infrastructure/local-path-provisioner/application.yaml (wave -5)
  ├─ gitops/sealed-secrets/application.yaml                     (wave -4, every generated SealedSecret — see docu/05)
  ├─ gitops/infrastructure/cert-manager/application-config.yaml (wave -3, needs cert-manager's own CRDs)
  ├─ gitops/apps/nextcloud/application.yaml                     (wave 0, default)
  ├─ gitops/apps/onlyoffice/application.yaml                    (wave 0, default)
  └─ gitops/apps/homeassistant/application.yaml                 (wave 0, default)
```

Sync waves (`argocd.argoproj.io/sync-wave` annotation) enforce ordering:
negative waves reconcile before less-negative/zero ones. Cilium must be first
(nothing schedules without a CNI); everything infrastructure-ish comes before
the 3 apps.

## Why ArgoCD itself is not self-managed

Every other infrastructure component follows "installed once by a
`scripts/0N-*.sh`, then adopted into ArgoCD via an `application.yaml`
pointed at the exact same config" — intentional, so there's a single source
of truth and no drift between the bootstrap install and the ongoing
GitOps-managed one. For the Helm-based ones (Cilium, SealedSecrets,
cert-manager) that's a shared `values.yaml`; for the one with no Helm chart
(local-path-provisioner) it's the same vendored raw manifest file both the
script and ArgoCD apply.

ArgoCD is the one exception (see
[`gitops/infrastructure/argocd/values.yaml`](../gitops/infrastructure/argocd/values.yaml)):
`scripts/08-install-argocd.sh` installs it and nothing ever re-adopts it into
itself. Self-managing ArgoCD is a well-known footgun — a bad sync can take
down the only tool you'd use to fix it. Changing ArgoCD's own config means
editing `gitops/infrastructure/argocd/values.yaml` and re-running
`scripts/08-install-argocd.sh` (`helm upgrade`) by hand.

## The "adopting a script-installed Helm release into ArgoCD" caveat

The first time ArgoCD reconciles `cilium`/`cert-manager`/`longhorn`/
`sealed-secrets`, it may show `OutOfSync` briefly even though nothing is
actually different — this is normal: ArgoCD renders the chart via `helm
template` and diffs/applies via `kubectl`, which doesn't share Helm CLI's own
release-tracking metadata. It self-heals on the next sync. If a diff persists
and looks wrong, compare against the exact `values.yaml` the bootstrap script
used — they're meant to be identical (same file).

## Making changes going forward

1. Edit something under `gitops/`.
2. `git commit && git push`.
3. ArgoCD picks it up automatically (`syncPolicy.automated.selfHeal: true`
   everywhere) — or trigger immediately: `argocd app sync <name>`.

## Multi-source Applications (why some `application.yaml` files look unusual)

Charts hosted in an external Helm repo (Cilium, cert-manager, sealed-secrets,
Nextcloud, Home Assistant) can't read a `values.yaml` living in *this* git
repo directly — ArgoCD's multi-source `sources:` + `$values` reference
pattern is used to combine "chart from Helm repo X" with "values file from
git repo Y" (and, for Nextcloud/Home Assistant, a third source directory-
syncing their own `namespace.yaml`/`network-policy.yaml`/raw manifests) in
one Application. Where there's no Helm chart at all (OnlyOffice,
local-path-provisioner, `gitops/sealed-secrets/`, and the
cilium/cert-manager raw-manifest config directories), a plain
single-`source` directory sync is used instead, with
`directory.include`/`directory.exclude` skipping the Application's own
`application.yaml` (already applied by root-app, at a different
destination).

## Access

```bash
kubectl --kubeconfig kubeconfig -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080, admin / $(cat secrets-vault/argocd-admin-password.txt)
```
(that `localhost` is the port-forward's own loopback address, unrelated to
this project's `*.lan` domains) or `https://argocd.lan` once
`scripts/11-configure-hosts.sh` has run — see
[`09-cert-manager-dns.md`](09-cert-manager-dns.md).
