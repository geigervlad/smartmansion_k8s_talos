# Talos Setup

Covers `scripts/01-create-vms.sh` (does almost everything — see below),
`scripts/02-generate-talos-config.sh` (optional utility), and
`scripts/03-bootstrap-cluster.sh` (the cluster-wide tail).

## Why one node at a time

`scripts/01-create-vms.sh` brings up each of the 6 nodes **fully** — create
the VM, start it, render and apply its Talos config, wait for it to come up
on its static IP — before moving to the next node. Deliberately not "create
all 6 VMs, then configure all 6 separately": if a node has a problem, this
surfaces and stops on it immediately, rather than discovering it only after
5 more VMs were already created and running.

**etcd is also bootstrapped on the first control-plane node as soon as it's
up**, before the second node is even created — not deferred to the very end.
This is safe, not just convenient:

- `talosctl bootstrap` is a **one-time** action on exactly one seed node.
  Every other control-plane node joins that already-initialized etcd
  automatically (dynamic membership) once *its own* config is applied —
  there's no separate "bootstrap" step for cp2/cp3, so nothing is lost by
  doing cp1's bootstrap before cp2 exists.
- etcd membership changes are safest applied one at a time, which this
  sequential ordering gives for free.
- **Cilium is not required for any of this.** `etcd`/`kube-apiserver`/
  `kube-scheduler`/`kube-controller-manager` all run with `hostNetwork:
  true` (same as kubeadm-style clusters), independent of any CNI. Cilium
  only matters for pod-to-pod traffic between nodes and for kubelet
  reporting `Ready` instead of `NotReady` — irrelevant during node
  bootstrap. Cilium install (`scripts/04-install-cilium.sh`) deliberately
  stays a separate, later step, after all 6 nodes are up — see
  [`01-architecture.md`](01-architecture.md) for the full picture.

## 1. The Image Factory schematic

`ensure_talos_schematic_id()` in `scripts/lib/common.sh` POSTs a list of
system extensions to `factory.talos.dev/schematics` once and caches the
returned ID in `talos/_out/schematic-id.txt`. That same ID is used for both:

- the boot **ISO** (`https://factory.talos.dev/image/<id>/<version>/metal-amd64.iso`,
  downloaded once up front by `scripts/01-create-vms.sh`, before the
  per-node loop starts), and
- the **install image** referenced in each node's machine config
  (`factory.talos.dev/installer/<id>:<version>`, set by
  `render_node_config_file()` in `scripts/lib/common.sh`) — this second part
  matters: without it, the extensions would only exist on the live boot ISO,
  not survive the install-to-disk step.

**Historical note**: the extensions requested are `siderolabs/iscsi-tools`
and `siderolabs/util-linux-tools` — stock Talos can't run Longhorn without
them. This project switched from Longhorn to local-path-provisioner (see
[`01-architecture.md`](01-architecture.md) and
[`11-troubleshooting.md`](11-troubleshooting.md) for why), which doesn't
need iSCSI at all — but the extensions are already baked into all 6
already-installed nodes and are harmless to leave in place, so they were
never removed. Not worth reinstalling Talos on 6 nodes to shave two unused
extensions off the image.

## 2. Per-node loop (`01-create-vms.sh`)

Before the loop starts: the ISO is downloaded (once) and
`ensure_base_talos_config()` generates the cluster-wide Talos secrets/CA +
`controlplane.yaml`/`worker.yaml` (once — this must NOT be re-run against an
existing cluster; it's skipped automatically if `talos/_out/controlplane.yaml`
already exists). Three patch layers get merged into that base config:

1. `talos/patches/common.yaml` — disables the default Flannel CNI (`cni.name:
   none`) and kube-proxy (`proxy.disabled: true`), since Cilium replaces both.
2. `talos/patches/controlplane.yaml` / `talos/patches/worker.yaml` — role-specific.
3. A per-node patch generated inline by `render_node_config_file()` in
   `scripts/lib/common.sh` — static IP, hostname (via its own
   `HostnameConfig` document, see below), install image, and a
   `UserVolumeConfig` document dedicating the second disk to storage (still
   named "longhorn" — see below and [`01-architecture.md`](01-architecture.md)).

Then, for each node in turn:

1. **Create + start the VM.** Deterministic MAC addresses
   (`node_mac_nocolon()` in `common.sh`, `08:00:27:AA:00:<index>`) mean later
   steps can find a VM on the LAN without persisting any state. All 6 nodes
   get a second virtual disk for storage (`NODE_LONGHORN_DISK_GB` in
   `config/cluster.env`).

   Boot order is **disk before dvd** (`--boot1 disk --boot2 dvd`), not the
   more intuitive-looking dvd-first: on a brand new VM the disk is blank, so
   the BIOS falls through to the attached Talos ISO and installs; every boot
   after that finds a valid install on disk and never touches the ISO again.
   Getting this backwards means the VM re-boots the installer ISO forever
   instead of the installed system. `eject_iso_if_present()` (in
   `common.sh`) also explicitly ejects the ISO once a node proves it's
   running from its real install, as a second safety net on top of the boot
   order.

   `--nicpromisc1 allow-all` on the bridged NIC works around a confirmed
   issue bridging over Wi-Fi (see `VBOX_BRIDGE_ADAPTER`'s comment in
   `config/cluster.env`): without it, traffic to/from the VMs' own MAC
   addresses can be silently dropped. Harmless on wired Ethernet.

   `--graphicscontroller vmsvga --vram 128 --accelerate3d off`: the default
   graphics controller has been observed to hang some VMs at startup on this
   project — VMSVGA with enough VRAM fixes that. 3D acceleration is
   deliberately left **off**: turning it on caused a *different* hang,
   during shutdown/reboot (`rcu_sched self-detected stall`, `sched: DL
   replenish lagged too much` in the kernel log) — VirtualBox's 3D
   pass-through introducing erratic guest scheduling latency, not a host
   resource problem. A headless Talos node has no use for 3D acceleration.

2. **Render this node's config** — `render_node_config_file()`.

3. **Find it in DHCP maintenance mode and apply the config.** Each VM boots
   into Talos "maintenance mode" and gets a temporary DHCP IP — there's no
   way to know that IP in advance, so `discover_ip_for_mac()` in `common.sh`
   actively ARP-scans the LAN (`nmap -sn`) and greps the host's ARP table for
   the VM's known MAC address, polling until it appears. `talosctl
   apply-config --insecure` is then retried up to 3 times (10s apart) — a
   transient handshake failure ("context deadline exceeded") is more likely
   on the Wi-Fi bridge workaround than on wired Ethernet, and usually clears
   up within a couple of tries.

4. **Wait for it to come up on its static IP**, then eject the ISO — proof
   the install-to-disk + reboot succeeded.

Only then does the loop move to the next node.

### Talos v1.10+'s multi-document config (two lessons learned the hard way)

**Talos v1.10+ moved several settings out of the classic monolithic
`machine:` block into their own separate YAML documents** (the config file is
multi-document, `---`-separated) — two of these bit this project during
setup and are worth knowing about if you hit similar errors:

- **Hostname**: `machine.network.hostname` still exists in the schema but
  conflicts with the new `HostnameConfig` document's `auto: stable` default
  ("static hostname is already set"). Fix: don't set
  `machine.network.hostname` at all; instead ship a `HostnameConfig` document
  with `auto: "off"` (the *only* other valid value — empty string is
  rejected) and `hostname: <name>`.
- **Disks**: the legacy `machine.disks` + `machine.kubelet.extraMounts` combo
  used in earlier drafts of this project doesn't appear in the v1.12
  reference at all. The current mechanism is a `UserVolumeConfig` document —
  `name` and `volumeType` are **top-level fields on the document itself**,
  *not* nested under `metadata:`/`provisioning:` (an easy mistake — Talos
  rejects the nested form as "unknown keys"); only `diskSelector` (and
  `minSize`/`maxSize` for a partition instead of a whole disk) goes under
  `provisioning:`:
  ```yaml
  apiVersion: v1alpha1
  kind: UserVolumeConfig
  name: longhorn
  volumeType: disk
  provisioning:
    diskSelector:
      match: disk.dev_path == '/dev/sdb'
  ```
  (`disk.deviceName` doesn't exist — the CEL expression is evaluated against
  the `Disks` resource's actual field names, `dev_path` is the device-path
  one; `talosctl get disks -n <ip> -o yaml` shows the full field set if you
  need to match on something else, e.g. `disk.transport`/`disk.serial`.)
  Pods can `hostPath` straight into the result, no `extraMounts` needed.
  **The mount path is not configurable**: Talos always uses
  `/var/mnt/<name>` — `/var/mnt/longhorn` here, still named after the
  storage software this project used before switching to
  local-path-provisioner (see [`01-architecture.md`](01-architecture.md)).
  local-path-provisioner's `config.json` (in
  [`gitops/infrastructure/local-path-provisioner/manifests.yaml`](../gitops/infrastructure/local-path-provisioner/manifests.yaml))
  points its `nodePathMap` at this same `/var/mnt/longhorn` path — keep the
  `name` here and that path in sync if you ever change either.

If a node's second disk doesn't show up as `/dev/sdb` (the script's
assumption), check with `talosctl get disks -n <node-ip>` and adjust
`render_node_config_file()` in `scripts/lib/common.sh` accordingly.

**The static network interface name is not `eth0`.** This one has no
validation error to catch it — the config is accepted, but if
`machine.network.interfaces[].interface` doesn't match a real interface, the
static IP/route/nameservers you specified simply never apply and the node
silently keeps whatever DHCP handed it, forever. Confirmed empirically for
this project's VirtualBox VMs (e1000 emulated NIC): the real name is
`enp0s3`, already set in `render_node_config_file()`. If you change the VM's
NIC hardware/count, re-verify with
`talosctl get link -n <maintenance-ip> --insecure` against a node still in
maintenance mode (match the `up`/`true` entry whose HW ADDR is the node's
known MAC) before trusting this value still holds — see
[`11-troubleshooting.md`](11-troubleshooting.md) for the full story,
including what happens downstream (NTP unreachable → clock drift → a node
that installs itself with certificates that are never valid, and can no
longer be talked to at all, securely or insecurely — the only way out at
that point is wiping and reinstalling that node).

**Talos CLI syntax note**: `talosctl machineconfig patch` (used to render the
final per-node config) has changed flags across Talos versions, and the
config schema itself is evolving quickly (see above) — if this step errors,
run `talosctl machineconfig patch --help` and check
https://docs.siderolabs.com/talos/<your-version>/reference/configuration/
against your installed version rather than assuming this doc is still
accurate for a much newer Talos release.

## 3. Re-rendering configs without touching VMs (`02-generate-talos-config.sh`)

Optional. `01-create-vms.sh` already renders each node's config inline as
part of its loop — this script exists for when you've edited
`config/cluster.env` or `talos/patches/*.yaml` and want to regenerate
`talos/_out/<node>.yaml` to inspect it, without creating/starting/touching
any VM. It does not apply anything anywhere by itself.

## 4. Cluster-wide tail (`03-bootstrap-cluster.sh`)

Run once all 6 nodes are up (i.e. after `01-create-vms.sh` completes — which
already bootstrapped etcd on the first control-plane node itself, see
above). Checks every node is reachable at its static IP, expands the
`talosconfig` endpoint list from just cp1 to all 3 control-plane IPs, and
writes `kubeconfig` to the repo root (gitignored).

**Expected and not a bug**: `kubectl get nodes` will show every node as
`NotReady` until `scripts/04-install-cilium.sh` runs — there's no CNI yet.

## Useful commands

```bash
talosctl --talosconfig talosconfig -n <node-ip> dashboard
talosctl --talosconfig talosconfig -n <node-ip> get disks
talosctl --talosconfig talosconfig -n <node-ip> logs kubelet
kubectl --kubeconfig kubeconfig get nodes -o wide
```
