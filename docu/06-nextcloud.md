# Nextcloud

Deployed via the official `nextcloud/nextcloud` Helm chart
(https://nextcloud.github.io/helm/) — see
[`gitops/apps/nextcloud/values.yaml`](../gitops/apps/nextcloud/values.yaml)
and [`gitops/apps/nextcloud/application.yaml`](../gitops/apps/nextcloud/application.yaml).

## What's configured

- **Storage**: 100Gi Longhorn PVC for Nextcloud's data directory, 20Gi for
  the bundled MariaDB (`mariadb.enabled: true` — the chart's own subchart,
  not a separately managed database).
- **TLS termination happens at the Ingress**, not in the Nextcloud pod —
  `phpClientHttpsFix.enabled: true` tells Nextcloud to trust that and
  generate `https://` links/redirects instead of `http://`. Without this,
  login redirects and most links come out broken.
- **Ingress**: `smartmansion.de`, via Cilium's Ingress Controller,
  `cert-manager.io/cluster-issuer: letsencrypt-staging` by default — switch
  to `letsencrypt-prod` once you've confirmed staging issues cleanly (see
  [`09-cert-manager-dns.md`](09-cert-manager-dns.md)).
- **Credentials**: `nextcloud-secrets` (sealed by
  `scripts/09-generate-app-secrets.sh`) supplies both the Nextcloud admin
  account (`nextcloud-username`/`nextcloud-password` keys — the chart's own
  `existingSecret` mechanism) and the MariaDB root/user passwords
  (`mariadb-root-password`/`mariadb-password` — the bundled mariadb
  subchart's own `existingSecret` mechanism). One secret, two consumers.

## First login

```bash
cat secrets-vault/app-secrets.env | grep NEXTCLOUD_ADMIN_PASSWORD
```

Username is `admin`. Log in at `https://smartmansion.de`.

## Connecting OnlyOffice

Not automated — see [`08-onlyoffice.md`](08-onlyoffice.md) for the one-time
manual step (installing and configuring the ONLYOFFICE Nextcloud app via
`occ`).

## NetworkPolicy

See [`03-cilium-networkpolicies.md`](03-cilium-networkpolicies.md) — the
short version: only traffic via the Ingress, same-namespace (its own
MariaDB), and the `onlyoffice` namespace is allowed in.

## Common issues

- **"Access through untrusted domain"**: check `nextcloud.trustedDomains` in
  `values.yaml` includes exactly the hostname you're browsing to.
- **Redirect loops / mixed content**: almost always `phpClientHttpsFix` not
  applied, or the Ingress TLS secret not yet issued — check
  `kubectl -n nextcloud get certificate`.
- **MariaDB pod CrashLoopBackOff on first install**: usually a PVC not yet
  bound — check `kubectl -n nextcloud get pvc` and Longhorn's own node/disk
  health (`kubectl -n longhorn-system get nodes.longhorn.io`).
