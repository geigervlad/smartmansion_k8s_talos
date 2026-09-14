# SmartMansion

A GitOps-managed Kubernetes homelab: 6 Talos Linux VMs (3 control-plane + 3
worker) on a single VirtualBox host, deployed and managed entirely through
this repository via ArgoCD. Runs Nextcloud, OnlyOffice and Home Assistant,
with Cilium NetworkPolicies, SealedSecrets, cert-manager/Let's Encrypt and a
DynDNS updater for a residential internet connection with no static IP.

**Start here: [`docu/00-overview.md`](docu/00-overview.md).**

```bash
./MASTER.sh
```

See [`docu/10-master-script.md`](docu/10-master-script.md) before running it
for the first time — a few things (DNS provider setup, GitHub remote) need
to be in place first.
