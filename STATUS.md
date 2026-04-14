# OpenShellBF Status

Last updated: 2026-04-14
Updated by: operator + codex
Session 2 commit: e8f43b15 (OpenShell codex/bluefield-probe)
Session 2 commit: f64c3479 (OpenShell codex/bluefield-probe, vf-bridge)
Session 3: end-to-end validation (no new code commits — all testing)
Session 4: kernel rebuild (CONFIG_POSIX_MQUEUE), full gateway boot achieved
Session 5: operational scripts, policies, E2E tests (8/8), exec access, packet lifecycle docs
Session 6: DPU managed-proxy MVP control plane + launch/debugging

## Current focus

- **REVISED BF3 MVP**: keep the host-side sandbox as `openshell-vm`, keep `eth1` as protected egress, and move first implementation effort to a guest-facing DPU proxy in TCP mode.
- **Comm Channel deprioritized**: host is untrusted and should not act as the DPU control-plane transport. OOB or another DPU-owned path is the control plane; guest `eth1` is the protected data plane.
- **Policy semantics remain per sandbox**: the DPU runtime should preserve OpenShell's per-sandbox policy model even if process topology differs.
- **Transparent NAT/CT work is closed**: OVS CT/NAT and Linux netfilter NAT on the BF3 protected path are treated as dead ends for this design.
- **Next implementation slice**: DPU control agent that pulls sandbox policy and provider env from OpenShell over a DPU-owned path, compiles local OPA input, and feeds the existing `openshell-dpu-proxy` TCP mode.

## 2026-04-14 DPU managed-proxy MVP progress

### Saved code state

- `OpenShell` clean worktree / branch: `dpu-managed-proxy-mvp`
  - commit `6a089147` — add DPU control-agent MVP
  - commit `01d8db6d` — stub comch when wrapper sources are absent
  - commit `cbfb0e4a` — allow TLS server-name override for DPU agent
- `OpenShellBF`
  - commit `25bed96` — wire DPU managed-proxy MVP bringup
  - commit `c33eb8b` — avoid self-matching DPU proxy wrappers
  - commit `16105aa` — reliably stop stale DPU proxy listeners

### What works

- Host-side `openshell-vm` protected path remains the correct base:
  - sandbox guest reaches `10.99.2.1:3128` over `eth1`
  - DPU protected IP is on `enp3s0f0s0`
  - OVS proxy steering flows exist on `ovsbr1`
- DPU control plane now works:
  - `openshell-dpu-agent --oneshot` succeeds against OpenShell gRPC
  - per-sandbox runtime state is generated under `/home/ubuntu/openshell-dpu/<sandbox-id>/`
  - current confirmed sandbox id:
    - `1ad033b9-1532-42d5-b873-d5ddedda9b39`
- TLS hostname mismatch to the gateway was addressed by adding:
  - `OPENSHELL_TLS_SERVER_NAME`
  - current working override: `localhost`
- DPU OPA starts successfully on `127.0.0.1:8181`

### Latest concrete blocker

- `openshell-dpu-proxy` startup reached the bind step and failed with:
  - `Address already in use (os error 98)`
- Root cause narrowed to stale proxy listeners and wrapper lifecycle issues:
  - earlier wrappers could self-match/kill or fail to clear old listeners
  - wrappers were patched in `OpenShellBF`, but final validation after the stale-listener fix was not completed before session end

### Resume checklist

1. On `lenny1`, pull latest `OpenShellBF`.
2. On the DPU, ensure `~/work/OpenShell` is on branch `dpu-managed-proxy-mvp` and includes commit `cbfb0e4a`.
3. Rebuild on the DPU:
   - `/home/ubuntu/.cargo/bin/cargo build --release -p openshell-sandbox --bin openshell-dpu-agent --bin openshell-dpu-proxy`
4. Stop and restart the DPU proxy stack from `OpenShellBF` using:
   - `--endpoint https://192.168.100.1:30051`
   - `--tls-server-name localhost`
5. Immediately inspect:
   - `./scripts/check-dpu-managed-proxy-mvp.sh --host bf-dpu --sandbox-id 1ad033b9-1532-42d5-b873-d5ddedda9b39`
6. If listener exists on `10.99.2.1:3128`, retest from sandbox:
   - `unset https_proxy http_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY`
   - `curl -skv --proxy http://10.99.2.1:3128 https://example.com/`

### Important operator notes

- Always use the correct gateway context when working with the sandbox:
  - `openshell gateway select openshell-vm-default`
- The DPU startup wrappers are host-side scripts and should be run from `lenny1`, not from the DPU shell.
- The OpenShell main worktree still has an unrelated user dirty file:
  - `crates/openshell-vm/src/health.rs`
  - do not overwrite it; continue using the clean worktree at `/home/ubuntu/work/OpenShell-dpu-mvp`

## 2026-04-14 design reset and MVP

### New target architecture

- Host remains **untrusted** and does not push policy, secrets, or runtime control directly into DPU services.
- Protected sandboxes keep a dedicated `eth1` path backed by a VF.
- `managed_proxy` starts as a **per-sandbox DPU proxy isolation unit** (container first, DPU VM later if needed).
- `direct` becomes a later **shared DPU-native lane**, likely DOCA Flow based.
- DPU control plane is **DPU-owned**, with OOB as the current MVP assumption.

Supporting artifacts:

- `docs/dpu-vf-isolated-architecture.md`
- `docs/vf-isolated-dpu-architecture.png`
- `scripts/reset-dpu-pf1-experiments.sh`

### MVP decisions

1. Keep `openshell-vm` on the host; do **not** move the workload into a DPU VM.
2. Start with `openshell-dpu-proxy --mode tcp` bound on the protected DPU-side IP (guest-facing).
3. Do **not** use Comm Channel for the MVP.
4. Land policy on the DPU via a new DPU control-agent that:
   - pulls `GetSandboxConfig`
   - pulls `GetSandboxProviderEnvironment`
   - writes DPU-local OPA policy/data and credentials files
   - reports policy load status back to OpenShell
5. Treat `direct` mode as a later track after the managed proxy path works.

### Network/admin state to preserve

- `oob_net0` is healthy on the DPU, but PF1 currently has a lower-metric default route. If OOB-only control plane is required, normalize routing before more dataplane experiments.
- PF1 NAT experiment cleanup script exists and restores a mostly clean baseline without touching PF0/`ovsbr1`.

### Implementation order

1. Save architecture and cleanup tooling in `OpenShellBF`.
2. Implement `openshell-dpu-agent` in `OpenShell`.
3. Generate DPU-local runtime files for the existing TCP proxy.
4. Add DPU-side service/container wiring after the agent compiles and writes correct state.
5. Use host-side DPU wrappers for startup/teardown:
   - `scripts/start-dpu-managed-proxy-mvp.sh`
   - `scripts/stop-dpu-managed-proxy-mvp.sh`

## Session 5 deliverables (2026-04-13)

### Operational scripts (`scripts/`)
| Script | Purpose |
|--------|---------|
| `common.sh` | Shared constants, logging, helpers (kill_stale, tcp_probe, etc.) |
| `start-vf-bridge.sh` | Creates SR-IOV VF, launches vf-bridge (AF_PACKET on host VF) |
| `start-microvm.sh` | Clean boot of openshell-vm with cert sync + optional vf-bridge |
| `create-sandbox.sh` | Policy-based sandbox creation (runs as ubuntu, verifies mTLS) |
| `e2e-test.sh` | 8 automated tests across 4 policy tiers |

### Sandbox policies (`policies/`)
| Policy | What it enforces |
|--------|-----------------|
| `lockdown.yaml` | Zero network access — default deny blocks all outbound |
| `web-readonly.yaml` | GET-only to PyPI/GitHub/npm, blocks POST, blocks non-listed hosts |
| `api-allow.yaml` | L4 allow to Anthropic/OpenAI/HuggingFace APIs + PyPI for SDK installs |
| `dpu-enforced.yaml` | Broad L4 allow (trust delegation) — DPU OVS does real enforcement |

### E2E test results (8/8 PASS)
```
PASS  lockdown-curl          (curl blocked)
PASS  lockdown-dns           (DNS resolution blocked)
PASS  web-ro-pip-dryrun      (pip install --dry-run allowed)
PASS  web-ro-post-blocked    (POST to pypi.org blocked)
PASS  web-ro-other-blocked   (curl to httpbin.org blocked)
PASS  api-anthropic-reachable (curl to api.anthropic.com succeeds)
PASS  api-other-blocked      (curl to example.com blocked)
PASS  dpu-pass-curl          (curl to api.anthropic.com via DPU-trust policy)
```

### Documentation (`docs/`)
- `packet-lifecycle.md` — "A Day in the Life of a Packet" teaching guide
- `packet-lifecycle.mmd` — Mermaid flowchart source
- `packet-lifecycle.png` — Rendered Graphviz diagram (541 KB)
- `render-diagram.py` — Graphviz DOT renderer script

### Key findings
- Binary path resolution: OPA checks resolved exe path via `/proc/PID/exe`. Sandbox uses uv-managed Python at `/sandbox/.uv/python/cpython-3.13.12-linux-x86_64-gnu/bin/python3.13`.
- Cannot use iptables MARK in libkrun kernel (xt_MARK revision 2 fails). Policy routing with `ip rule` is the path forward.
- VM exec works via vsock port 10777 (requires version symlink workaround for debug binary).

## Snapshot

- Source of truth: `docs/unified-spec.md`
- Runtime direction: microVM-first
- Open question resolved: DPU is already in switchdev mode with OVS bridges configured. VF representors will appear on DPU when VFs are created from the host. The architecture for the first proof slice is confirmed viable.

## DPU network map (fully verified 2026-04-11)

```
Physical wire 0 (p0 / enp3s0f0np0)
    └── ovsbr1 (OVS bridge, policy flows active)
            ├── p0           — physical uplink (wire)
            ├── pf0hpf       — host PF0 representor (all enp179s0f0np0 traffic)
            ├── en3f0pf0sf0  — SF0 OVS-side representor (gateway attach point)
            └── [pf0vf0]     — VF0 representor, NOT yet added to bridge

Physical wire 1 (p1 / enp3s0f1np1)
    └── ovsbr2 (OVS bridge)
            ├── p1           — physical uplink (wire)
            ├── pf1hpf       — host PF1 representor
            └── en3f1pf1sf0  — SF1 OVS-side representor

DPU process attachment (not in OVS):
    enp3s0f0s0  — SF0 application netdev (bind here to send/receive via ovsbr1)
    enp3s0f1s0  — SF1 application netdev
```

Active OVS policy flows on ovsbr1 (already enforcing today):
```
priority=200  ip  in_port=pf0hpf  nw_dst=45.54.28.15         → DROP
priority=100  tcp in_port=pf0hpf  nw_dst=140.82.116.6 tp=443 → output:p0 (allow)
priority=0                                                     → NORMAL
```

VF0 representor: `pf0vf0` appeared on DPU immediately after host wrote sriov_numvfs=1.
Next: add `pf0vf0` to `ovsbr1`, then all microVM eth1 traffic becomes DPU-policy-governed.

## Latest findings

- Upstream OpenShell already has an experimental `openshell-vm` runtime built on `libkrun`.
- The current VM path appears centered on `gvproxy` / `virtio-net`.
- The missing MVP piece is the BlueField SR-IOV protected-egress path.

## Immediate next steps

### Step 1 — wire VF0 representor into OVS (on DPU, minutes)
```bash
# Assign MAC to VF on host first:
sudo ip link set enp179s0f0v0 address 52:54:00:aa:bb:cc

# On DPU — add VF0 representor to bridge and add default-drop for VF traffic:
sudo ovs-vsctl add-port ovsbr1 pf0vf0
sudo ovs-ofctl add-flow ovsbr1 "priority=50,in_port=pf0vf0,actions=drop"
# Verify DPU blocks VF traffic; add allow rule for one destination to test enforcement
```

### Step 2 — prove DPU enforcement on VF (host, minutes)
```bash
# Bring up the VF and send traffic; it should be blocked by the DPU drop flow
sudo ip link set enp179s0f0v0 up
# ping or curl from the VF netdev context; expect drop
# Add allow rule on DPU; expect traffic to pass — proves the enforcement point works
```

### Step 3 — implement openshell-vm dual-NIC (code, ~/work/OpenShell)
Files to change (all in `crates/openshell-vm/`):
1. `src/lib.rs` — add `protected_egress: Option<ProtectedEgressConfig>` to `VmConfig`; second `krun_add_net_unixstream` call in `launch()`
2. `src/main.rs` — `--protected-egress-socket <path>` CLI flag
3. `scripts/openshell-vm-init.sh` — eth1 static bring-up (no default route)
Host wiring: TAP device bridged to `enp179s0f0v0` (host VF), connected to libkrun via unix socket

### Step 4 — boot test and end-to-end proof
- Launch microVM with eth1 wired to VF; tcpdump on DPU `pf0vf0` to confirm visibility
- Add OVS allow rule for one destination; verify VM can reach it; verify DPU drops the rest
- This proves the first slice: one microVM, DPU-enforced protected-egress, observable enforcement point

### Step 5 — scaffold dpu/ code in ~/work/OpenShell
- `dpu/control-agent/`: policy fetch loop, compiled policy cache, TTL logic
- `dpu/egress-gateway/`: bind to `enp3s0f0s0`, evaluate compiled policy, emit audit

## Blockers and risks

- **eSwitch management is DPU-side only** (verified). Host `devlink` returns EOPNOTSUPP. All BF3 eSwitch and OVS work is done via `ssh ubuntu@192.168.100.2` (rshim only). This is by design and reinforces the trust boundary.
- **eSwitch is already switchdev** — no mode switch needed (blocker resolved).
- **OVS already configured** — both bridges in place with uplinks and SF ports (blocker resolved).
- **Remaining blocker**: VF creation from the host has not been attempted. `echo 1 > /sys/bus/pci/devices/0000:b3:00.0/sriov_numvfs` needs operator approval (reversible: `echo 0` removes VFs, but beware of VF-in-use guard).
- **Remaining blocker**: openshell-vm has no `eth1` / protected-egress path yet. Code changes required in 3 files (identified above).
- **Remaining soft blocker**: ubuntu not in kvm group on host (usermod run but re-login needed). Can use `sudo` for initial VF experiments.
- Direct VF passthrough into libkrun not available. Near-term path: host VF netdev → macvtap or TAP → second `krun_add_net_unixstream` call in openshell-vm. Alternatively, expose the VF via the host side and connect through OVS to the DPU bridge directly.

## Working notes

- Update this file at least when:
  - a new hardware fact is verified,
  - a blocker is discovered,
  - an implementation decision changes,
  - or a new next step is chosen.
- Prefer short dated entries below instead of rewriting history.

### Log

- 2026-04-12 07:00–08:20 UTC SESSION 4 (operator + claude — kernel rebuild + full gateway boot)
  - GOAL: Rebuild libkrunfw with CONFIG_POSIX_MQUEUE=y and achieve full gateway boot.
  - KERNEL REBUILD — Built libkrunfw from source using `tasks/scripts/vm/build-libkrun.sh`. Pinned to commit `463f717bbdd916e1352a025b6fb2456e882b0b39`. Three-phase build: kernel source prep → merge openshell.kconfig fragment → full kernel + libkrunfw.so.5 (21MB) + libkrun.so (6.4MB). Verified `CONFIG_POSIX_MQUEUE=y` in the built `.config`.
  - RUNTIME REPACK — Ran `compress-vm-runtime.sh` producing 19MB compressed artifacts (libkrunfw.so.5.zst, libkrun.so.zst, gvproxy.zst). Downloaded gvproxy v0.8.8 for linux-amd64.
  - BINARY REBUILD — `OPENSHELL_VM_RUNTIME_COMPRESSED_DIR=target/vm-runtime-compressed cargo build -p openshell-vm`. Embedded: libkrun.so.zst (2.0MB), libkrunfw.so.5.zst (6.5MB), gvproxy.zst (3.9MB). Rootfs not embedded (built separately).
  - MQUEUE FIX CONFIRMED — First boot showed zero mqueue errors. All k3s pods (coredns, agent-sandbox-controller, local-path-provisioner, helm-install-openshell, openshell-0) reached Running state. This was the blocker from session 3.
  - HEALTH CHECK TIMEOUT — Original 90s timeout too short (openshell-0 started at T+53s, gateway needs ~40s more to init). Increased to 180s in `health.rs`.
  - STALE KUBELET STATE BUG — Found and fixed: `/var/lib/kubelet/pods` lives on virtio-fs rootfs (not state disk). When state disk is reformatted, stale kubelet pod dirs cause cascading mkdir failures. Added cleanup to `openshell-vm-init.sh`: `rm -rf /var/lib/kubelet/pods /var/log/pods /var/log/containers`.
  - STALE MTLS CERTS BUG — Found and fixed: `is_warm_boot()` found stale mTLS certs under `/root/.config/openshell/gateways/openshell-vm-default/` from a previous boot. New PKI generated on state disk didn't match. Fix: delete stale gateway config before cold boot.
  - FULL GATEWAY BOOT — `Gateway healthy [48.2s]`, `Ready [54.4s total]`. All pods running, gRPC health check passed with proper mTLS.
  - BUILD NOTES: `libclang-dev` needed for libkrun build (clang-sys crate). Set `LIBCLANG_PATH=/usr/lib/llvm-18/lib` if auto-detection fails.
  - FILES CHANGED:
    - `crates/openshell-vm/src/health.rs` — timeout 90s → 180s
    - `rootfs/srv/openshell-vm-init.sh` — added kubelet state cleanup (runtime patch, not committed)
  - STATUS: Full OpenShell gateway running in microVM. Ready for sandbox creation test.

- 2026-04-12 05:00–06:10 UTC SESSION 3 (operator + claude — end-to-end validation)
  - GOAL: Step-by-step testing of all code produced in sessions 1–2.
  - VERIFIED — VF and DPU state persisted across sessions. `sriov_numvfs=1`, `enp179s0f0v0` UP with MAC `52:54:00:aa:bb:cc`, `pf0vf0` in `ovsbr1` with drop flow active. Drop counter at 2674 packets (up from 1500 in session 2).
  - VERIFIED — vf-bridge runtime works. `AF_PACKET` bound successfully to `tap-vftest` (TAP device test) and to `enp179s0f0v0` (real BF3 VF). Previous blocker (CAP_NET_RAW) resolved with sudo.
  - VERIFIED — openshell-vm built with embedded runtime. Downloaded pre-built `libkrun.so`, `libkrunfw.so.5`, and `gvproxy` from GitHub release `vm-dev`, zstd-compressed, and rebuilt `openshell-vm` with `OPENSHELL_VM_RUNTIME_COMPRESSED_DIR`. Rootfs built with `build-rootfs.sh --base` (required `DOCKER_CONFIG` and `PATH` passthrough for sudo, and NGC auth for `nvcr.io`).
  - VERIFIED — microVM boots with dual NICs. Console output shows `eth0` (gvproxy, MAC `5a:94:ef:e4:0c:ee`) and `eth1` (protected-egress, MAC `52:54:00:bf:00:01`). eth1 brought UP with `10.99.2.2/24` by init script. No default route on eth1 (correct).
  - VERIFIED — vf-bridge packet relay works bidirectionally. Stats from one session: 96 frames guest→host (4408 B), 7 frames host→guest (2070 B). 42-byte frames are ARP from guest.
  - VERIFIED — DPU sees VM eth1 traffic. `tcpdump -i pf0vf0` on DPU shows: `ARP, Request who-has 10.99.2.1 tell 10.99.2.2` (from guest eth1), DHCP requests, IPv6 multicast. Drop flow counter incremented from 2674 → 2786 → 2914 → 3144 across test iterations.
  - PROVEN — DPU selective enforcement on VM traffic:
    - Added `priority=100,udp,in_port=pf0vf0,nw_dst=8.8.8.8,actions=output:p0` on DPU.
    - VM sent 5 UDP packets to 8.8.8.8 (allowed) and 5 to 1.1.1.1 (denied).
    - DPU flow: `nw_dst=8.8.8.8` → `n_packets=5, n_bytes=292` (ALLOWED, forwarded to wire).
    - DPU flow: `priority=50,in_port=pf0vf0,actions=drop` → counter incremented (1.1.1.1 packets DENIED).
    - `tcpdump` confirmed: `10.99.2.2.37652 > 8.8.8.8.53` visible at pf0vf0, `10.99.2.2.33534 > 1.1.1.1.53` also visible but dropped by OVS.
    - Required static ARP entries in guest (`ip neigh add ... lladdr 52:54:00:aa:bb:cc`) to resolve L2 addresses for external IPs without a gateway.
  - ISSUES ENCOUNTERED:
    - First VM boot failed with `ECONNREFUSED` on eth1 backend — stale UNIX socket from killed vf-bridge. Fix: always `rm -f` socket before starting vf-bridge.
    - `openshell-vm exec` does not work with `--rootfs` flag — VM state file not written to expected path. Not a blocker (used init scripts + console log instead).
    - SSH into VM not available (base rootfs has no sshd). Used `--exec` with test scripts and read console log.
    - NGC auth failure when building rootfs — `sudo` doesn't inherit Docker credentials. Fix: `sudo DOCKER_CONFIG=/home/ubuntu/.docker`.
    - DOCA CC compilation failure in sandbox supervisor build — not needed for dual-NIC test, rootfs usable without supervisor.
  - STATUS: Phase 2 is COMPLETE and PROVEN. The first proof slice works: one microVM, DPU-enforced protected-egress, selective allow/deny, observable enforcement point.
  - BLOCKER FOUND — full OpenShell gateway (k3s + sandboxes) cannot start: VM kernel lacks `CONFIG_POSIX_MQUEUE`. runc needs mqueue mount at `/dev/mqueue` for container init. This affects both custom and pre-built release binaries. Fix committed to `openshell.kconfig` (commit `832994c3`) but requires libkrunfw kernel rebuild.
  - ALSO FOUND — gvproxy crashes after ~90s when k3s pods fail repeatedly. Root cause: VM kernel mqueue → runc fails → no pods → gvproxy socket EOF.

- 2026-04-11 19:18 UTC RESUME (agent session 2)
  - Commands: `ip link show enp179s0f0v0`; `cat /sys/bus/pci/devices/0000:b3:00.0/sriov_numvfs`; `ssh ubuntu@192.168.100.2 sudo ovs-vsctl show`; `ssh ubuntu@192.168.100.2 sudo ovs-ofctl dump-flows ovsbr1`; `ip addr show enp179s0f0v0`; `ssh ubuntu@192.168.100.2 ip -s link show pf0vf0`.
  - VERIFIED — VF persisted through sleep: `enp179s0f0v0` UP, MAC `52:54:00:aa:bb:cc`, IP `10.99.1.1/24`, sriov_numvfs=1.
  - VERIFIED — DPU enforcement is PROVEN. The drop flow on `pf0vf0` shows `n_packets=1500, idle_age=21` — 1500 packets from the host VF were counted and dropped by the DPU. This is not theoretical. The DPU observed, acted on, and counted real traffic.
  - VERIFIED — `pf0vf0` representor RX stats: 1501 packets received (DPU saw them). TX: 2987 packets (normal ARP/DHCP from bridge). The slight mismatch is consistent with the ICMP allow rule below.
  - VERIFIED — Operator added ICMP allow flow during previous session: `priority=100,icmp,in_port=pf0vf0 actions=output:p0` (idle_age=43997s, not recently used). This confirms the allow-rule mechanism works.
  - VERIFIED — `pf0vf0` altname: `enp3s0f0nc1pf0vf0` (nc1 = controller 1 = host side, pf0vf0 = PF0 VF0).
  - VERIFIED — devlink shows `hw_addr 00:00:00:00:00:00` for VF function — this is the hardware-assigned MAC as seen from devlink. The actual VF netdev MAC on the host is `52:54:00:aa:bb:cc` (set via `ip link`). These are independent; the DPU representor uses its own MAC for ARP/L2.
  - STATUS: Phase 0 (hardware validation) and Phase 1 (DPU enforcement proof) are complete. Moving to implementation planning and Phase 2 (openshell-vm dual NIC).
  - NEXT: Implementation plan updated at `docs/implementation-plan.md`. See that doc for phased execution plan.

- 2026-04-11 06:33:43 UTC HANDSHAKE
  - Agent online on host `lenny1`.
  - Date/time: 2026-04-11 06:33:43 UTC.
  - Machine type: host x86_64 (`uname -m` = `x86_64`, kernel 6.8.0-107-generic). Not DPU ARM.
  - Tooling present in PATH: `devlink` (/usr/sbin/devlink), `mlxconfig` (/usr/bin/mlxconfig), `lspci` (/usr/bin/lspci), `ovs-vsctl` (/usr/bin/ovs-vsctl), `ip` (/usr/sbin/ip). All five confirmed present.
  - Code investigation and any code changes will happen in `/home/ubuntu/work/OpenShell` on branch `codex/bluefield-probe`.
  - Remote for OpenShell: SSH only (`git@github.com:AshBrainwave/OpenShell.git`); no writable HTTPS remote detected.
  - Next path to investigate: hardware SR-IOV readiness (BF3 eSwitch mode, VF count, IOMMU) and openshell-vm second-NIC feasibility.
  - All docs read: unified-spec.md, design-spec.md, implementation-plan.md, bluefield-codex-handoff.txt.

- 2026-04-11 07:xx UTC OVS-VF-WIRED (operator-verified on DPU)
  - Commands: `sudo ovs-vsctl add-port ovsbr1 pf0vf0`; `sudo ovs-ofctl add-flow ovsbr1 "priority=50,in_port=pf0vf0,actions=drop"`; `sudo ovs-vsctl show`; `sudo ovs-ofctl dump-flows ovsbr1`.
  - VERIFIED — `pf0vf0` is now a port in `ovsbr1` (confirmed in `ovs-vsctl show`).
  - VERIFIED — Drop flow installed and confirmed: `priority=50,in_port=pf0vf0 actions=drop`, duration=147s, n_packets=0 (no traffic sent through VF yet — expected, VF still DOWN on host).
  - VERIFIED — All four flows now in ovsbr1: priority-200 drop to 45.54.28.15; priority-100 allow tcp/443 to 140.82.116.6; priority-50 drop from pf0vf0; priority-0 NORMAL default.
  - STATUS: DPU enforcement point for VF0 is wired and ready. The moment the host VF sends traffic, the DPU will count and drop it.
  - PENDING: host-side verification (assign MAC+IP to enp179s0f0v0, ping through VF, confirm n_packets increments on DPU drop rule). Not yet run — paused here.

- 2026-04-11 07:xx UTC VF-CREATION-AND-DPU-PROBE-DEEP (operator-verified)
  - Commands on DPU: `ip link show`; `sudo ovs-ofctl dump-flows ovsbr1`; `devlink port show` (after VF creation).
  - Commands on host: `echo 1 | sudo tee /sys/bus/pci/devices/0000:b3:00.0/sriov_numvfs`; `ip link show | grep -i enp179`.
  - VERIFIED — VF creation: `sriov_numvfs=1` on host succeeded instantly. Host gained `enp179s0f0v0` (DOWN, no MAC). DPU gained representor `pf0vf0` (pcivf, controller 1, pfnum 0, vfnum 0, external true, hw_addr 00:00:00:00:00:00).
  - VERIFIED — `pf0vf0` has all-zero MAC because no MAC has been set on the VF. Must assign one before use: `sudo ip link set enp179s0f0v0 address <mac>` on host, OR `devlink port function set pci/0000:03:00.0/196609 hw_addr <mac>` from DPU.
  - VERIFIED — SF netdev architecture explained:
    - `en3f0pf0sf0` (iface 8, master ovs-system) — OVS representor for SF0; used for TC/OVS steering rules.
    - `enp3s0f0s0` (iface 9, NO master) — SF0 application netdev; a DPU process binds to this interface to send/receive traffic through the SF path in ovsbr1.
    - These are two views of the same SF: representor (for the switch) and application netdev (for the process). This is the DOCA SF model.
  - VERIFIED — DPU `oob_net0` is present (iface 3, UP) — out-of-band management port on the DPU, MAC `48:b0:2d:a6:21:ba`. Separate from rshim.
  - VERIFIED — `p0` and `p1` physical uplink altnames are `enp3s0f0np0` and `enp3s0f1np1` respectively. All bridge ports confirmed UP.
  - VERIFIED — OVS flow rules on ovsbr1 are active and non-trivial (pre-existing from earlier operator work):
    - Rule 1 (priority 200): DROP all IP traffic from `pf0hpf` (host PF0) to `45.54.28.15`. This is an IP-level block for a specific destination.
    - Rule 2 (priority 100): ALLOW TCP/443 from `pf0hpf` to `140.82.116.6` (a GitHub IP), forwarding to `p0` (wire).
    - Rule 3 (priority 0): NORMAL — standard L2 forwarding for everything else.
    - IMPLICATION: DPU is ALREADY enforcing outbound policy on host PF0 traffic today via OVS flows. The enforcement mechanism is proven and working. n_packets=49946 on the default rule confirms real traffic is flowing through ovsbr1.
  - INFERENCE — The same OVS flow mechanism is exactly what we need for sandbox VF enforcement. Replace `in_port=pf0hpf` with `in_port=pf0vf0` and the DPU enforces policy per-sandbox (per-VF).
  - INFERENCE — DPU gateway process should bind to `enp3s0f0s0` for L7-aware decisions (SNI, Host header), then emit verdict back via OVS TC rule or by reinjecting to p0. For L4-only rules, pure OVS flows on `pf0vf0` suffice without a userspace process.
  - NEXT HARDWARE STEPS: (1) assign MAC to `enp179s0f0v0` on host; (2) `sudo ovs-vsctl add-port ovsbr1 pf0vf0` on DPU; (3) add a default-drop flow for `in_port=pf0vf0`; (4) test host-side VF connectivity is blocked; (5) add selective allow and confirm DPU enforcement.
  - NEXT CODE STEPS: implement dual-NIC in openshell-vm (3 files identified); wire eth1 to host-side bridge over VF.

- 2026-04-11 07:xx UTC DPU-PROBE (operator-verified at DPU terminal via rshim)
  - Commands run on DPU (ubuntu@localhost = 192.168.100.2): `lspci -nn | grep -i mellanox`; `devlink dev eswitch show pci/0000:03:00.0`; `devlink port show`; `ovs-vsctl show`; `sudo ovs-vsctl show`; `sudo devlink dev eswitch show pci/0000:03:00.0`.
  - VERIFIED — DPU-side PCI address for BF3 ConnectX-7: `0000:03:00.0` (PF0), `0000:03:00.1` (PF1). Matches host-side `0000:b3:00.0/1` as expected.
  - VERIFIED — eSwitch mode on DPU: `pci/0000:03:00.0: mode switchdev inline-mode none encap-mode basic`. Already in switchdev mode. No mode switch needed.
  - VERIFIED — DPU devlink port map (all confirmed netdevs):
    - `pf0hpf` — host PF0 representor (pcipf, controller 1 = host/x86, external true, MAC 48:b0:2d:a6:21:a6). Represents all host-PF0 traffic on DPU.
    - `en3f0pf0sf0` — DPU-local scalable function SF0 on PF0 (pcisf, controller 0 = DPU ARM, state active/attached). This is the DPU process attachment point.
    - `p0` — physical uplink port 0 (the wire).
    - `pf1hpf` — host PF1 representor (pcipf, controller 1, external true, MAC 48:b0:2d:a6:21:a7).
    - `en3f1pf1sf0` — DPU-local SF0 on PF1 (pcisf, controller 0, state active/attached).
    - `p1` — physical uplink port 1 (the wire).
    - `enp3s0f0s0` — virtual flavour, auxiliary/mlx5_core.eth.2. Likely a second SF or VF representor already instantiated. Needs investigation.
    - `enp3s0f1s0` — virtual flavour, auxiliary/mlx5_core.eth.3. Same.
  - VERIFIED — OVS 3.3.0040 is running on DPU. Two bridges pre-configured:
    - `ovsbr1`: ports `p0` (wire) + `pf0hpf` (host PF0 rep) + `en3f0pf0sf0` (DPU SF) + `ovsbr1` (internal). All host PF0 traffic is already bridged through the DPU.
    - `ovsbr2`: ports `p1` (wire) + `pf1hpf` (host PF1 rep) + `en3f1pf1sf0` (DPU SF) + `ovsbr2` (internal). Same for PF1.
  - INFERENCE — The OVS bridge setup means ALL current host traffic on `enp179s0f0np0` already transits through the DPU's `ovsbr1` bridge. The DPU is already on-path for existing host traffic. This is stronger than expected.
  - INFERENCE — When a VF is created from the host (echo 1 > /sys/bus/pci/devices/0000:b3:00.0/sriov_numvfs), a VF representor (e.g. `pf0vf0rep` or `enp179s0f0v0rep` style) will appear on the DPU. Adding it to `ovsbr1` gives the DPU a direct enforcement point for all VF traffic.
  - INFERENCE — `en3f0pf0sf0` is the natural attachment point for a DPU-side gateway process (e.g. a Rust binary listening on that netdev with nftables rules). Traffic from a sandbox VF → eSwitch → VF representor → ovsbr1 → SF0 netdev → gateway process → p0 (wire).
  - NOTE — `devlink dev eswitch show` without sudo returned EPERM on DPU. With sudo it works. DPU ubuntu user also lacks devlink privileges by default.
  - NOTE — `enp3s0f0s0` and `enp3s0f1s0` with flavour:virtual are not yet explained. Possibly pre-created SF representors or leftover VF representors from a prior experiment. Should check with `ip link show` and `ip addr` on DPU.

- 2026-04-11 07:xx UTC ESWITCH-ARCHITECTURE (operator-verified at terminal)
  - Commands run by operator: `sudo usermod -aG kvm ubuntu`; `sudo devlink dev eswitch show pci/0000:b3:00.0`.
  - VERIFIED — `sudo usermod -aG kvm ubuntu` succeeded. ubuntu is now in the kvm group (re-login or `newgrp kvm` required for the current shell to see it).
  - VERIFIED — `sudo devlink dev eswitch show pci/0000:b3:00.0` returns "kernel answers: Operation not supported".
  - INTERPRETATION: "Operation not supported" (EOPNOTSUPP) is not a permissions error. The kernel accepted the call but the BF3 integrated ConnectX-7 driver does not expose eSwitch management from the host x86 side. On BlueField-3, eSwitch control belongs to the DPU ARM OS, not the host. This is by design.
  - ARCHITECTURAL IMPLICATION: The host cannot set eSwitch mode, enumerate VF representors, or steer traffic on the BF3 eSwitch. All of that must be done from the DPU side via `ssh ubuntu@192.168.100.2` (rshim path only). This is consistent with BF3's separated-mode design where the DPU ARM owns the network control plane.
  - SECURITY NOTE: This is actually what we want — the trust boundary holds because the host cannot reach the eSwitch control plane. An adversarial host OS cannot disable DPU-side enforcement by misconfiguring the eSwitch.
  - NEXT ACTION: SSH into the DPU via rshim (`ssh ubuntu@192.168.100.2`) and run `devlink dev eswitch show` from there to determine current mode. The DPU's internal PCI address for the same device is typically `0000:03:00.0` or similar (must discover on DPU).

- 2026-04-11 06:33:43 UTC HARDWARE-PROBE-2 (full enumeration with correct tool access)
  - Commands: `lspci -nn | grep -i -E 'mellanox|nvidia|bluefield'`; `cat /sys/bus/pci/devices/*/sriov_{total,num}vfs`; `lsmod | grep -E 'vfio|kvm|iommu|mlx'`; `find /sys/kernel/iommu_groups -maxdepth 3 -type l | grep -E 'b3:00|31:00'`; `devlink dev show`; `ip link show`; `ip route`; `ip addr show tmfifo_net0`.
  - VERIFIED — PCI device map:
    - ConnectX-6 Dx (separate card, NOT BlueField): `0000:31:00.0` (`ens2f0np0`), `0000:31:00.1` (`ens2f1np1`)
    - BlueField-3 DPU integrated ConnectX-7: `0000:b3:00.0` (`enp179s0f0np0`), `0000:b3:00.1` (`enp179s0f1np1`)
    - BlueField-3 SoC Management Interface (rshim): `0000:b3:00.2`
    - BlueField-3 PCIe Bridge SoC: `0000:b1:00.0`, `0000:b2:00.0`, `0000:b2:02.0`, `0000:b4:00.0`, `0000:b5:00.0`
    - NVIDIA GA100 AX800 GPU: `0000:b6:00.0`
  - VERIFIED — SR-IOV capacity (sysfs readable without sudo):
    - `0000:b3:00.0` (BF3 PF0): `sriov_totalvfs`=16, `sriov_numvfs`=0 (no active VFs)
    - `0000:b3:00.1` (BF3 PF1): `sriov_totalvfs`=16, `sriov_numvfs`=0 (no active VFs)
    - `0000:31:00.0` (CX6 Dx PF0): `sriov_totalvfs`=8, `sriov_numvfs`=0
    - `0000:31:00.1` (CX6 Dx PF1): `sriov_totalvfs`=8, `sriov_numvfs`=0
  - VERIFIED — IOMMU groups (each PF is ALONE in its own group — ideal for VFIO passthrough):
    - `0000:31:00.0` → group 5 (alone)
    - `0000:31:00.1` → group 6 (alone)
    - `0000:b3:00.0` → group 19 (alone)
    - `0000:b3:00.1` → group 20 (alone)
    - `0000:b3:00.2` → group 21 (alone)
  - VERIFIED — VFIO/KVM modules all loaded: `vfio`, `vfio_pci`, `vfio_pci_core`, `vfio_iommu_type1`, `iommufd`, `kvm`, `kvm_intel`, `mlx5_core`, `mlx5_ib`, `mlx_compat`.
  - VERIFIED — `/dev/kvm` exists (crw-rw---- root kvm). User `ubuntu` is NOT in the `kvm` group (current groups: ubuntu,adm,cdrom,sudo,dip,plugdev,lxd,docker). KVM access requires either adding ubuntu to kvm group or using sudo; this is a soft blocker.
  - VERIFIED — rshim path active: `tmfifo_net0` UP at `192.168.100.1/24`. DPU management is reachable at `192.168.100.2` via rshim. SSH to DPU must go through rshim only.
  - VERIFIED — host-side BF3 NIC `enp179s0f0np0` has IP `172.31.255.20/24` (dedicated host↔DPU internal subnet).
  - VERIFIED — Default internet route is via `ens2f0np0` (ConnectX-6 Dx, not BF3). BF3 NICs carry a separate subnet.
  - VERIFIED — `devlink dev show` (runs without sudo) lists: `pci/0000:31:00.0`, `pci/0000:31:00.1`, `pci/0000:b3:00.0`, `pci/0000:b3:00.1` plus auxiliary mlx5 devices.
  - BLOCKED — `devlink dev eswitch show pci/0000:b3:00.0` returns "Operation not permitted" without sudo. eSwitch mode (legacy vs switchdev) is unknown from this session.
  - BLOCKED — `devlink port show` similarly requires elevated privileges; VF representors cannot be enumerated without sudo.
  - INFERENCE — Given IOMMU groups are already split (each PF alone), VF IOMMU isolation should be good once VFs are created, but must verify VF IOMMU grouping after first `echo 1 > sriov_numvfs`.

- 2026-04-11 06:33:43 UTC OPENSHELL-VM-PROBE-2 (deeper code analysis)
  - Files read: `src/lib.rs` (full), `src/ffi.rs` (full), `src/main.rs` (partial), `scripts/openshell-vm-init.sh` (partial).
  - VERIFIED — NetBackend enum has exactly three variants: `Tsi`, `None`, `Gvproxy { binary }`. No VF/VFIO variant exists.
  - VERIFIED — `VmConfig` struct has a single `net: NetBackend` field. There is no `eth1`, `second_nic`, or `protected_egress` field of any kind.
  - VERIFIED — Linux launch path: gvproxy started in QEMU SOCK_STREAM mode; `vm.add_net_unixstream(&net_sock, &mac, COMPAT_NET_FEATURES)` is called exactly once, producing guest `eth0`. The `krun_add_net_unixstream` symbol is loaded and used (not dead code in the launch path; the `#[allow(dead_code)]` tag on the struct field is historic).
  - VERIFIED — libkrun FFI bindings include `krun_add_net_unixstream` and (macOS-only) `krun_add_net_unixgram`. There is no `krun_add_pci_device`, `krun_add_vfio_device`, or equivalent symbol in `ffi.rs`. Direct VF-backed device assignment is not in the current libkrun API surface.
  - VERIFIED — `openshell-vm-init.sh` configures only `eth0` (gvproxy DHCP path) or `dummy0` (TSI path). There is no `eth1` branch.
  - INFERENCE — A second virtio-net `eth1` is structurally feasible by calling `krun_add_net_unixstream` a second time with a distinct socket path and a different MAC address. libkrun's virtio-net model supports multiple devices per context; this would produce guest `eth0` + `eth1`.
  - INFERENCE — The host side of `eth1` would still need a network backend. Options: (a) a second gvproxy instance bridged into the BF3 representor OVS path, (b) a TAP device on the host bridged into the BF3 eSwitch path, (c) direct VF passthrough via VFIO (requires new libkrun support or a different VM runtime).
  - INFERENCE — Option (b) TAP + OVS bridge is the most practical near-term pilot: create a TAP device, attach it to an OVS bridge that includes the BF3 representor, and connect it to `krun_add_net_unixstream` via gvisor's QEMU socket or a tun/tap fd. This keeps the traffic on a BF3-visible ingress path without requiring VF passthrough.
  - Exact files requiring modification for dual-NIC support:
    - `crates/openshell-vm/src/lib.rs`: add `protected_egress_net: Option<NetBackend>` (or equivalent) to `VmConfig`; extend `launch()` to call `krun_add_net_unixstream` a second time when present.
    - `crates/openshell-vm/src/main.rs`: add `--protected-egress-net` CLI flag and socket path argument.
    - `crates/openshell-vm/scripts/openshell-vm-init.sh`: add `eth1` bring-up logic (static IP, no default route; protected egress path should NOT carry a default route inside the guest).
    - Possibly `crates/openshell-vm/src/ffi.rs`: no changes needed unless a new libkrun symbol must be loaded.

- 2026-04-11 06:33:43 UTC SLICE-ASSESSMENT-2
  - Q: What is the current eSwitch mode? → UNKNOWN (requires sudo). Must verify next with operator access.
  - Q: How many VFs supported / enabled? → 16 supported, 0 enabled (verified). Safe to create 1 experimentally.
  - Q: Are VF representors present? → Cannot determine without eSwitch mode. In legacy mode, no representors. In switchdev mode, representors appear on host.
  - Q: Is VFIO / IOMMU ready? → Kernel modules all loaded. IOMMU groups are correctly split. Soft blocker: ubuntu not in kvm group.
  - Q: Can openshell-vm support a second NIC on Linux/KVM? → Yes, via a second `krun_add_net_unixstream` call with a distinct socket. Code changes are straightforward (3 files). VF-backed passthrough is not in current libkrun API.
  - Q: Can that second NIC be tied to a BF3 SR-IOV / representor path? → The cleanest MVP path is TAP + OVS bridge to a BF3 representor (avoids VF passthrough complexity, DPU still sees all traffic). Direct VF passthrough is cleaner for trust boundary but requires either extending libkrun or switching to QEMU/KubeVirt.
  - Q: Smallest end-to-end experiment? → (1) add ubuntu to kvm group; (2) check eSwitch mode with sudo; (3) if legacy, switch to switchdev on BF3 PF0; (4) echo 1 > sriov_numvfs on BF3 PF0; (5) create a TAP + OVS bridge to the new VF0 representor; (6) write a minimal second `krun_add_net_unixstream` call in openshell-vm; (7) boot a VM and confirm eth1 traffic appears on the BF3 representor side.
  - RECOMMENDATION: Pursue TAP/OVS path first (it is reversible, proves DPU-side visibility, and does not require libkrun changes beyond a second unixstream call). Once that works, evaluate whether VF direct passthrough is needed for the trust boundary claim; if so, KubeVirt/QEMU is the cleaner adapter than extending libkrun.
  - HARD BLOCKERS: (1) eSwitch mode unknown — if already switchdev, we can proceed directly; if legacy, a mode switch is needed (affects all traffic on that PF, must coordinate); (2) ubuntu not in kvm group (soft, easily fixed with sudo usermod).
  - SOFT BLOCKERS: No VF/VFIO path in libkrun; TAP/OVS is the near-term workaround.

- 2026-04-11 01:06:52 UTC PUSH-BLOCKER
  - Commands: `env GIT_CONFIG_NOSYSTEM=1 git -C /home/ubuntu/work/OpenShellBF push origin main`; `ssh -V`.
  - Finding: handshake commit `0a5384f` exists locally on `OpenShellBF/main`, but this environment cannot execute `/usr/bin/ssh` (`Permission denied`), so the SSH GitHub remote cannot be pushed from this session.
  - Impact: status updates can be committed locally, but not made externally visible until SSH execution is fixed or an HTTPS-authenticated push path is provided.
- 2026-04-11 01:06:52 UTC CODE-WORKSPACE
  - Commands: `env GIT_CONFIG_NOSYSTEM=1 git -C /home/ubuntu/work/OpenShell branch --show-current`; `env GIT_CONFIG_NOSYSTEM=1 git -C /home/ubuntu/work/OpenShell remote -v`; `env GIT_CONFIG_NOSYSTEM=1 git -C /home/ubuntu/work/OpenShell status --short`.
  - Finding: `OpenShell` is already on local branch `codex/bluefield-probe`, worktree is clean, and only SSH remote `origin git@github.com:AshBrainwave/OpenShell.git` is visible.
  - Finding: no separate writable fork remote was detected from this session.
- 2026-04-11 01:06:52 UTC HARDWARE-PROBE
  - Commands: `readlink -f /sys/class/net/*/device`; `readlink -f /sys/class/net/*/device/driver`; `test -e /sys/class/net/<if>/device/{sriov_totalvfs,sriov_numvfs,virtfn0}`; `ls -l /dev/kvm`; `id`.
  - Verified host-visible Mellanox PF candidates on `mlx5_core`: `0000:31:00.0` (`ens2f0np0`), `0000:31:00.1` (`ens2f1np1`), `0000:b3:00.0` (`enp179s0f0np0`), `0000:b3:00.1` (`enp179s0f1np1`).
  - Verified each of those four PF candidates has `sriov_totalvfs` and `sriov_numvfs` sysfs nodes present, which indicates SR-IOV capability is exposed at the driver/sysfs layer.
  - Verified no `virtfn0` symlink is present on those PF candidates, so no active host-visible VFs were found during this probe.
  - Verified `tmfifo_net0` is present on the host, which is consistent with BlueField/RShim tooling being present on this machine.
  - Verified `/dev/kvm` exists, but current user `ubuntu` is not in group `kvm` and cannot read or write `/dev/kvm` directly.
  - Blocked facts: exact VF counts, eSwitch mode, `devlink` port inventory, representor inventory, and IOMMU grouping could not be read from this session because `/usr/bin/ssh`, `/usr/sbin/devlink`, `/usr/sbin/ip`, `/usr/sbin/lsmod`, `/proc/modules`, and the relevant `/sys` attribute files are denied in the execution environment.
- 2026-04-11 01:06:52 UTC OPENSHELL-VM-PROBE
  - Commands: `rg --files crates/openshell-vm`; `rg -n 'gvproxy|virtio|net|krun|vfio|nic' crates/openshell-vm`; `sed -n` on `src/lib.rs`, `src/ffi.rs`, `src/main.rs`, and `scripts/openshell-vm-init.sh`.
  - Verified current runtime choices are only `gvproxy`, `tsi`, and `none`; there is no existing CLI or config surface for a second NIC attachment.
  - Verified host-side libkrun bindings currently expose only vsock, block, and `krun_add_net_unixstream` / `krun_add_net_unixgram`; there is no current VFIO or PCI device-assignment path in `openshell-vm`.
  - Verified launch flow adds exactly one virtio-net device via gvproxy and one guest-visible management path; guest init handles only `eth0` and installs the default route there.
  - Inference: a second virtio-net NIC is structurally feasible by extending `VmConfig`, CLI parsing, and launch/init logic to add another `krun_add_net_unixstream` attachment and configure guest `eth1`.
  - Inference: direct VF-backed attachment is not currently proven in `openshell-vm`; it likely requires either new libkrun/device-assignment support or a different runtime path.
  - Exact files most likely needing modification for dual-NIC support: `/home/ubuntu/work/OpenShell/crates/openshell-vm/src/lib.rs`, `/home/ubuntu/work/OpenShell/crates/openshell-vm/src/main.rs`, `/home/ubuntu/work/OpenShell/crates/openshell-vm/scripts/openshell-vm-init.sh`, and possibly `/home/ubuntu/work/OpenShell/crates/openshell-vm/src/ffi.rs` if libkrun needs extra host-device bindings.
- 2026-04-11 01:06:52 UTC SLICE-ASSESSMENT
  - Current answer: `openshell-vm` looks viable for the microVM part, but the first slice is not yet proven on this machine because the DPU-visible VF/representor path is still unverified and current libkrun integration has no demonstrated VF attachment path.
  - Smallest next experiment: outside this restricted session, use operator/root access to identify the BlueField PF with `devlink`/`lspci`, confirm eSwitch mode and representors, create exactly one reversible VF on the target PF, and only then prototype a second `virtio-net` path in `openshell-vm --exec` before attempting sandbox/pod integration.
  - If VF attachment into libkrun remains blocked after PF/VF validation, KubeVirt/QEMU-style VF passthrough is the cleaner fallback for the protected-egress slice than forcing it through the current `gvproxy`-centric runtime.
- 2026-04-11 00:59:27 UTC HANDSHAKE
  - Agent online on host `lenny1`.
  - Machine type: host x86_64 (`uname -m` = `x86_64`), not DPU ARM.
  - Working directories: `/home/ubuntu/work/OpenShellBF` and `/home/ubuntu/work/OpenShell`.
  - BlueField tooling appears partially present: `devlink` and `ip` are installed; `mlxconfig`, `lspci`, and `ovs-vsctl` are not currently in `PATH`.
  - Code investigation and any code changes will happen in `/home/ubuntu/work/OpenShell`.
  - Next path to investigate after handshake publish: `/home/ubuntu/work/OpenShellBF/docs` and `/home/ubuntu/work/OpenShell/crates/openshell-vm`.
- 2026-04-10: Initial project handoff created.
- 2026-04-14 21:25:00 UTC SESSION-6 PF1-CT-NAT-DEBUG
  - Goal: move the protected-egress path from PF0 to PF1 so NAT symmetry matches the already-routed DPU IP `10.185.99.182/24` on `enp3s0f1s0`.
  - Host-side changes already committed before this note:
    - `scripts/common.sh` defaults switched to PF1 (`0000:b3:00.1`, `enp179s0f1np1`).
    - `scripts/start-vf-bridge.sh` now drives PF1 and host VF `enp179s0f1v0`.
    - `scripts/setup-dpu-nat.sh` installs OVS CT/NAT flows on `ovsbr2` using `pf1vf0` -> `p1` with SNAT `10.185.99.182`.
    - `docs/dpu-nat-design.md` updated for the PF1/ovsbr2 design.
  - VERIFIED:
    - Host PF1 VF exists: `enp179s0f1v0`.
    - DPU representor exists: `pf1vf0` and is attached to `ovsbr2`.
    - `vf-bridge` is bound to `enp179s0f1v0` and reaches `libkrun connected — bridge active` once the VM is started with `--with-vf-bridge`.
    - Guest `eth1` appears only when the microVM is launched with `sudo ./scripts/start-microvm.sh --with-vf-bridge`.
    - Guest routing can be re-applied successfully:
      - `ip addr add 10.99.2.2/24 dev eth1`
      - `ip rule add from 10.99.2.2 lookup 100 priority 99`
      - `ip neigh replace 10.99.2.1 lladdr 02:00:00:00:00:01 dev eth1 nud permanent`
      - `ip route add default via 10.99.2.1 dev eth1 table 100`
      - Verified with `ip route get 160.79.104.10 from 10.99.2.2` => `via 10.99.2.1 dev eth1 table 100`
    - Test-1 result: `ct(table=X)` recirculation on `pf1vf0` still fails silently on BF3/OVS 3.3.0040. Packets are seen on `pf1vf0` only and never reach `p1` nor the next table.
    - Test-3 result: SF escape path partially works. Packet path proven:
      - `pf1vf0` receives SYN from `10.99.2.2`
      - OVS forwards it to `en3f1pf1sf0`
      - Linux receives it on `enp3s0f1s0`
  - BLOCKED:
    - SF escape path still does not NAT/forward. On `enp3s0f1s0`, repeated SYNs from `10.99.2.2` are visible, but:
      - no SNAT to `10.185.99.182` occurs,
      - iptables/nftables NAT counters remain at `0`,
      - no successful outbound TCP connect completes.
    - Strong inference: packets are entering the Linux side of the PF1 SF pair but not traversing the expected forwarding/NAT path; further ad-hoc debugging should stop until the BlueField architecture is validated against vendor guidance.
  - Artifacts added this session:
    - `docs/dpu-ct-debug-prompt.md` — focused prompt documenting why `ct(table=X)` and `ct(commit,nat(...))` are failing on BF3 VF representors.
    - `scripts/setup-dpu-nat.sh` improved to include SF representor pass-through on `ovsbr2`.
  - Resume point for next session:
    1. Start from the known-good host setup:
       - `sudo ./scripts/start-vf-bridge.sh`
       - `sudo ./scripts/start-microvm.sh --with-vf-bridge`
    2. Re-verify guest `eth1` exists and routing points `10.99.2.2` traffic to `eth1`.
    3. Continue only with a design-backed PF1 solution:
       - either prove SF escape can truly traverse Linux forwarding/NAT,
       - or replace it with a vendor-supported PF1-native CT/NAT path.
    4. Do not continue the older PF0/PF1 asymmetric NAT experiments.
- 2026-04-13 23:35:10 UTC SESSION-7 PF1-DATAPATH-CONCLUSION
  - Host-side automation added in `OpenShellBF`:
    - `scripts/test-dpu-software-nat.sh`
    - `scripts/run-dpu-software-nat-proof.sh`
    - `scripts/test-dpu-veth-nat.sh`
    - `scripts/run-dpu-veth-nat-proof.sh`
    - `scripts/common.sh` updated with DPU SSH defaults and control-socket reuse
  - VERIFIED — OVS CT/NAT is broken on this BF3 path even with hw-offload disabled:
    - `table=0,ip,in_port=pf1vf0,actions=ct(table=1,nat)` increments on `ovsbr2`
    - `table=1,ct_state=+new+trk,in_port=pf1vf0` remains `0`
    - `table=1,priority=0,actions=drop` receives the test packets
    - `tcpdump` shows SYNs on `pf1vf0`, nothing on `p1`
    - Conclusion: this is not just a hardware-offload issue; the BF3/OVS recirculation CT path is non-functional for this VF path
  - VERIFIED — DPU-side Linux veth escape path is L2/L3 viable:
    - OVS forwards `pf1vf0 -> ovsnat0`
    - Linux receives traffic on `hostnat0` (after aligning the gateway MAC to `02:00:00:00:00:01`)
    - traffic is forwarded onward and becomes visible on both `enp3s0f1s0` and `p1`
  - BLOCKED — Linux conntrack/NAT still does not engage on that BF3 egress path:
    - `iptables -t raw PREROUTING` CT rule on `hostnat0` increments
    - `iptables FORWARD` rule `hostnat0 -> enp3s0f1s0` increments
    - `nft` `ctdebug` shows only the plain packet counter increments; `ct state new|established|untracked` all remain `0`
    - `nft list chain ip nat POSTROUTING` shows all custom SNAT counters remain `0`
    - `conntrack -L` shows no entries for `10.99.2.2` / `160.79.104.10`
    - `tcpdump` on `enp3s0f1s0` and `p1` shows packets still leaving with source `10.99.2.2`
  - CONCLUSION — Transparent DPU SNAT is not viable on this BF3 setup via either:
    - OVS CT/NAT on `pf1vf0`
    - Linux netfilter NAT after OVS handoff through `nat0`
    - Linux netfilter NAT after OVS handoff through `ovsnat0 <-> hostnat0`
  - RECOMMENDATION — Stop spending time on transparent NAT. The viable next design is a DPU-owned explicit egress proxy / gateway process (L4/L7) that the microVM sandbox reaches over `eth1`, while the DPU remains the enforcement and audit point.
- 2026-04-13 23:55:00 UTC SESSION-8 DOCA-NAT-PROXY-RESEARCH
  - REVIEWED — NVIDIA DOCA NAT guide confirms the supported NAT path is a **DOCA Flow reference app on the DPU**, not OVS CT/NAT and not Linux netfilter NAT after punting to Arm Linux.
  - REVIEWED — NAT guide execution requires:
    - hugepages,
    - SF-backed devices,
    - mandatory `-a auxiliary:mlx5_core.sf.X,dv_flow_en=2` flags,
    - and a **2-port-only** deployment model.
  - REVIEWED — DOCA Flow switch-mode docs indicate representor-centric switching with a miss-to-software model, which is a much better architectural fit for a BF3 hybrid fast/slow path than more OVS/netfilter experiments.
  - REVIEWED — `j3soon/bluefield-dpu-setup-notes` and its `examples/` tree. Practical takeaway:
    - the repo is useful mainly as a **DOCA environment bring-up checklist**,
    - especially host/DPU DOCA version alignment and running a simple DOCA sample before a more complex app,
    - not as a ready-made NAT/proxy datapath design.
  - REVIEWED — local OpenShell code already includes a real DPU proxy binary:
    - `crates/openshell-sandbox/src/dpu_proxy.rs`
    - `run_dpu_proxy(...)`
    - `run_dpu_proxy_cc(...)`
    - OPA, credential injection, inference routing, and OCSF audit are already present.
  - SAVED — research note in `docs/doca-nat-proxy-hybrid-research.md`
  - RECOMMENDATION — next implementation should explicitly split:
    - `direct` mode → BF3-native DOCA NAT / DOCA Flow lane
    - `managed_proxy` mode → explicit DPU proxy reusing `openshell-dpu-proxy`
  - DO NOT RESUME:
    - transparent OVS CT/NAT debugging on `pf1vf0`
    - Linux netfilter SNAT debugging on `nat0`
    - Linux netfilter SNAT debugging on `ovsnat0 <-> hostnat0`
- 2026-04-11 SESSION-2 CODE-CHANGES (commit e8f43b15, branch codex/bluefield-probe)
  - Phase 2 scaffolding complete. All changes compile clean (`cargo check -p openshell-vm`; rustfmt passes).
  - `crates/openshell-vm/src/lib.rs`: Added `ProtectedEgressConfig { socket_path, mac }` struct. Added `protected_egress: Option<ProtectedEgressConfig>` to `VmConfig`. Initialized to `None` in `VmConfig::gateway()`. Added `krun_add_net_unixstream` call in `launch()` (Linux only; returns `VmError::HostSetup` on non-Linux). virtio-net features: CSUM, GUEST_CSUM, GUEST_TSO4, GUEST_UFO, HOST_TSO4, HOST_UFO.
  - `crates/openshell-vm/src/main.rs`: Added `--protected-egress-socket <path>` and `--protected-egress-mac <XX:XX:XX:XX:XX:XX>` CLI flags (default MAC 52:54:00:bf:00:01). Added `parse_mac()` helper. `ProtectedEgressConfig` wired into both exec and gateway VmConfig branches.
  - `crates/openshell-vm/scripts/openshell-vm-init.sh`: Added eth1 bring-up block after eth0/dummy0 block. eth1 gets static 10.99.2.2/24, no default route (protected egress only).
  - `deploy/setup-protected-egress-vf.sh`: New one-shot host-side script for BF3 VF creation and vf-bridge launch. Validates VFIO modules, PCI device, netdev; discovers VF netdev automatically; launches vf-bridge with --netdev and --socket args.
  - PENDING at time of this log: vf-bridge binary did not exist — Phase 3 work.
  - RESOLVED in commit f64c3479 below.
- 2026-04-11 SESSION-2 VF-BRIDGE (commit f64c3479, branch codex/bluefield-probe)
  - Phase 3 scaffolding complete. New crate: `crates/vf-bridge/`.
  - Wire protocol confirmed from OpenShell lib.rs doc comment ("QEMU wire protocol") and gvproxy integration (`-listen-qemu`): each frame is prefixed with a 4-byte big-endian length (QEMU net-socket stream mode, same as `qemu -netdev socket,type=stream`). Reference: QEMU net/socket.c, `htonl(size)` framing.
  - Architecture: two threads share dup'd `AF_PACKET` fd and `try_clone()`'d `UnixStream`. Thread A (guest→host): reads QEMU-framed packets from UNIX socket, writes raw Ethernet to AF_PACKET. Thread B (host→guest): reads raw Ethernet from AF_PACKET, writes QEMU-framed to UNIX socket. `PACKET_IGNORE_OUTGOING` (Linux ≥ 4.20) suppresses TX loopback. `SO_RCVTIMEO` 500ms enables clean shutdown when UNIX socket closes.
  - `deploy/setup-protected-egress-vf.sh`: updated `--netdev` → `--ifname` to match the vf-bridge CLI.
  - PROVEN: compilation (`cargo build -p vf-bridge`, zero warnings). QEMU framing unit tests: 4/4 pass (round-trip, zero-length rejected, oversized rejected, multiple sequential frames).
  - UNPROVEN: runtime AF_PACKET + socket relay (requires `CAP_NET_RAW`; no root in this session). No root available; `AF_PACKET socket()` returns EPERM without the capability.
  - TEST PROCEDURE (run as root on lenny1): `sudo ip tuntap add dev tap-vftest mode tap && sudo ip link set tap-vftest up`; `sudo ./target/release/vf-bridge --socket /tmp/test.sock --ifname tap-vftest --verbose &`; connect a test client speaking QEMU framing to `/tmp/test.sock` and send Ethernet frames; observe `[guest→host]` and `[host→guest]` log lines and final counters.
  - FOR BF3 VF PATH: `sudo ./deploy/setup-protected-egress-vf.sh` creates VF on `enp179s0f0np0`, discovers `enp179s0f0v0`, and execs `vf-bridge --ifname enp179s0f0v0 --socket /run/openshell/vf-bridge/eth1.sock`. Then `openshell-vm --protected-egress-socket /run/openshell/vf-bridge/eth1.sock`. DPU-side representor `pf0vf0` in ovsbr1 provides enforcement point.
  - NEXT: run the runtime test with root on lenny1 to prove TAP-backed packet flow, then VF-backed flow with a running openshell-vm. Phase 3 → Phase 4: DPU control-agent and egress-gateway on `enp3s0f0s0`.
