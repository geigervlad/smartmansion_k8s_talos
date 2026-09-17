# Troubleshooting

## VM / Talos layer

**`ensure_base_talos_config()` (in `scripts/01-create-vms.sh` or
`scripts/02-generate-talos-config.sh`) fails with `failed to generate
config bundle: error patching worker config: JSON6902 patches are not
supported for multi-document machine configuration`, or (after "fixing" it
with an empty `{}`) `error parsing config JSON patch: config not found`**
- Confirmed real bug in talosctl itself
  ([siderolabs/talos#13029](https://github.com/siderolabs/talos/issues/13029)),
  not something this project's config got wrong: passing an "empty"
  `--config-patch*` file to `talosctl gen config` — whether the file is
  truly empty, comments-only (parses to YAML `null`), or an explicit empty
  mapping (`{}`) — has been unreliable across talosctl versions, each
  spelling failing a *different* way. There is no config-file spelling of
  "no patch" that reliably works. The actual fix: don't pass the flag at
  all when there's nothing to patch. `ensure_base_talos_config()` in
  `scripts/lib/common.sh` omits `--config-patch-worker` entirely now that
  `talos/patches/worker.yaml` is an unused placeholder — add the flag back
  only once that file has real content.
- Easy to miss because `ensure_base_talos_config()` only actually calls
  `talosctl gen config` once (skipped on every later run once
  `talos/_out/controlplane.yaml` exists) — so a bad patch file/flag can sit
  unnoticed for a long time until the next full rebuild from scratch
  actually re-runs `gen config` and hits it.

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

**Why local-path-provisioner instead of Longhorn**
- This project used Longhorn originally, then switched. Longhorn's whole
  value proposition is replicating data *across nodes* — but every node
  here is a VM on the *same single physical machine*
  ([`01-architecture.md`](01-architecture.md)), so it only protects against
  a Talos VM/OS crash, not the dominant real failure mode (that one
  machine's disk or power). Meanwhile it costs ~20+ base pods plus 3 extra
  replica pods per volume (`defaultClassReplicaCount: 3`) — confirmed to
  add up to 27 pods across just 3 worker nodes before any app was even
  deployed. local-path-provisioner: one controller pod, plain directories
  on the node's local disk, no replication, no CSI complexity. Trade-off
  accepted: a PVC's data is pinned to whichever node it was first created
  on — no live migration, no snapshots, no built-in backup.
- The second VirtualBox disk / Talos `UserVolumeConfig` mount this uses is
  still named/labeled "longhorn" (deliberately not renamed — see
  [`02-talos-setup.md`](02-talos-setup.md)). If PVCs won't bind, first
  confirm that disk actually exists and shows up as `/dev/sdb` —
  `talosctl --talosconfig talosconfig -n <ip> get disks`. If it's a
  different device name, fix the assumption in `render_node_config_file()`
  in `scripts/lib/common.sh` and re-apply that node's config.
- `kubectl --kubeconfig kubeconfig -n local-path-storage get pods` — the
  provisioner itself; `kubectl describe pvc -n <ns> <pvc>` for a specific
  stuck volume's events.

**Pods `forbidden: violates PodSecurity "baseline:latest"` — a
DaemonSet/Deployment stuck with `FailedCreate` events, or any pod needing
`hostPath`/`hostNetwork`/`privileged`**
- Confirmed real Talos platform default, not a bug: Talos enables the
  Kubernetes PodSecurity admission controller with **`baseline`
  enforcement by default for every namespace except `kube-system`**.
  Baseline forbids privileged containers, hostPath volumes, and host
  namespaces (`hostNetwork`/`hostPID`/`hostIPC`) outright — the daemonset/
  deployment controller keeps retrying pod creation forever (visible as
  repeated `FailedCreate` events over many minutes), it never just fails
  fast, which is what makes this easy to mistake for a hang or a timeout
  that just needs a longer `--wait`.
- Confirmed to affect: local-path-provisioner's per-PV "helper pod" (a
  short-lived Job that `mkdir`/`rm`'s the hostPath directory for each
  volume — see
  [`gitops/infrastructure/local-path-provisioner/manifests.yaml`](../gitops/infrastructure/local-path-provisioner/manifests.yaml))
  and Home Assistant (needs `hostNetwork: true` for mDNS — see
  [`gitops/apps/homeassistant/namespace.yaml`](../gitops/apps/homeassistant/namespace.yaml)).
  Longhorn hit this too before the switch away from it, for the same
  reason (`privileged` + hostPath to manage block devices/iSCSI directly).
  Both current namespaces are declared with the label
  `pod-security.kubernetes.io/enforce: privileged`, which opts them out of
  the restriction entirely — the namespace must have the label *before*
  any pod is created into it, and a `kubectl label` after the fact doesn't
  retroactively unstick already-rejected pods (the controller does retry
  on its own once the label is fixed, but re-running the relevant install
  script is the reliable way to confirm it — e.g. a manual
  `kubectl rollout restart` may be needed to force an immediate retry
  rather than waiting for the next periodic resync, confirmed necessary in
  practice for Longhorn's DaemonSet).
- If you add a new component later that needs any of these (privileged,
  hostPath, host namespaces), give its namespace the same label — check
  `kubectl describe pod` events for `violates PodSecurity` first to confirm
  this is actually why before assuming something else is wrong.

## Cilium

**`clean-cilium-state` (or `cilium-agent`) init container `CrashLoopBackOff`
with `unable to apply caps: can't apply capabilities: operation not
permitted`**
- Confirmed real gap in the original setup, now fixed: Talos's hardened
  kernel refuses some of the Linux capabilities Cilium's default Helm chart
  values request (`SYS_MODULE` in particular — Talos never allows workloads
  to load kernel modules, full stop). `securityContext.capabilities` in
  `gitops/infrastructure/cilium/values.yaml` now explicitly lists exactly
  the capability set Talos actually permits for `ciliumAgent` and
  `cleanCiliumState`, per Cilium's own Talos installation docs. Fix by
  re-running `./scripts/04-install-cilium.sh` (it's `helm upgrade
  --install`, safe to re-run — picks up the corrected values.yaml and
  replaces the crash-looping pods).
- While in there: `k8sServiceHost`/`k8sServicePort` also changed from the
  `CLUSTER_VIP` to Talos's own per-node API server load balancer
  (`localhost:7445`) — the officially recommended target for in-cluster
  kube-proxy-replacement clients like Cilium, since it doesn't depend on
  which node currently holds the VIP or its failover latency. This is a
  separate mechanism from the VIP, not a duplicate — `kubectl`/`talosctl`/
  ArgoCD from outside the cluster still go through `CLUSTER_VIP`.

## cert-manager / `.lan`

**`ClusterIssuer smartmansion-internal` is not `Ready`**
- Check the CA `Certificate` itself first:
  `kubectl --kubeconfig kubeconfig -n cert-manager describe certificate
  smartmansion-internal-ca` — the ClusterIssuer can't be Ready until that
  Certificate (and the `selfsigned-bootstrap` ClusterIssuer behind it) is.
  There's no external dependency here at all (no DNS, no ACME account), so
  this should self-resolve within seconds unless cert-manager itself isn't
  healthy — check `kubectl -n cert-manager get pods`.

**A `*.lan` domain doesn't resolve, or a browser shows "can't reach this
site" rather than a certificate warning**
- This is a DNS/routing problem, not a cert-manager one. See the
  troubleshooting section of [`09-cert-manager-dns.md`](09-cert-manager-dns.md)
  — check the Windows hosts file has the entry
  (`scripts/11-configure-hosts.sh` must be run from an Administrator shell),
  then check `kubectl -n kube-system get svc cilium-ingress` actually has
  `EXTERNAL-IP` set to `INGRESS_VIP`. Verify with `curl -kv https://<domain>/`
  (not `curl --resolve`, which bypasses name resolution and will hide a
  broken hosts-file lookup) — confirm it actually tries connecting to
  `INGRESS_VIP`, not `127.0.0.1`/`::1`.

**Browser still shows a certificate warning after importing
`secrets-vault/smartmansion-ca.crt`**
- Fully close and reopen the browser — most cache trust decisions per
  connection, not per page load. Firefox keeps its own certificate store
  separate from Windows' — import there too if you use it.

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

## Version pins & Helm chart migration (2026-09)

This project moved every component to the latest available *pinned* version
(Talos v1.14.0/Kubernetes 1.37.0, Cilium 1.20.2, cert-manager v1.21.2, ArgoCD
chart 10.9.1, SealedSecrets chart 2.20.0), switched Home Assistant from
plain manifests to a Helm chart, and moved every generated SealedSecret into
its own `gitops/sealed-secrets/` folder. A few non-obvious things came out
of that — and a couple of dead ends worth recording so they don't get
re-tried.

**Bitnami is effectively gone — don't reach for `bitnami/*` charts or images
at all, including as a bundled subchart dependency**
- Broadcom's Bitnami changes went further than the earlier `bitnami/*` →
  `bitnamilegacy/*` image migration (see the mariadb note below, kept for
  history): as of late 2025, free Bitnami container images/charts were
  discontinued outright, `bitnamilegacy/*` is a **frozen snapshot** (no tag
  newer than ~August 28, 2025 for any image checked via the Docker Hub API —
  `postgresql`, `redis`, `rabbitmq`, `mariadb`), and current Bitnami charts
  additionally require `global.security.allowInsecureImages: true` just to
  accept an image they can't verify a signature for. None of this is a
  temporary rough patch to work around — it's the charts themselves going
  away as a viable free option. **Don't use them, including indirectly**:
  the `nextcloud/nextcloud` chart's bundled `postgresql`/`mariadb`/`redis`
  subcharts are ALL Bitnami-sourced (`oci://registry-1.docker.io/
  bitnamicharts`), so using them (even via the parent chart's own
  `postgresql.enabled: true`) pulls in the same dead end. Fixed by disabling
  all three bundled subcharts and running plain PostgreSQL/Valkey manifests
  instead, wired in via `externalDatabase`/`externalRedis` — see
  [`06-nextcloud.md`](06-nextcloud.md).
- CloudNativePG (the modern, non-Bitnami, operator-based way to run Postgres
  on Kubernetes) was considered and deliberately **not** used — adds an
  operator + a `Cluster` CRD, real overkill for what is, here, a single
  homelab Nextcloud instance with no HA requirement. A plain
  `docker.io/library/postgres` StatefulSet is the whole database layer;
  revisit CloudNativePG only if this cluster ever needs Postgres to survive
  a node failure automatically.
- **(History, already fixed once, left for context)** Before the wider
  Bitnami discontinuation above, this project already hit the narrower
  `bitnami/mariadb` → `bitnamilegacy/mariadb` image-404 issue in August
  2025 and worked around it with a registry override — that fix is now
  moot since MariaDB itself was dropped in favor of Postgres, but the same
  *kind* of failure (a chart's default image reference 404ing without
  warning) is exactly what pushed this project off Bitnami entirely rather
  than chasing each new broken pin.

**OnlyOffice: the "official" chart is a different, heavier product than the
image this project actually wants to run**
- `ONLYOFFICE/Kubernetes-Docs` (the one Helm chart ONLYOFFICE itself
  publishes) deploys the *microservices* split — separate
  `docservice`/`converter` pods — and needs an **external**
  PostgreSQL/Redis/RabbitMQ; it does not support the all-in-one
  `onlyoffice/documentserver` image this project actually runs (which
  bundles its own internal Postgres/RabbitMQ/Redis in one container). No
  community chart avoids this either (`suda/documentserver` wraps the same
  microservices split). Tried adopting the official chart anyway once — it
  worked, but meant standing up three more stateful services just to run
  what is, here, a single Nextcloud editing backend, which is more
  complexity than this project wants for that job. Reverted to plain
  manifests (see [`08-onlyoffice.md`](08-onlyoffice.md)) — this is a
  deliberate choice, not a sign no one looked for a chart.
- **Lesson that generalizes beyond OnlyOffice, worth remembering if this
  comes up again with a different component**: ArgoCD renders with `helm
  template`, not `helm upgrade` — a chart default along the lines of
  "leave this value empty and a random one will be generated, preserved
  across upgrades" relies on Helm's `lookup` function against the live
  cluster or `helm upgrade`'s own prior-release state, neither of which a
  plain `helm template` render reliably has. Under ArgoCD, an unset value
  like that can re-randomize on every sync/self-heal — for anything baked
  into a Pod spec (an env var, a cookie/token value), that means an
  unwanted pod restart on every single reconciliation. If a future chart
  adoption hits this, the fix is the same every time: generate the value
  once in `scripts/09-generate-app-secrets.sh`, seal it, and point the
  chart's `existingSecret`-style field at it explicitly — never leave an
  "auto-generate" default active for anything ArgoCD renders.

**Every generated SealedSecret now lives in one folder,
`gitops/sealed-secrets/`, not next to the component it targets**
- See [`05-sealed-secrets.md`](05-sealed-secrets.md). Each file still sets
  its own `metadata.namespace`, so this is purely an organizational change —
  a new `sealed-secrets-data` Application (sync-wave `-4`) syncs the whole
  folder. `cert-manager-config` moved from wave `-4` to `-3` to stay after
  it (originally so its ClusterIssuers could reference a secret sealed
  there — moot now that cert-manager's DNS-01 setup was removed entirely,
  see the section below, but the wave ordering was kept since there's no
  reason to move it back).

## Moved to LAN-only access: internal CA, `.lan`, no more public DNS (2026-09)

This project originally used `smartmansion.de` + Let's Encrypt (via a
deSEC.io DNS-01 delegation, since Strato has no ACME API) + a DynDNS updater
keeping the A records pointed at a changing public IP — all of that existed
purely to get a publicly-trusted certificate for a domain reachable from the
internet. Once the access model settled on "LAN/VPN only, never actually
reachable from the internet," none of it was still earning its complexity,
so it was removed outright:

- **Removed entirely**: the `dyndns-updater` component (its own namespace,
  CronJob, and sealed credentials), the `cert-manager-webhook-desec`
  community webhook, the `letsencrypt-staging`/`letsencrypt-prod`
  ClusterIssuers, `DESEC_API_TOKEN`/`STRATO_DYNDNS_USER`/
  `STRATO_DYNDNS_PASSWORD` prompts from `scripts/09-generate-app-secrets.sh`
  (nothing in this project needs a manually-provided credential anymore —
  every secret is now auto-generated), and the whole "manually-provided
  credential" code path in that script (`prompt_if_missing`,
  `secrets-vault/manual-credentials.env`) since nothing used it once those
  three were gone.
- **Kept and promoted**: the `smartmansion-internal` self-signed
  ClusterIssuer already existed as a documented fallback — it's now the
  *only* ClusterIssuer. See [`09-cert-manager-dns.md`](09-cert-manager-dns.md).
- **New**: every domain is `*.lan` (`DOMAIN_NEXTCLOUD` etc. in
  `config/cluster.env`), resolved via a plain Windows hosts-file entry
  (`scripts/11-configure-hosts.sh`, needs an Administrator shell) rather
  than any DNS server at all.
- **New, to make `*.lan` actually reachable on real ports (80/443, not a
  NodePort)**: Cilium's L2 announcement + LB-IPAM features are now enabled
  (`gitops/infrastructure/cilium/values.yaml`), with a
  `CiliumLoadBalancerIPPool` (one IP, `INGRESS_VIP`) and a
  `CiliumL2AnnouncementPolicy` (`gitops/infrastructure/cilium/manifests/`)
  giving the Ingress Controller's Service a real, ARP-announced LAN IP.
  Without this, a bare-metal `LoadBalancer`-type Service just sits at
  `EXTERNAL-IP=<pending>` forever — there's no cloud provider here to
  allocate one.
- **`.localhost` (the first attempt) was tried and confirmed broken, not
  just theoretically risky**: it's an RFC 6761 reserved TLD, and on this
  exact setup both curl and Windows' own resolver hardcoded it to
  `127.0.0.1`/`::1` *before the hosts file was ever consulted* — a correct
  hosts-file entry pointing `homeassistant.localhost` at `INGRESS_VIP` was
  silently ignored, every connection refused. Switched to `.lan`, which
  carries no such reservation — see
  [`09-cert-manager-dns.md`](09-cert-manager-dns.md) for how to verify a
  domain actually resolves where you think it does (`curl -kv`, never
  `curl --resolve` — that flag masks exactly this failure) and how to swap
  to yet another suffix if `.lan` ever causes trouble on a specific network.

## SealedSecrets

**`scripts/05-install-sealed-secrets.sh` fails with `Error: no repositories
found matching 'sealed-secrets'. Nothing will be updated`**
- Fixed: the chart repo moved from `bitnami-labs.github.io/sealed-secrets`
  to `bitnami.github.io/sealed-secrets` (org rename) — the old URL now
  404s. `helm repo add` for the old URL was silently failing (masked by a
  `|| true` that every `helm repo add` in this repo used to have — see the
  general note below), so the real error only ever surfaced later, confusingly,
  at the `helm repo update` step. Both `scripts/05-install-sealed-secrets.sh`
  and `gitops/infrastructure/sealed-secrets/application.yaml` now point at
  the correct URL.
- General fix applied to every Helm-based `scripts/0N-install-*.sh` (Cilium,
  SealedSecrets, cert-manager, ArgoCD): `helm repo add ... ||
  true` silently swallowed genuine failures (network issues, moved/dead
  URLs), which only ever surfaced later as a confusing unrelated error one
  or two commands downstream. Replaced with `helm repo add ...
  --force-update` — idempotent for re-running with the same name (what
  `|| true` was actually there for), but a real failure now fails loudly
  and immediately, at the command that's actually broken.

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
