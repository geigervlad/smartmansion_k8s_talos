# OnlyOffice

Deployed as plain manifests (no official Helm chart exists) — see
[`gitops/apps/onlyoffice/deployment.yaml`](../gitops/apps/onlyoffice/deployment.yaml).
Image `onlyoffice/documentserver:8.2.2`. It's not meant to be used directly;
it's the editing backend Nextcloud's ONLYOFFICE connector app calls into.

## What's configured

- Single `local-path` PVC (20Gi), mounted at three subPaths for the
  Document Server's data/log/lib directories — it bundles its own
  PostgreSQL/RabbitMQ/Redis internally, nothing external needed at this scale.
- `JWT_ENABLED=true` with `JWT_SECRET` from the `onlyoffice-secrets`
  SealedSecret (`jwt-secret` key) — without this, anyone who can reach
  `office.smartmansion.de` could ask it to render arbitrary documents.
- Ingress at `office.smartmansion.de`.

## Connecting it to Nextcloud (one-time manual step)

This is genuinely a manual step, not automated by this repo — cleanly
automating Nextcloud app-store installation + config against a live instance
would need a fragile custom Job (waiting for Nextcloud to be up, exec-ing
`occ` commands, handling re-runs). Documenting it here is more honest than
pretending it's fully declarative.

1. Get the JWT secret both apps need to share:
   ```bash
   grep ONLYOFFICE_JWT_SECRET secrets-vault/app-secrets.env
   ```
2. Install and configure the connector app inside the Nextcloud pod:
   ```bash
   NC_POD=$(kubectl --kubeconfig kubeconfig -n nextcloud get pod -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}')

   kubectl --kubeconfig kubeconfig -n nextcloud exec "$NC_POD" -- php occ app:install onlyoffice
   kubectl --kubeconfig kubeconfig -n nextcloud exec "$NC_POD" -- php occ config:app:set onlyoffice DocumentServerUrl --value="https://office.smartmansion.de/"
   kubectl --kubeconfig kubeconfig -n nextcloud exec "$NC_POD" -- php occ config:app:set onlyoffice jwt_secret --value="<value from step 1>"
   ```
3. Optional but recommended: point the internal request path at the
   in-cluster Service instead of round-tripping through the public Ingress
   (faster, one less hop through cert-manager's TLS):
   ```bash
   kubectl --kubeconfig kubeconfig -n nextcloud exec "$NC_POD" -- php occ config:app:set onlyoffice DocumentServerInternalUrl --value="http://onlyoffice-documentserver.onlyoffice.svc.cluster.local/"
   kubectl --kubeconfig kubeconfig -n nextcloud exec "$NC_POD" -- php occ config:app:set onlyoffice StorageUrl --value="https://smartmansion.de/"
   ```
4. In Nextcloud → Settings → ONLYOFFICE, confirm it shows a green
   "connection established" status.

## NetworkPolicy

See [`03-cilium-networkpolicies.md`](03-cilium-networkpolicies.md) — only
traffic via the Ingress and the `nextcloud` namespace is allowed in.

## Common issues

- **"Document Server unreachable"** in Nextcloud settings: check
  `DocumentServerInternalUrl` resolves from inside the cluster and the
  `onlyoffice` namespace's NetworkPolicy allows the `nextcloud` namespace
  (it does, by default — check nothing was edited).
- **JWT/token errors when opening a document**: the `jwt_secret` occ config
  value and the Document Server's `JWT_SECRET` env var (from
  `onlyoffice-secrets`) have drifted — re-run step 2 above with the current
  value from `secrets-vault/app-secrets.env`.
