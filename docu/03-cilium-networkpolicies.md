# Cilium & NetworkPolicies

## Why Cilium specifically

Three jobs at once, replacing what would otherwise be 2-3 separate
components:

1. **CNI** — pod networking (`cni.name: none` in `talos/patches/common.yaml`
   hands this off from Talos's default Flannel to Cilium).
2. **kube-proxy replacement** (`kubeProxyReplacement: true` in
   `gitops/infrastructure/cilium/values.yaml`, with matching
   `cluster.proxy.disabled: true` in the Talos config) — eBPF-based service
   routing instead of iptables.
3. **Ingress Controller** (`ingressController.enabled: true`) — avoids
   needing a separate nginx-ingress deployment; plain `Ingress` resources in
   `gitops/apps/*/` are served directly by Cilium's embedded Envoy.
4. **NetworkPolicy enforcement** — the actual point of this document.

## The policy model used here

Every app namespace (`nextcloud`, `onlyoffice`) gets a `CiliumNetworkPolicy`
(Cilium's own CRD, not plain Kubernetes `NetworkPolicy` — chosen specifically
for the `fromEntities: [ingress]` feature below) that:

- **Default-denies ingress** to everything in the namespace except what's
  explicitly allowed (`endpointSelector: {}` with only listed `ingress`
  rules matching).
- **Allows traffic from Cilium's own Ingress Controller** via
  `fromEntities: [ingress]` — this is how `https://nextcloud.lan` actually
  reaches the Nextcloud pod at all.
- **Allows same-namespace traffic** via `fromEndpoints: [{}]` — e.g. Nextcloud
  talking to its own PostgreSQL/Redis pods.
- **Allows specific cross-namespace traffic** where genuinely needed — e.g.
  Nextcloud ↔ OnlyOffice, for the WOPI document-editing callback, matched via
  Cilium's reserved `k8s:io.kubernetes.pod.namespace` label.

**Egress is deliberately left unrestricted.** Locking down egress too (DNS,
container registry pulls, app-store/update checks, push notification
services) would need a much longer allowlist per app for limited benefit at
homelab scale. Documented as a known scope limitation, not an oversight — a
reasonable next hardening step if you want it.

## Home Assistant is the exception

`gitops/apps/homeassistant/network-policy.yaml` exists but is **not
authoritative**. `hostNetwork: true` (required for mDNS — see
[`07-homeassistant.md`](07-homeassistant.md)) means the pod uses the node's
own network namespace directly; Cilium's per-pod policy enforcement doesn't
apply to it (that would require the separate "host firewall" feature,
`--enable-host-firewall`, which is not turned on here). Don't rely on that
file for HA's actual isolation — the router/VLAN segmentation discussed when
this project was scoped is what actually contains it.

## Debugging policies

```bash
kubectl --kubeconfig kubeconfig -n <ns> get ciliumnetworkpolicy
cilium status                                    # from a cilium-agent pod, or via `cilium` CLI if installed
kubectl -n kube-system exec -it ds/cilium -- cilium policy trace \
  --src-k8s-pod <ns>/<pod> --dst-k8s-pod <ns>/<pod>
```

Hubble UI (enabled in `gitops/infrastructure/cilium/values.yaml`) gives a
visual flow view:

```bash
kubectl --kubeconfig kubeconfig -n kube-system port-forward svc/hubble-ui 12000:80
```
