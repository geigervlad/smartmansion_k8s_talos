# The Master Script

## Running it

```bash
./MASTER.sh
```

Runs `scripts/00-check-prereqs.sh` through `scripts/10-bootstrap-argocd-apps.sh`
in order. Takes a while (VM boot times, Let's Encrypt account registration,
image pulls) and will pause for interactive input twice:

- `scripts/09-generate-app-secrets.sh` prompts for the deSEC API token and
  Strato DynDNS username/password (can't be generated — see
  [`09-cert-manager-dns.md`](09-cert-manager-dns.md)). Pre-fill
  `secrets-vault/manual-credentials.env` yourself beforehand to skip the prompts.
- `scripts/10-bootstrap-argocd-apps.sh` asks for confirmation before
  committing and before pushing to your GitHub remote.

## Resuming / re-running

Every step checks its own current state first and skips what's already
done — safe to just re-run `./MASTER.sh` after fixing a failure partway
through. To skip straight to a later step:

```bash
./MASTER.sh --from 06      # resume at scripts/06-install-cert-manager.sh
./MASTER.sh --only 09      # run just scripts/09-generate-app-secrets.sh
```

## Before the first run

1. Edit `config/cluster.env` — at minimum check `VBOX_BRIDGE_ADAPTER` matches
   your actual host NIC (`VBoxManage list bridgedifs`) and `GITOPS_REPO_URL`
   points at your real GitHub project.
2. Read [`09-cert-manager-dns.md`](09-cert-manager-dns.md) and create the
   deSEC account / delegated zones *before* running — steps 06-10 will
   complete without it, but no real certificate will issue until it's done.
3. Have your Strato DynDNS username/password ready (Strato control panel →
   domain → DynDNS).

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
kubectl --kubeconfig kubeconfig get sealedsecrets -A              # one per app + infra credential
kubectl --kubeconfig kubeconfig get certificate -A                # Ready once DNS-01 validates
```

See [`11-troubleshooting.md`](11-troubleshooting.md) if any of those don't
look right.
