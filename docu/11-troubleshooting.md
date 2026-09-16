# Troubleshooting

## VM / Talos layer

**`scripts/01-create-vms.sh` VMs don't get a LAN IP / `discover_ip_for_mac`
times out**
- Check `VBOX_BRIDGE_ADAPTER` in `config/cluster.env` actually matches a real
  interface: `VBoxManage list bridgedifs | grep ^Name`.
- Confirm the VM is actually running: `VBoxManage list runningvms`.
- Your router's DHCP pool might not have a free lease, or might be filtering
  by known MAC addresses — check the router's DHCP client list.

**`apply-config` fails with something like `failed to create client
connection: parse "dns:///dns:///[...waiting for VM with MAC...]:50000":
net/url: invalid control character in URL`**
- Fixed (was a real bug, not a network issue): `discover_ip_for_mac()`'s
  progress messages leaked into its own return value. `log_info`/`log_step`
  in `scripts/lib/common.sh` used to print to stdout; any function that both
  logs progress internally *and* returns a value via a final `echo` for the
  caller to capture with `$(...)` had this same latent bug — command
  substitution captures ALL of a function's stdout, log lines included, not
  just the last `echo`. It only showed up once discovery took more than one
  polling loop (i.e. didn't find the MAC on the very first `nmap` sweep) —
  early testing happened to always succeed on the first try, which is why
  this wasn't caught immediately. All logging now goes to stderr, which is
  also just the correct convention (diagnostics vs. actual return value).
  If you hit something like this elsewhere, check for the same pattern: a
  function capturing `$(some_function_that_also_logs)`.

**`apply-config` fails 3x with `authentication handshake failed: context
deadline exceeded` against a node you're pretty sure is already healthy**
- Confirmed real scenario, now fixed at the root: `scripts/01-create-vms.sh`
  used to treat every failure of "is this node already reachable?" the same
  way, including the common "reachable but its cert isn't valid *yet*"
  clock-skew case (see below) — which then wasted ~100s+ on an unnecessary
  ARP-discovery round before eventually trying `--insecure apply-config`
  against a node that had long since left maintenance mode (always
  rejected). `check_node_status()` in this script now inspects *why* the
  check failed: a "not yet valid" cert error short-circuits straight to
  waiting for the clock to catch up (skipping VM-creation/ARP-discovery
  entirely), while a genuine unreachability still falls through to the
  normal create-and-configure path. A leftover fallback later in the script
  still catches the rare case where ARP discovery itself returns the node's
  own static IP. If you still hit the handshake-timeout error after this
  fix, check the node is actually healthy with `talosctl --talosconfig
  talosconfig -n <static-ip> -e <static-ip> version --short` directly
  before assuming something is wrong.

**VM hangs at startup (headless) and never boots**
- Confirmed on this project: switch the graphics controller to VMSVGA with
  enough VRAM (`--graphicscontroller vmsvga --vram 128` — already in
  `scripts/01-create-vms.sh`). If you still see this on VMs created before
  that fix landed, power them off and re-run `./scripts/01-create-vms.sh`
  (it re-applies `modifyvm` settings to existing, stopped VMs, not just new
  ones).

**VM hangs during shutdown/reboot, or just hangs and stops responding on the
network entirely — kernel log shows `rcu_sched self-detected stall on CPU`,
`sched: DL replenish lagged too much`, `gave up on ... while stopping
"machined"`, or similar cgroup-cleanup timeouts**

All confirmed real on this project, roughly in the order they're worth
checking:

1. **`--accelerate3d on`** — VirtualBox's 3D pass-through introducing
   erratic scheduling latency into the guest. `scripts/01-create-vms.sh` now
   sets `--accelerate3d off` unconditionally — a headless Talos node has no
   use for 3D acceleration anyway. If you're on a version of this script
   from before that fix, power off the VM and re-run
   `./scripts/01-create-vms.sh` to re-apply.
2. **Windows power plan set to "Balanced"** — aggressive CPU core
   parking/downclocking causes exactly this kind of host-side vCPU
   scheduling jitter. Check with `powercfg /getactivescheme`; switch to
   "Ultimate Performance" (or at least "High performance") with
   `powercfg /setactive <GUID>` (`powercfg /list` shows the GUIDs). This is
   a host-wide Windows setting, not something `01-create-vms.sh` can set for
   you. Confirmed to fix most occurrences on this project — not host CPU
   overcommit (check `Get-CimInstance Win32_Processor` / `nproc` if in
   doubt; 18 vCPUs across 6 VMs is well within reach of any reasonably
   modern multi-core host).
3. **Hyper-V / WSL2 / Docker Desktop enabled on the host** — forces
   VirtualBox to run guests via the Windows Hypervisor Platform (NEM)
   execution engine instead of native VT-x, which has materially worse
   timer/scheduling fidelity. This is a structural limitation, not a bug:
   confirmed by VirtualBox itself rejecting the classic
   `VBoxManage setextradata <vm> "VBoxInternal/TM/TSCTiedToExecution" 1`
   workaround with `"not supported in NEM mode"` on a host with Hyper-V
   active — that fix only applies under native VT-x. Stopping Docker
   Desktop's own VM (`wsl --list --running`, `wsl --shutdown`) does NOT
   reliably prevent this — confirmed it can still happen with no Docker
   Desktop VM running at all, since Hyper-V itself (not any specific VM
   using it) is what forces NEM mode. There is no clean fix short of
   disabling Hyper-V entirely (which breaks WSL2/Docker Desktop until
   re-enabled — a real trade-off, not something to do without deciding you
   want it). Practical remedy when a VM genuinely hangs (not self-recovering
   within a minute or so): power off and restart it —
   `VBoxManage controlvm <vm> poweroff` then
   `VBoxManage startvm <vm> --type headless`, then re-run
   `./scripts/01-create-vms.sh` (it detects and resumes cleanly). A hang
   that resolves on its own (kernel watchdog restarts the guest) needs no
   intervention at all — check `arp -a` for the node's MAC first to see if
   it's actually still unresponsive before assuming the worst.

   **Experimental mitigation, not yet confirmed either way**:
   `scripts/01-create-vms.sh` sets `--paravirtprovider hyperv` instead of
   the Linux-guest default (`kvm`) — since the host's real execution engine
   under NEM genuinely *is* Hyper-V, exposing that honestly to the guest
   (Linux supports Hyper-V paravirt too) may give it a more accurate clock
   reference than emulating a KVM clocksource that isn't really there,
   which could reduce false-positive stall warnings. Unlike
   `TSCTiedToExecution`, VirtualBox does not reject this under NEM. If it
   doesn't help, or makes hangs more frequent, change it back to
   `--paravirtprovider kvm` in `scripts/01-create-vms.sh` and re-run —
   existing VMs need a poweroff/restart to pick up the change (it's a
   `modifyvm` setting, applied on next boot).

**`apply-config` fails with `authentication handshake failed: context
deadline exceeded`**
- `scripts/01-create-vms.sh` retries this 3x automatically (10s
  apart) — a transient handshake failure like this is more likely on the
  Wi-Fi bridge workaround than on wired Ethernet, and usually clears up on
  its own within a couple of tries. If it fails all 3 attempts, it's
  probably not transient — check the VM is actually still running and
  reachable (`ping <maintenance-ip>`) rather than assuming a config problem;
  a missing/unresolved hostname is *not* the cause — maintenance mode has no
  need for one.

**Script looks stuck with no new output after `Ejecting install ISO from
...` — nothing happens for minutes**
- Confirmed real bug, now fixed: the eject step itself was already done by
  the time you'd see that log line (it prints *before* the actual
  `VBoxManage storageattach ... emptydrive` call, but that call returns
  fast). What actually hangs is the *next* step — `bootstrap_etcd_if_first_cp()`'s
  idempotency check, `talosctl ... etcd status`, against a node whose etcd
  has never been bootstrapped: that gRPC endpoint isn't listening at all
  pre-bootstrap, so the call blocked forever instead of failing fast. Fixed
  by `talosctl_ctx_t()` in `scripts/lib/common.sh` (same as `talosctl_ctx`
  but wrapped in `timeout 15`), used for this check and the post-bootstrap
  `wait_for` in both `scripts/01-create-vms.sh` and
  `scripts/03-bootstrap-cluster.sh`. If your script is currently stuck here,
  Ctrl+C it and re-run — nothing was lost, the ISO eject already succeeded
  and etcd bootstrap will now proceed properly instead of hanging on the
  check before it. If you ever add a new `talosctl ...` call that queries
  cluster state that might not exist yet, consider whether it needs
  `talosctl_ctx_t` instead of the unbounded `talosctl_ctx`.

**Static IP never takes effect — node stays on its DHCP address forever,
`talosctl` times out reaching the static IP**
- Confirmed root cause on this project: the machine config's
  `machine.network.interfaces[].interface` field must match Talos's *actual*
  kernel interface name, and it is **not always `eth0`**. On this host's
  VirtualBox VMs (e1000 emulated NIC) it's `enp0s3`. Silent failure mode: no
  error at all, the interface config for `eth0` just never matches anything,
  the node quietly keeps whatever DHCP gave it, and every symptom looks like
  a networking or DNS problem instead of a config problem.
- Verify empirically rather than assume, on any node still in maintenance
  mode: `talosctl get link -n <maintenance-ip> --insecure` — look for the
  `up`/`true` entry whose HW ADDR matches the node's known MAC
  (`node_mac_colon()` in `scripts/lib/common.sh`). Fix the `interface:`
  value in `scripts/02-generate-talos-config.sh`'s `render_node_config` if
  it differs, then regenerate and re-apply.

**Node's TLS certs say "not yet valid" / "certificate has expired or is not
yet valid"**
- This means the node already finished installing (insecure/maintenance mode
  is gone for good on that node) but its own clock was a bit ahead of true
  time when it minted its certs. Two very different severities of the same
  underlying thing, tell them apart by how big the skew is (the error message
  states both timestamps):
  - **A couple of minutes or less** — confirmed benign and self-resolving:
    the node's clock is briefly ahead right after install, before NTP does
    its first correction, so the cert's "not valid before" timestamp is only
    a short distance in the future. Just wait — `scripts/01-create-vms.sh`'s
    safety net for this already waits up to 240s for exactly this case. No
    action needed; don't wipe the node over this.
  - **Hours or days** — not self-resolving, and even `--insecure` will now
    refuse to connect (maintenance mode is gone for good on that node).
    Usually downstream of the interface-name bug above on an earlier attempt:
    no working static network config meant NTP (`pool.ntp.org`) was also
    unreachable for a long time, so the VM's virtual RTC drifted badly before
    ever getting corrected. There is no client-side fix in this case — wipe
    that node's OS disk and let it reinstall cleanly:
    ```bash
    rm -f "<VirtualBox default machine folder>/smartmansion-<node>/smartmansion-<node>-os.vdi"
    ```
    then re-run `./scripts/01-create-vms.sh` (recreates the blank disk, boot
    order falls through to the ISO again) and `./scripts/03-bootstrap-cluster.sh`.
  Fix the root cause (interface name, above) first, or it'll just happen again.

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
