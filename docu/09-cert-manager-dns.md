# cert-manager, the internal CA, and `.localhost`

This project deliberately has **no public DNS involvement at all**: no
Let's Encrypt, no ACME account, no DNS-01 challenge, no delegated zone, no
DynDNS updater keeping an A record pointed at a changing public IP. Access
is LAN-only, so none of that machinery earns its keep — it existed in an
earlier version of this project (Strato + deSEC + DynDNS) purely to get a
publicly-trusted certificate for a domain reachable from the internet, and
was removed once the access model became "this network, full stop."

## The two pieces

1. **A self-signed internal CA**, created once by
   [`gitops/infrastructure/cert-manager/manifests/cluster-issuers.yaml`](../gitops/infrastructure/cert-manager/manifests/cluster-issuers.yaml):
   a bootstrap self-signed `ClusterIssuer`, a CA `Certificate` signed by it,
   and a second `ClusterIssuer` (`smartmansion-internal`) that signs
   everything else using that CA. Every app Ingress uses
   `cert-manager.io/cluster-issuer: smartmansion-internal`.
2. **`.localhost` domains** (`DOMAIN_NEXTCLOUD` etc. in `config/cluster.env`)
   resolved by a plain Windows hosts-file entry
   (`scripts/11-configure-hosts.sh`) pointing every one of them at
   `INGRESS_VIP` — the one LAN IP Cilium's Ingress Controller announces via
   L2 (see [`gitops/infrastructure/cilium/manifests/`](../gitops/infrastructure/cilium/manifests/)
   and [`01-architecture.md`](01-architecture.md)).

Neither piece talks to anything outside this network. There's nothing to
sign up for, no token to obtain, no zone to delegate.

## One-time setup

1. Run the pipeline through `scripts/06-install-cert-manager.sh` — it
   applies the ClusterIssuers, waits for the CA certificate to issue, and
   exports its public half to `secrets-vault/smartmansion-ca.crt`
   (gitignored — regenerate any time with the commands in
   "Re-exporting the CA cert" below, no need to keep this specific copy safe
   the way you would the SealedSecrets key).
2. Run `scripts/11-configure-hosts.sh` **from an Administrator shell**
   (right-click Git Bash/your terminal → "Run as administrator" — the
   Windows hosts file isn't writable otherwise) — this is what makes
   `https://nextcloud.localhost` etc. resolve at all.
3. Import `secrets-vault/smartmansion-ca.crt` into your OS/browser trust
   store — not done automatically (see "Why this is manual" below).
   - **Windows** (PowerShell, run once, no admin needed for `-CurrentUser`):
     ```powershell
     Import-Certificate -FilePath secrets-vault\smartmansion-ca.crt -CertStoreLocation Cert:\CurrentUser\Root
     ```
   - Firefox keeps its own certificate store, separate from Windows':
     Settings → Privacy & Security → Certificates → View Certificates →
     Authorities → Import.

Until step 3, every `*.localhost` app in this project loads fine but shows
a "not secure" / certificate-warning page first — the connection is still
genuinely TLS-encrypted with a real (if self-signed) cert, browsers just
don't trust the issuer yet.

### Why this is manual

Importing a certificate into your OS/browser trust store affects how your
machine trusts *everything*, not just this cluster — not something a script
in this repo should do unattended. It's also a one-time, per-device step:
do it once per machine you access these apps from, not once per pipeline run.

## Why `.localhost` specifically, and the one real caveat

`.localhost` is reserved by [RFC 6761](https://www.rfc-editor.org/rfc/rfc6761)
to always mean "this machine" — which is exactly wrong for what this
project does with it (pointing it at `INGRESS_VIP`, a *different* machine on
the LAN). Windows' own resolver checks the hosts file first, before any
built-in handling of reserved TLDs, so this works — but **not every
resolver does**: some browsers, some DNS-over-HTTPS configurations, and
some Linux/macOS resolvers hardcode `*.localhost` to `127.0.0.1` and never
consult the hosts file for it at all. If a specific browser or device won't
reach these apps no matter what `scripts/11-configure-hosts.sh` writes,
this is almost certainly why.

**The fix, if you hit this**: change `DOMAIN_NEXTCLOUD`/etc. in
`config/cluster.env` to a suffix that isn't a reserved TLD — e.g.
`.smartmansion.lan` or `.lab` — update every app's Ingress host
(`gitops/apps/*/values.yaml` / `deployment.yaml`) to match, then re-run
`scripts/11-configure-hosts.sh` and push so ArgoCD picks up the new Ingress
hostnames. No need to touch cert-manager itself — the CA signs whatever
hostname a Certificate asks for, it doesn't care what the suffix is. This
is a one-variable-family change by design, precisely because `.localhost`
might not work everywhere.

## Re-exporting the CA cert

If `secrets-vault/smartmansion-ca.crt` ever goes missing (it's gitignored,
local-only) but the cluster's CA itself is still there:

```bash
kubectl --kubeconfig kubeconfig -n cert-manager get secret smartmansion-internal-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > secrets-vault/smartmansion-ca.crt
```

## Troubleshooting

- **Browser shows "not secure" after importing the CA**: most browsers
  cache certificate trust decisions per-connection — fully close and
  reopen the browser (not just the tab).
- **`kubectl describe certificate -n <ns> <name>` never goes `Ready`**:
  check `kubectl -n cert-manager get clusterissuer smartmansion-internal`
  is `Ready` first — if the CA `Certificate` itself never issued,
  `kubectl -n cert-manager describe certificate smartmansion-internal-ca`
  is the one to check.
- **A `*.localhost` domain doesn't resolve, or resolves to `127.0.0.1`
  instead of `INGRESS_VIP`**: see "Why `.localhost` specifically" above —
  first confirm the hosts file actually has the entry
  (`cat /c/Windows/System32/drivers/etc/hosts` from Git Bash, or
  `type C:\Windows\System32\drivers\etc\hosts` from cmd), then suspect a
  resolver that ignores it for this TLD.
- **Domain resolves and the IP is reachable, but nothing answers on 443**:
  check `kubectl -n kube-system get svc cilium-ingress` has an `EXTERNAL-IP`
  matching `INGRESS_VIP` — if it's stuck `<pending>`, check
  `kubectl get ciliumloadbalancerippools` and
  `kubectl get ciliuml2announcementpolicies` (both cluster-scoped) both
  exist (see
  [`gitops/infrastructure/cilium/manifests/`](../gitops/infrastructure/cilium/manifests/)).
