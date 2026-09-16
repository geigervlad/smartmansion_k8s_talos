# cert-manager, DNS-01 and Strato

Strato.de (the DNS provider for `smartmansion.de`) has no ACME-compatible DNS
management API. That's the whole problem this document works around. It
covers two *separate* things that both touch Strato's DNS panel:

1. **DNS-01 challenges** for issuing Let's Encrypt certificates (TXT records).
2. **DynDNS** for keeping the A records pointed at your changing public IP
   (see [`gitops/infrastructure/dyndns-updater`](../gitops/infrastructure/dyndns-updater/)).

These are independent — you need both, but they don't depend on each other.

## Why DNS-01 at all?

No port 80/443 is exposed to the internet (VPN-only access, per the original
design discussion), so HTTP-01 challenges are out — Let's Encrypt can't reach
a webserver on your LAN to validate ownership. DNS-01 only requires that a
TXT record be publicly *resolvable*, which doesn't require any inbound port
on your network at all.

## Options that were considered

| Option | Verdict |
|---|---|
| Plain cert-manager DNS-01 for Strato | **Not possible** — Strato has no supported API. |
| Official cert-manager RFC2136 / built-in providers | Strato isn't one of them. |
| Self-hosted **acme-dns** (cert-manager's official answer to "my provider has no API") | Works, but means running your own public authoritative DNS server (port 53 TCP+UDP reachable from the internet) plus a one-time NS delegation. Real operational weight for a homelab. |
| **Community `cert-manager-webhook-desec`** ← chosen | Delegate just `_acme-challenge.<domain>` to deSEC.io (free, no port exposure needed) and let a small in-cluster webhook talk to deSEC's API on cert-manager's behalf. |
| Self-signed / internal CA | Zero external dependencies, but every device needs the CA imported once to avoid browser warnings. Kept as `smartmansion-internal` ClusterIssuer fallback either way. |

**Important honesty note about the chosen option:** `cert-manager-webhook-desec`
(https://github.com/kmorning/cert-manager-webhook-desec) is a single-maintainer
community project. There's no published Helm chart (installation is raw
manifests, vendored into
[`gitops/infrastructure/cert-manager/manifests/desec-webhook.yaml`](../gitops/infrastructure/cert-manager/manifests/desec-webhook.yaml))
and no pinned container image tag — it ships as `:latest`. This was a deliberate
choice made after weighing it against acme-dns and self-signed; if it ever
breaks (image disappears, upstream changes), the `smartmansion-internal`
ClusterIssuer is the documented fallback (see below) and doesn't require
touching anything at Strato.

## One-time setup (do this before real certificates will issue)

### 1. Create a deSEC.io account and delegate zones

1. Sign up for a free account at https://desec.io.
2. Under "Domains", add these three as separate domains in your deSEC account
   (deSEC treats each delegated zone as its own "domain" object, even though
   they're subdomains of `smartmansion.de`):
   - `_acme-challenge.smartmansion.de`
   - `_acme-challenge.home.smartmansion.de`
   - `_acme-challenge.office.smartmansion.de`
3. deSEC will show you its nameservers for each (normally `ns1.desec.io` and
   `ns2.desec.io` — double-check in your deSEC dashboard, this has changed
   historically).
4. Generate an API **token** under "Tokens" in the deSEC dashboard (account-wide
   — the same token works for all three delegated zones, so you only need one).

### 2. Delegate the zones at Strato

In the Strato DNS panel for `smartmansion.de`, add **NS records** (not TXT,
not A):

```
_acme-challenge.smartmansion.de.        NS   ns1.desec.io.
_acme-challenge.smartmansion.de.        NS   ns2.desec.io.
_acme-challenge.home.smartmansion.de.   NS   ns1.desec.io.
_acme-challenge.home.smartmansion.de.   NS   ns2.desec.io.
_acme-challenge.office.smartmansion.de. NS   ns1.desec.io.
_acme-challenge.office.smartmansion.de. NS   ns2.desec.io.
```

This only delegates those three specific subdomains — everything else about
`smartmansion.de` (the actual A records, MX, etc.) stays fully managed at
Strato as before. DNS propagation can take a few hours; verify with:

```bash
dig NS _acme-challenge.smartmansion.de
```

### 3. Provide the token to the cluster

`scripts/09-generate-app-secrets.sh` will prompt for the deSEC API token (or
read it from `secrets-vault/manual-credentials.env` if you pre-filled it) and
seal it into `gitops/sealed-secrets/desec-token.yaml` (see
[`05-sealed-secrets.md`](05-sealed-secrets.md) — every generated SealedSecret
in this repo lives in that one folder, not next to the component it targets).
Nothing else to do manually — the `letsencrypt-staging`/`letsencrypt-prod`
ClusterIssuers (applied by `scripts/06-install-cert-manager.sh`) already
reference that secret by name.

### 4. Issue a real certificate for the first time

Test against **staging** first — Let's Encrypt's production server has tight
rate limits, and a typo-driven retry loop can lock you out for about a week.
The app Ingress manifests under `gitops/apps/*/` default to
`cert-manager.io/cluster-issuer: letsencrypt-staging`. Once
`kubectl describe certificate -n <namespace> <name>` shows `Ready`, switch the
annotation to `letsencrypt-prod` and let ArgoCD resync.

## Fallback: self-signed internal CA

`gitops/infrastructure/cert-manager/manifests/cluster-issuers.yaml` also
creates a `smartmansion-internal` ClusterIssuer backed by a self-signed CA —
zero external dependencies, works even if deSEC/Strato/the webhook are
unreachable. To use it, change an Ingress's `cert-manager.io/cluster-issuer`
annotation to `smartmansion-internal`. Export the CA once and import it on
your devices to avoid browser warnings:

```bash
kubectl --kubeconfig kubeconfig -n cert-manager get secret smartmansion-internal-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > secrets-vault/smartmansion-ca.crt
```

Since access is VPN/LAN-only anyway (per the original design), importing one
CA per device is a one-time, low-friction step — this is the recommended
fallback, not a lesser option.

## Troubleshooting

- `kubectl get clusterissuer` shows `Ready` even without the deSEC token or
  NS delegation done — that condition only reflects successful ACME account
  *registration* with Let's Encrypt, not that DNS-01 challenges will succeed.
- `kubectl describe certificaterequest -n <ns> <name>` and
  `kubectl describe challenge -n <ns>` are the two commands that actually show
  DNS-01 failures (e.g. "no such host" means the NS delegation hasn't
  propagated yet, or the deSEC domain wasn't created).
- `kubectl get apiservice v1alpha1.acme.ukmetrics.ca` should show `Available:
  True`; if not, check `kubectl -n cert-manager logs deploy/desec-webhook`.
