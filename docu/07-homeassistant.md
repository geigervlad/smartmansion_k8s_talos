# Home Assistant

Deployed via the community-maintained `pajikos/home-assistant` Helm chart
(https://pajikos.github.io/home-assistant-helm-chart/, pinned to `0.3.81`,
appVersion `2026.9.2` — see
[`gitops/apps/homeassistant/application.yaml`](../gitops/apps/homeassistant/application.yaml)).
No *official* chart exists (Home Assistant itself doesn't publish one) —
this is the most actively maintained community option: it auto-releases a
new chart version alongside every upstream Home Assistant release. See
[`gitops/apps/homeassistant/values.yaml`](../gitops/apps/homeassistant/values.yaml).

## `hostNetwork: true` — why, and what it costs

mDNS/SSDP-based device discovery (HomeKit, Chromecast, most consumer IoT
integrations) needs real multicast traffic, which does not pass through
Kubernetes' overlay pod network. `hostNetwork: true` puts the pod directly on
the node's own network namespace, so it sees the same LAN traffic the node
itself does — which only works at all because the 6 VMs use VirtualBox's
**Bridged Adapter** networking (see [`01-architecture.md`](01-architecture.md)),
putting every node on the real LAN rather than behind VirtualBox's NAT.

The cost, stated plainly: this pod bypasses Cilium's NetworkPolicy
enforcement entirely (see
[`03-cilium-networkpolicies.md`](03-cilium-networkpolicies.md)) and can bind
to any port on whichever node it's scheduled to. It is, by design, the most
privileged workload in this cluster. This was a known, accepted tradeoff from
the original design discussion — the actual isolation for this workload is
your router/VLAN setup, not this cluster. `dnsPolicy: ClusterFirstWithHostNet`
(set in `values.yaml`) keeps it using cluster DNS despite `hostNetwork`.

## Accessing it

- `https://homeassistant.localhost` (via the Ingress + cert-manager, same
  pattern as the other apps).
- Directly at `http://<node-ip>:8123` on whichever of the 3 workers it's
  currently scheduled to (`kubectl -n homeassistant get pods -o wide`) — no
  `nodeSelector` is set, since all 3 workers are equally on the LAN, so this
  address can change across reschedules. The Ingress hostname is the stable
  way to reach it.

## First run

Home Assistant's own setup wizard runs on first access at the URL above —
create the admin account there (not generated/sealed by this repo, unlike
Nextcloud). Config persists to a 10Gi `local-path` PVC.

## Extending this (out of scope here, but common next steps)

- **USB Zigbee/Z-Wave dongles**: the chart supports `additionalVolumes` /
  `additionalMounts` for a `hostPath` device mount — see the chart's own
  README for `securityContext`/capability requirements, not configured here
  since it depends on which specific hardware you have.
- **Static node placement**: add `nodeSelector` in `values.yaml` if you want
  it pinned to one specific worker (e.g. the one physically closest to a USB
  dongle).
- **Custom `configuration.yaml`**: the chart can manage it declaratively via
  `configuration.enabled: true` — left off here (`false`, the default) so
  Home Assistant's own UI-managed config from the setup wizard isn't
  overwritten on every sync; see the chart's `configuration.templateConfig`
  value if you want to switch to a fully declarative config file later.
