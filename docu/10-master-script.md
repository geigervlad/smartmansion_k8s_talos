# The Master Script

## Running it

```bash
./MASTER.sh
```

Runs `scripts/00-check-prereqs.sh` through `scripts/11-configure-hosts.sh`
in order. Takes a while (VM boot times, image pulls) and will pause for
interactive input once:

- `scripts/10-bootstrap-argocd-apps.sh` asks for confirmation before
  committing and before pushing to your GitHub remote.

`scripts/11-configure-hosts.sh` (the last step) needs an Administrator
shell — see [`09-cert-manager-dns.md`](09-cert-manager-dns.md). If you ran
`MASTER.sh` from a normal shell, that one step will fail with a clear
message; re-run just it from an elevated shell:
`./MASTER.sh --only 11`.

## Resuming / re-running

Every step checks its own current state first and skips what's already
done — safe to just re-run `./MASTER.sh` after fixing a failure partway
through. To skip straight to a later step:

```bash
./MASTER.sh --from 06      # resume at scripts/06-install-cert-manager.sh
./MASTER.sh --only 09      # run just scripts/09-generate-app-secrets.sh
```

## Before the first run

Edit `config/cluster.env` — at minimum check `VBOX_BRIDGE_ADAPTER` matches
your actual host NIC (`VBoxManage list bridgedifs`), `GITOPS_REPO_URL`
points at your real GitHub project, and `INGRESS_VIP` is a genuinely free
LAN IP (outside your router's DHCP range). No accounts to create, no DNS
zones to delegate — see [`09-cert-manager-dns.md`](09-cert-manager-dns.md).

## What each step assumes about the one before it

Each `scripts/0N-*.sh` documents its own assumptions in its header comment —
worth reading if you're running them individually rather than via
`MASTER.sh`. The short version: they're strictly ordered (CNI before
anything schedules, SealedSecrets before any secret can be sealed,
cert-manager's CRDs before its ClusterIssuers, etc.) — `MASTER.sh`'s default
order is the only supported order.

## Verifying success

```bash
kubectl --kubeconfig kubeconfig get nodes                       # 6 Ready
kubectl --kubeconfig kubeconfig -n argocd get applications       # all Synced/Healthy
kubectl --kubeconfig kubeconfig get sealedsecrets -A              # one per app secret
kubectl --kubeconfig kubeconfig get certificate -A                # Ready almost immediately — internal CA, no external validation
kubectl --kubeconfig kubeconfig -n kube-system get svc cilium-ingress   # EXTERNAL-IP == INGRESS_VIP
```

See [`11-troubleshooting.md`](11-troubleshooting.md) if any of those don't
look right.
