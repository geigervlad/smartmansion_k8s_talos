# SealedSecrets

## Why

This repo is pushed to a **public** GitHub project (per the original
requirements). Nothing that touches `gitops/` can ever contain a plaintext
credential. `SealedSecret` resources are ciphertext, safe to commit — only
the SealedSecrets controller running in *this specific cluster* (holding the
matching private key) can decrypt them back into a real `Secret`.

## The private key — read this before you need it

`scripts/05-install-sealed-secrets.sh` installs the controller, which
auto-generates its encryption keypair on first start, then **immediately
backs it up** to `secrets-vault/sealed-secrets-key-backup.yaml` (gitignored).

**If this key is lost, every SealedSecret ever created — including all the
ones `scripts/09-generate-app-secrets.sh` writes — becomes permanently
undecryptable.** There is no recovery. Copy
`secrets-vault/sealed-secrets-key-backup.yaml` somewhere outside this
machine (USB stick, password manager vault, offline backup) right after the
first successful run. This is the single most important file this pipeline
produces.

The public half is also exported, to
[`gitops/infrastructure/sealed-secrets/pub-cert.pem`](../gitops/infrastructure/sealed-secrets/pub-cert.pem)
— safe to commit (it's a public key), and lets you seal new secrets offline
without needing a live connection to the cluster (`kubeseal --cert
gitops/infrastructure/sealed-secrets/pub-cert.pem`).

## How sealing works in this repo

`seal_secret_literals()` in `scripts/lib/common.sh` is the one helper every
script uses:

```bash
seal_secret_literals <k8s-secret-name> <namespace> <output-file> -- key1=val1 [key2=val2 ...]
```

It builds a plain `Secret` manifest with `kubectl create secret generic
--dry-run=client` (no cluster call needed) and pipes it through `kubeseal
--cert gitops/infrastructure/sealed-secrets/pub-cert.pem` to produce the
`SealedSecret` YAML that actually gets committed.

`scripts/09-generate-app-secrets.sh` is the one place this happens for every
secret in the repo — see that script and
[`10-master-script.md`](10-master-script.md) for what it generates vs. what
it asks you for.

## Rotating a secret

1. Delete the relevant `*-sealed-secret.yaml` / `sealed-secret.yaml` file.
2. Delete the corresponding line from `secrets-vault/app-secrets.env` or
   `secrets-vault/manual-credentials.env` (whichever cached the old value).
3. Re-run `scripts/09-generate-app-secrets.sh` — it generates/prompts for a
   fresh value and re-seals.
4. Commit, push, let ArgoCD sync. Restart the affected pod if it doesn't
   pick up the new env var automatically.

## Restoring the controller on a rebuilt cluster

If you ever rebuild the cluster from scratch but want existing SealedSecrets
in git to keep working, restore the key **before** `scripts/09-*` runs again:

```bash
kubectl --kubeconfig kubeconfig apply -f secrets-vault/sealed-secrets-key-backup.yaml
kubectl --kubeconfig kubeconfig -n sealed-secrets rollout restart deployment/sealed-secrets
```
