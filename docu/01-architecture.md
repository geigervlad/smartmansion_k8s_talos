# Architecture

## Physical / virtual layout

One Debian 12 host runs VirtualBox with 6 VMs, all on a **Bridged Adapter**
(`VBOX_BRIDGE_ADAPTER` in `config/cluster.env`) — meaning every VM gets a
real IP on your home LAN from your router, exactly like a physical device
would. This is not optional: Home Assistant's `hostNetwork: true` pod (see
[`07-homeassistant.md`](07-homeassistant.md)) needs to see real mDNS/SSDP
multicast traffic from IoT devices, which only works if the node it lands on
is actually on the LAN, not behind VirtualBox's NAT.

| Node | Role | Default IP |
|---|---|---|
| cp1, cp2, cp3 | Talos control-plane | .50 – .52 |
| worker1, worker2, worker3 | Talos worker (+ Longhorn disk) | .60 – .62 |
| — | Control-plane VIP (Talos-managed) | .55 |

All defaults live in `config/cluster.env` — change them there, not in
individual scripts.

## Why 3+3 and a VIP

3 control-plane nodes gives etcd real quorum (survives 1 node down). The
shared `CLUSTER_VIP` (Talos's built-in Virtual IP feature) means the
Kubernetes API endpoint doesn't hard-depend on any single control-plane node
being up — `kubectl`/`talosctl`/ArgoCD all talk to the VIP, not to `cp1`
directly. Workloads never schedule on control-plane nodes (the default Talos
taint, made explicit in `talos/patches/controlplane.yaml`) — only the 3
workers run Nextcloud/OnlyOffice/Home Assistant/Longhorn.

## Software layers

```
VirtualBox (Debian 12 host)
  └─ Talos Linux (immutable, API-managed, minimal attack surface)
       └─ Kubernetes
            ├─ Cilium              CNI + kube-proxy replacement + Ingress Controller + NetworkPolicy
            ├─ SealedSecrets        encrypts secrets so they're safe to commit to git
            ├─ cert-manager         Let's Encrypt certs via DNS-01 (deSEC webhook, see docu/09)
            ├─ Longhorn             distributed block storage (PVCs for Nextcloud/OnlyOffice/HA)
            ├─ dyndns-updater       keeps Strato's A records pointed at this homelab's changing public IP
            ├─ ArgoCD               GitOps controller — everything above (except itself) is an Application
            └─ apps: Nextcloud, OnlyOffice, Home Assistant
```

## Why Talos specifically

Talos has no SSH, no shell, no package manager, a read-only filesystem, and
is entirely managed over its gRPC API (`talosctl`). This directly addresses
the container-escape-to-host-root concern that shaped this project: there is
barely a "host" to escape *into*. It also means near-zero OS patching —
upgrades are atomic image swaps, not `apt upgrade`.

## Trust boundaries (what actually protects what)

- **Cilium NetworkPolicy** (`CiliumNetworkPolicy` resources in each
  `gitops/apps/*/network-policy.yaml`) isolates Nextcloud/OnlyOffice from
  each other and from anything else in the cluster, default-deny except
  explicit allows. See [`03-cilium-networkpolicies.md`](03-cilium-networkpolicies.md).
- **Home Assistant is the deliberate exception**: `hostNetwork: true` bypasses
  Cilium's per-pod policy enforcement entirely. It is the most privileged
  workload in this cluster by necessity (mDNS discovery). Its real isolation
  boundary is your router/VLAN setup, not anything in this repo — a
  continuation of the network-segmentation discussion that scoped this
  project in the first place.
- **SealedSecrets** means the git repo (pushed to a *public* GitHub project)
  never contains plaintext credentials — only ciphertext only this specific
  cluster's controller can decrypt. Losing the controller's private key
  (backed up to `secrets-vault/`, see [`05-sealed-secrets.md`](05-sealed-secrets.md))
  means losing the ability to ever decrypt or rotate them.
- **cert-manager DNS-01 via deSEC** means no inbound port 80/443 needs to be
  opened to the internet to get real TLS certificates — see
  [`09-cert-manager-dns.md`](09-cert-manager-dns.md) for the full reasoning
  and the community-webhook tradeoff that was knowingly accepted.
