# SmartMansion

A GitOps-managed Kubernetes homelab: 6 Talos Linux VMs (3 control-plane + 3
worker) on a single VirtualBox host, deployed and managed entirely through
this repository via ArgoCD. Runs Nextcloud, OnlyOffice and Home Assistant,
with Cilium NetworkPolicies, SealedSecrets, and cert-manager backed by a
self-signed internal CA — LAN-only access via `*.lan` domains, no
public DNS or Let's Encrypt involved at all.

**Start here: [`docu/00-overview.md`](docu/00-overview.md).**

```bash
./MASTER.sh
```

See [`docu/10-master-script.md`](docu/10-master-script.md) before running it
for the first time — a couple of things (`config/cluster.env`, the GitHub
remote) need to be in place first.
