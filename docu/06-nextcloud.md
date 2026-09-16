# Nextcloud

Deployed via the official `nextcloud/nextcloud` Helm chart
(https://nextcloud.github.io/helm/, pinned to `9.2.6`, appVersion `34.0.3`
— see `gitops/apps/nextcloud/application.yaml`) — see
[`gitops/apps/nextcloud/values.yaml`](../gitops/apps/nextcloud/values.yaml)
and [`gitops/apps/nextcloud/application.yaml`](../gitops/apps/nextcloud/application.yaml).

## Database & cache: plain manifests, not the chart's bundled subcharts

The chart's own bundled `postgresql`/`mariadb`/`redis` subcharts are all
Bitnami-sourced — and Bitnami's free images/charts were effectively
discontinued through 2025/2026 (see
[`11-troubleshooting.md`](11-troubleshooting.md)). Rather than keep fighting
that, both run as **plain manifests** in this same directory, with the chart
pointed at them via `externalDatabase`/`externalRedis`:

- [`gitops/apps/nextcloud/postgresql.yaml`](../gitops/apps/nextcloud/postgresql.yaml)
  — the official `docker.io/library/postgres:18` image directly, one
  StatefulSet, one PVC. No operator (CloudNativePG was considered and
  deliberately skipped — this is a single homelab instance, not something
  that needs automatic failover/HA).
- [`gitops/apps/nextcloud/redis.yaml`](../gitops/apps/nextcloud/redis.yaml)
  — [Valkey](https://valkey.io) (the open-source, Linux-Foundation-governed
  fork of Redis, fully protocol-compatible — Redis itself moved to a more
  restrictive license, Valkey is the community continuation), one
  Deployment, one PVC. Wired in automatically by the `nextcloud/docker`
  image's own `redis.config.php` default config once `externalRedis.enabled`
  is true — nothing else to configure.

## What's configured

- **Storage**: 100Gi `local-path` PVC for Nextcloud's data directory, 20Gi
  for PostgreSQL, 4Gi for Valkey. local-path-provisioner pins each PVC's
  data to whichever node it was first created on — see
  [`01-architecture.md`](01-architecture.md) for why that trade-off was
  chosen over Longhorn.
- **TLS termination happens at the Ingress**, not in the Nextcloud pod —
  `phpClientHttpsFix.enabled: true` tells Nextcloud to trust that and
  generate `https://` links/redirects instead of `http://`. Without this,
  login redirects and most links come out broken.
- **Ingress**: `smartmansion.de`, via Cilium's Ingress Controller,
  `cert-manager.io/cluster-issuer: letsencrypt-staging` by default — switch
  to `letsencrypt-prod` once you've confirmed staging issues cleanly (see
  [`09-cert-manager-dns.md`](09-cert-manager-dns.md)).
- **Credentials**: `nextcloud-secrets` (in
  [`gitops/sealed-secrets/`](../gitops/sealed-secrets/), sealed by
  `scripts/09-generate-app-secrets.sh` — see
  [`05-sealed-secrets.md`](05-sealed-secrets.md) for why generated secrets
  live in that one folder instead of next to Nextcloud itself) supplies the
  Nextcloud admin account (`nextcloud-username`/`nextcloud-password` — the
  chart's own `existingSecret` mechanism), the Postgres user's password
  (`db-username`/`db-password` — read by *both* the Nextcloud pod, via
  `externalDatabase.existingSecret`, and the `postgresql.yaml` StatefulSet
  itself, so they can never drift apart), and the Valkey password
  (`redis-password`, same pattern via `redis.yaml`).

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
PostgreSQL/Valkey), and the `onlyoffice` namespace is allowed in.

## Common issues

- **"Access through untrusted domain"**: check `nextcloud.trustedDomains` in
  `values.yaml` includes exactly the hostname you're browsing to.
- **Redirect loops / mixed content**: almost always `phpClientHttpsFix` not
  applied, or the Ingress TLS secret not yet issued — check
  `kubectl -n nextcloud get certificate`.
- **PostgreSQL/Valkey pod CrashLoopBackOff on first install**: usually a PVC
  not yet bound — check `kubectl -n nextcloud get pvc` and
  `kubectl -n local-path-storage get pods` (the provisioner itself).
- **Nextcloud pod can't reach the database**: `postgresql.yaml` is a
  headless Service (`clusterIP: None`, required for a StatefulSet) — confirm
  `nextcloud-postgresql` resolves from inside the `nextcloud` namespace
  (`kubectl -n nextcloud run -it --rm dnstest --image=busybox --restart=Never
  -- nslookup nextcloud-postgresql`).
