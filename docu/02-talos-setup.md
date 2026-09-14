# Talos Setup

Covers `scripts/01-create-vms.sh` through `scripts/03-bootstrap-cluster.sh`.

## 1. The Image Factory schematic (Longhorn extensions)

Stock Talos can't run Longhorn — it needs the `siderolabs/iscsi-tools` and
`siderolabs/util-linux-tools` system extensions baked into the image.
`ensure_talos_schematic_id()` in `scripts/lib/common.sh` POSTs the extension
list to `factory.talos.dev/schematics` once and caches the returned ID in
`talos/_out/schematic-id.txt`. That same ID is used for both:

- the boot **ISO** (`https://factory.talos.dev/image/<id>/<version>/metal-amd64.iso`,
  downloaded by `scripts/01-create-vms.sh`), and
- the **install image** referenced in each node's machine config
  (`factory.talos.dev/installer/<id>:<version>`, set by
  `scripts/02-generate-talos-config.sh`) — this second part matters: without
  it, the extensions would only exist on the live boot ISO, not survive the
  install-to-disk step, and Longhorn would fail on every node after first boot.

## 2. VM creation (`01-create-vms.sh`)

Deterministic MAC addresses (`node_mac_nocolon()` in `common.sh`,
`08:00:27:AA:00:<index>`) are assigned per VM so later steps can find a VM on
the LAN without needing to persist any state — see step 3. Workers get a
second virtual disk (`NODE_LONGHORN_DISK_GB` in `config/cluster.env`) purely
for Longhorn; control-plane nodes don't.

## 3. Machine config generation (`02-generate-talos-config.sh`)

`talosctl gen config` runs once (generates the cluster's CA/secrets — this
must NOT be re-run against an existing cluster, the script checks for and
skips this if `talos/_out/controlplane.yaml` already exists). Three patch
layers are merged, in order:

1. `talos/patches/common.yaml` — disables the default Flannel CNI (`cni.name:
   none`) and kube-proxy (`proxy.disabled: true`), since Cilium replaces both.
2. `talos/patches/controlplane.yaml` / `talos/patches/worker.yaml` — role-specific.
3. A per-node patch generated inline in the script — static IP, hostname,
   install image, and (workers only) the extra disk/mount config for Longhorn.

If a worker's second disk doesn't show up as `/dev/sdb` (the script's
assumption), check with `talosctl get disks -n <node-ip>` and adjust the
per-node patch in `scripts/02-generate-talos-config.sh` accordingly.

**Talos CLI syntax note**: `talosctl machineconfig patch` (used to render the
final per-node config) has changed flags across Talos versions. If this step
errors, run `talosctl machineconfig patch --help` against your installed
version and adjust the script.

## 4. Bootstrap (`03-bootstrap-cluster.sh`)

Each VM boots into Talos "maintenance mode" and gets a temporary DHCP IP —
there's no way to know that IP in advance, so `discover_ip_for_mac()` in
`common.sh` actively ARP-scans the LAN (`nmap -sn`) and greps the host's ARP
table for the VM's known MAC address, polling until it appears. Once found,
`talosctl apply-config --insecure` pushes that node's real config, which
makes it reboot onto its permanent static IP.

After all 6 nodes have their config, etcd is bootstrapped on the first
control-plane node (`talosctl bootstrap`) and `kubeconfig`/`talosconfig` are
written to the repo root (gitignored).

**Expected and not a bug**: `kubectl get nodes` will show every node as
`NotReady` until `scripts/04-install-cilium.sh` runs — there's no CNI yet.

## Useful commands

```bash
talosctl --talosconfig talosconfig -n <node-ip> dashboard
talosctl --talosconfig talosconfig -n <node-ip> get disks
talosctl --talosconfig talosconfig -n <node-ip> logs kubelet
kubectl --kubeconfig kubeconfig get nodes -o wide
```
