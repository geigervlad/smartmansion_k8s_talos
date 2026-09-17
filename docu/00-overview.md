# SmartMansion — Overview

A GitOps-managed Kubernetes homelab: one Debian 12 host runs 6 Talos Linux
VMs (3 control-plane + 3 worker) under VirtualBox, managed entirely through
this git repository via ArgoCD. Deploys Nextcloud, OnlyOffice and Home
Assistant. LAN-only access via `*.localhost` domains and a self-signed
internal CA — no public DNS, no Let's Encrypt (see
[`09-cert-manager-dns.md`](09-cert-manager-dns.md)).

## Read this first

- [`01-architecture.md`](01-architecture.md) — the big picture: nodes,
  networking, how the pieces fit together.
- [`10-master-script.md`](10-master-script.md) — how to actually run this
  end to end.
- [`09-cert-manager-dns.md`](09-cert-manager-dns.md) — the internal CA +
  `.localhost` setup, and the one caveat worth knowing about it before you
  rely on it.

## Prerequisites (on the Debian 12 host)

| Tool | Used for | Install |
|---|---|---|
| VirtualBox (`VBoxManage`) | The 6 VMs | `apt install virtualbox` |
| `talosctl` | Talos config/bootstrap | https://www.talos.dev/latest/introduction/getting-started/ |
| `kubectl` | Cluster access | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | Installing infra charts | https://helm.sh/docs/intro/install/ |
| `kubeseal` | Sealing secrets | https://github.com/bitnami-labs/sealed-secrets/releases |
| `argocd` (CLI) | Optional, for `argocd app` commands | https://argo-cd.readthedocs.io/en/stable/cli_installation/ |
| `git`, `openssl`, `jq`, `curl`, `nmap` | Scripting glue | `apt install git openssl jq curl nmap` |

`scripts/00-check-prereqs.sh` verifies all of these before anything else runs.

## What the pipeline actually does

```
scripts/00-check-prereqs.sh        sanity-check tools + config/cluster.env
scripts/01-create-vms.sh           per node: create VM, start it, apply Talos config, verify — one at a time (bootstraps etcd right after node 1)
scripts/02-generate-talos-config.sh optional: re-render per-node configs without touching any VM
scripts/03-bootstrap-cluster.sh    once all 6 nodes are up: finalize talosconfig endpoints, fetch kubeconfig
scripts/04-install-cilium.sh       CNI (kube-proxy replacement + ingress controller)
scripts/05-install-sealed-secrets.sh  controller + back up its private key
scripts/06-install-cert-manager.sh cert-manager + the internal CA ClusterIssuer
scripts/07-install-storage.sh      local-path-provisioner (local storage)
scripts/08-install-argocd.sh       ArgoCD itself (not GitOps-managed, see docu/04)
scripts/09-generate-app-secrets.sh generate + seal every app secret
scripts/10-bootstrap-argocd-apps.sh push this repo, apply the app-of-apps
scripts/11-configure-hosts.sh      point every *.localhost domain at the cluster in your Windows hosts file
```

Run them all via `./MASTER.sh`, or one at a time while debugging — see
[`10-master-script.md`](10-master-script.md).

## Repo layout

```
config/cluster.env       single source of truth: node IPs, domains, disk sizes, ...
scripts/                 the numbered pipeline above, plus scripts/lib/common.sh
talos/patches/           Talos machine config patches (checked in, no secrets)
talos/_out/               generated per-node configs + cluster secrets (gitignored)
gitops/bootstrap/         root-app.yaml — the one Application applied by hand
gitops/infrastructure/    cilium, cert-manager, local-path-provisioner, sealed-secrets (controller)
gitops/sealed-secrets/    every generated SealedSecret, one folder for all of them — see docu/05
gitops/apps/              nextcloud, onlyoffice, homeassistant
docu/                     you are here
secrets-vault/            gitignored: raw secrets, key backups — never committed
```

## After the first successful run

- ArgoCD UI: `https://argocd.localhost` (or port-forward — see
  `scripts/08-install-argocd.sh` output).
- Nextcloud: `https://nextcloud.localhost`
- Home Assistant: `https://homeassistant.localhost`
- OnlyOffice: `https://onlyoffice.localhost` (not meant to be used directly
  by you — it's the editing backend Nextcloud calls into, see
  [`08-onlyoffice.md`](08-onlyoffice.md))

Every one of these needs `scripts/11-configure-hosts.sh` to have run first
(the domain doesn't resolve otherwise) and will show a certificate warning
until you import `secrets-vault/smartmansion-ca.crt` — see
[`09-cert-manager-dns.md`](09-cert-manager-dns.md).

From here on, changes are made by editing files under `gitops/` and pushing —
ArgoCD picks them up automatically (`syncPolicy.automated.selfHeal: true`
everywhere).
