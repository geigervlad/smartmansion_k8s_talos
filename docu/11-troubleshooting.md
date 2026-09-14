# Troubleshooting

## VM / Talos layer

**`scripts/01-create-vms.sh` VMs don't get a LAN IP / `discover_ip_for_mac`
in `scripts/03-bootstrap-cluster.sh` times out**
- Check `VBOX_BRIDGE_ADAPTER` in `config/cluster.env` actually matches a real
  interface: `VBoxManage list bridgedifs | grep ^Name`.
- Confirm the VM is actually running: `VBoxManage list runningvms`.
- Your router's DHCP pool might not have a free lease, or might be filtering
  by known MAC addresses — check the router's DHCP client list.

**A node never goes `Ready` after `scripts/04-install-cilium.sh`**
- `kubectl --kubeconfig kubeconfig describe node <name>` — look for taints
  that shouldn't be there, or a kubelet that never registered.
- `talosctl --talosconfig talosconfig -n <ip> logs kubelet`

**Longhorn shows a node/disk unhealthy**
- Confirm the second VirtualBox disk actually exists for that VM and shows
  up as `/dev/sdb` — `talosctl --talosconfig talosconfig -n <ip> get disks`.
  If it's a different device name, fix the assumption in
  `scripts/02-generate-talos-config.sh` (`render_node_config`) and re-apply
  that node's config.
- `kubectl --kubeconfig kubeconfig -n longhorn-system get nodes.longhorn.io -o yaml`

## cert-manager / DNS

**`ClusterIssuer` is `Ready` but no certificate ever issues**
- That's expected until both the deSEC token is sealed AND the Strato NS
  delegation has propagated — see [`09-cert-manager-dns.md`](09-cert-manager-dns.md).
- `kubectl --kubeconfig kubeconfig -n <app-ns> describe certificate <name>`
  and `describe challenge` (if one exists) show the actual DNS-01 failure
  reason.
- `dig NS _acme-challenge.smartmansion.de` should return deSEC's nameservers
  — if it doesn't, the Strato delegation hasn't propagated yet (can take
  hours) or wasn't entered correctly.

**`desec-webhook` pod CrashLoopBackOff or APIService never `Available`**
- `kubectl --kubeconfig kubeconfig -n cert-manager logs deploy/desec-webhook`
- This is an unpinned (`:latest`) community image — if it suddenly breaks
  after previously working, check
  https://github.com/kmorning/cert-manager-webhook-desec for upstream
  changes before assuming the vendored manifest is wrong. Fallback: switch
  the affected Ingress's `cert-manager.io/cluster-issuer` annotation to
  `smartmansion-internal` (see [`09-cert-manager-dns.md`](09-cert-manager-dns.md)).

**Hit a Let's Encrypt rate limit**
- You were issuing against `letsencrypt-prod` directly instead of testing
  with `letsencrypt-staging` first. Wait out the rate limit window (up to a
  week for repeated failures) and switch to staging until it issues cleanly.

## ArgoCD / GitOps

**An Application stuck `OutOfSync` after adoption from a script-installed
Helm release**
- Usually cosmetic on the first sync (Helm CLI release metadata vs ArgoCD's
  own tracking) — see [`04-argocd-gitops.md`](04-argocd-gitops.md). If it
  persists, diff the live values against the exact `values.yaml` the
  bootstrap script used.

**root-app doesn't pick up a new `application.yaml`**
- Confirm the filename actually matches `**/application*.yaml` (root-app's
  `directory.include` glob) and that it was actually pushed
  (`git log origin/main`, not just committed locally).

## SealedSecrets

**`SealedSecret` exists but the resulting `Secret` never appears**
- `kubectl --kubeconfig kubeconfig -n sealed-secrets logs deploy/sealed-secrets`
  — usually means the SealedSecret was encrypted for a different
  cluster/key (e.g. sealed against a stale `pub-cert.pem` after a cluster
  rebuild) — see the restore procedure in
  [`05-sealed-secrets.md`](05-sealed-secrets.md).

## Home Assistant

**mDNS / device discovery doesn't find anything**
- Confirm the VM actually got a real LAN IP (bridged, not NAT) — see the VM
  layer section above; `hostNetwork: true` only helps if the node itself is
  genuinely on the LAN.
- Confirm the pod actually has `hostNetwork: true` set:
  `kubectl --kubeconfig kubeconfig -n homeassistant get pod -o yaml | grep hostNetwork`.

## General

- Every script sources `scripts/lib/common.sh` and uses `log_info`/`log_warn`/
  `log_error` consistently — re-run the specific failing
  `scripts/0N-*.sh` directly (not the whole `MASTER.sh`) to get a faster
  feedback loop while debugging one step.
- `kubectl --kubeconfig kubeconfig get events -A --sort-by=.lastTimestamp | tail -50`
  is usually the fastest way to see what's actually failing cluster-wide.
