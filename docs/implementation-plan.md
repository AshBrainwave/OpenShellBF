# Implementation Plan: OpenShell x BlueField-3 MVP

Status: Living document — updated from verified lab evidence  
Last updated: 2026-04-11  
Previous version: superseded (was generic; this version is evidence-driven)

---

## Current State (as of 2026-04-11)

### What exists and works

| Item | State | Evidence |
|---|---|---|
| BF3 DPU hardware | Present on `lenny1` | lspci confirmed `0000:b3:00.0/1` |
| eSwitch mode | `switchdev` (DPU-side) | `devlink dev eswitch show` on DPU |
| OVS 3.3.0040 | Running on DPU, two bridges configured | `ovs-vsctl show` |
| SR-IOV VF | 1 VF active (`enp179s0f0v0`, `pf0vf0`) | sriov_numvfs=1, devlink port show |
| DPU drop enforcement | PROVEN — 1500 packets dropped | n_packets=1500 on pf0vf0 drop flow |
| DPU allow enforcement | PROVEN — ICMP allow rule tested | idle_age confirms rule exercised |
| IOMMU isolation | Each PF in its own group | /sys/kernel/iommu_groups |
| VFIO modules | All loaded | lsmod |
| KVM access | `/dev/kvm` present, ubuntu in kvm group | id, ls /dev/kvm |
| rshim path | `tmfifo_net0`, DPU at 192.168.100.2 | ip addr show tmfifo_net0 |
| openshell-vm | Experimental libkrun runtime exists | crates/openshell-vm/ |
| openshell-vm Linux path | gvproxy QEMU socket → guest eth0 | src/lib.rs launch() |

### What does not exist yet

| Item | Gap |
|---|---|
| Guest eth1 | No second NIC in openshell-vm — code change required |
| Host-side eth1 bridge | No TAP/macvtap wiring to VF yet |
| DPU control agent | No policy-fetch loop; flows are static OVS rules today |
| DPU egress gateway | No L7-aware process on `enp3s0f0s0` |
| Policy compilation | No OpenShell-to-OVS-flow pipeline |
| Audit emission | No structured audit events from DPU |
| Fail-closed TTL | No policy-expiry enforcement |
| Managed-proxy mode | Not started |

---

## Verified DPU Network Map

```
lenny1 (host x86_64)
├── enp179s0f0np0  (host PF0, 10.185.99.20 — management/internet)
│    └── BF3 eSwitch → pf0hpf on DPU, in ovsbr1
├── enp179s0f0v0   (host VF0, 10.99.1.1/24, MAC 52:54:00:aa:bb:cc)
│    └── BF3 eSwitch → pf0vf0 on DPU, in ovsbr1, DROP rule active
└── tmfifo_net0    (rshim, 192.168.100.1/24 → DPU at 192.168.100.2)

BF3 DPU (192.168.100.2, ARM)
└── ovsbr1 (OVS bridge)
     ├── p0            — physical uplink (wire)
     ├── pf0hpf        — host PF0 representor
     ├── pf0vf0        — host VF0 representor  ← enforcement point
     ├── en3f0pf0sf0   — SF0 OVS representor   ← gateway attach (OVS side)
     └── ovsbr1        — internal bridge port
          └── enp3s0f0s0 (SF0 app netdev, NOT in OVS) ← gateway process binds here

Active OVS flows (ovsbr1):
  priority=200  ip   in_port=pf0hpf nw_dst=45.54.28.15       → DROP
  priority=100  tcp  in_port=pf0hpf nw_dst=140.82.116.6 p=443 → output:p0
  priority=100  icmp in_port=pf0vf0                            → output:p0 (test)
  priority=50        in_port=pf0vf0                            → DROP (1500 hits)
  priority=0                                                    → NORMAL
```

---

## Architecture Decision: openshell-vm or KubeVirt?

### Continue with openshell-vm if:
- libkrun or the host-side bridge can attach a second virtio-net device to a TAP/macvtap that is wired to the VF
- Guest eth1 can be added without changes to the libkrun library itself (just new FFI binding or bridge process)
- The trust boundary claim holds: DPU sees all eth1 traffic at `pf0vf0` representor

### Pivot to KubeVirt / QEMU if:
- libkrun cannot accept a TAP fd or QEMU-compatible socket wired to the VF without major library changes
- The latency or MAC handling of the bridge approach invalidates the trust claim
- VF passthrough via VFIO is required and libkrun cannot support it

**Current assessment**: Continue with openshell-vm. The bridge approach (TAP wired to VF via Linux bridge or macvtap) is structurally sound. DPU sees all traffic through `pf0vf0` regardless of whether the host-side is a macvtap, a tap+bridge, or a direct VF. The spike needed is small (1–2 days): determine whether `krun_add_net_unixstream` can accept a TAP fd, or whether a small bridge process is needed.

---

## Phased Plan

### Phase 0: Hardware and Control-Plane Validation

**Status: COMPLETE**

**Goal**: Confirm the hardware can support the first proof slice before writing code.

**Verified deliverables**:
- [x] BF3 PF PCI addresses identified (`0000:b3:00.0`, `0000:b3:00.1`)
- [x] SR-IOV capacity confirmed (16 VFs per PF)
- [x] IOMMU groups: each PF isolated (groups 19, 20, 21)
- [x] VFIO modules loaded (`vfio`, `vfio_pci`, `vfio_iommu_type1`, `iommufd`)
- [x] KVM ready (`/dev/kvm`, ubuntu in kvm group)
- [x] eSwitch mode: `switchdev` (DPU-side only — EOPNOTSUPP from host, by design)
- [x] OVS configured on DPU with both bridges
- [x] rshim path to DPU confirmed (192.168.100.2)
- [x] All five tools present: `devlink`, `mlxconfig`, `lspci`, `ovs-vsctl`, `ip`

**Exit criteria**: met.

---

### Phase 1: DPU Network Fact Validation

**Status: COMPLETE**

**Goal**: Prove a VF representor appears on the DPU, gets wired into OVS, and the DPU can enforce policy on that VF's traffic.

**Verified deliverables**:
- [x] VF created: `echo 1 > /sys/bus/pci/devices/0000:b3:00.0/sriov_numvfs` → `enp179s0f0v0` on host, `pf0vf0` on DPU
- [x] `pf0vf0` added to `ovsbr1`: `sudo ovs-vsctl add-port ovsbr1 pf0vf0`
- [x] Default-drop flow installed: `priority=50,in_port=pf0vf0,actions=drop`
- [x] Drop enforcement proven: n_packets=1500 on drop rule (real traffic dropped)
- [x] Allow rule tested: `priority=100,icmp,in_port=pf0vf0,actions=output:p0` (exercised)
- [x] VF survives system sleep (VF and flows persist across operator sessions)
- [x] SF model understood: `en3f0pf0sf0` (OVS rep) + `enp3s0f0s0` (app netdev for gateway)

**Exit criteria**: met. DPU enforcement point is proven. A process binding to `enp3s0f0s0` or OVS TC rules on `pf0vf0` can control all microVM eth1 traffic.

---

### Phase 2: openshell-vm Second NIC

**Status: NEXT**

**Goal**: Boot a microVM with a second virtio-net interface (`eth1`) whose traffic exits through the host VF and is visible at `pf0vf0` on the DPU.

**Dependencies**:
- Phase 1 complete (VF wired into OVS) ✓
- KVM accessible ✓
- openshell-vm buildable on this host (runtime bundle available or embedded)

**Deliverables**:
- [ ] Spike: determine whether `krun_add_net_unixstream` accepts a TAP/macvtap fd, or whether a bridge process is needed
- [ ] Host-side bridge: TAP device wired to VF (`enp179s0f0v0`) via Linux bridge or macvtap
- [ ] openshell-vm code: `protected_egress` field in `VmConfig`, second `krun_add_net_unixstream` (or `krun_add_net_tap`) call in `launch()`
- [ ] Guest init: eth1 brought up with static IP and NO default route
- [ ] Boot test: microVM launches, `eth1` is UP in guest
- [ ] Traffic test: guest sends traffic via eth1, appears at DPU `pf0vf0` (tcpdump confirms)

**Code touchpoints** (all in `~/work/OpenShell/crates/openshell-vm/`):

```
src/lib.rs
  - Add to VmConfig:
      protected_egress: Option<ProtectedEgressConfig>
  - Add struct:
      pub struct ProtectedEgressConfig {
          pub tap_path: PathBuf,     // path to /dev/tapN (macvtap) or TAP socket
          pub mac: [u8; 6],          // guest-visible eth1 MAC
      }
  - Add to VmContext (new method):
      fn add_net_tap_fd(&self, fd: RawFd, mac: &[u8; 6], features: u32) -> Result<(), VmError>
        // calls krun_add_net_unixstream with fd >= 0 and null path
        // OR calls a new krun_add_net_tap if that symbol exists in libkrun
  - Extend launch():
      if let Some(pe) = &config.protected_egress {
          let fd = open_tap_fd(&pe.tap_path)?;
          vm.add_net_tap_fd(fd, &pe.mac, COMPAT_NET_FEATURES)?;
      }

src/ffi.rs
  - If krun_add_net_tap exists in the loaded libkrun, add binding:
      type KrunAddNetTap = unsafe extern "C" fn(ctx_id: u32, tap_fd: i32, c_mac: *const u8, features: u32) -> i32;
  - Otherwise: use krun_add_net_unixstream with fd >= 0 and null path (test first)

src/main.rs
  - Add CLI flag: --protected-egress-tap <path>  (path to /dev/tapN)
  - Add CLI flag: --protected-egress-mac <mac>   (guest eth1 MAC, e.g. 52:54:00:bf:01:00)

scripts/openshell-vm-init.sh
  - After the existing eth0 block, add:
      if ip link show eth1 >/dev/null 2>&1; then
          ip link set eth1 up
          ip addr add 10.99.2.2/24 dev eth1
          # NO default route on eth1 — protected egress only, not management
      fi
```

**Host-side setup script** (new: `deploy/setup-protected-egress-vf.sh`):
```bash
# Run once per host boot to wire VF to a TAP for microVM use
PF=enp179s0f0np0
VF_NETDEV=enp179s0f0v0
TAP=tap-protected

# Ensure VF exists
echo 1 | sudo tee /sys/bus/pci/devices/0000:b3:00.0/sriov_numvfs

# Assign MAC
sudo ip link set $VF_NETDEV address 52:54:00:aa:bb:cc
sudo ip link set $VF_NETDEV up

# Create TAP (mode tap, owned by current user for libkrun access)
sudo ip tuntap add dev $TAP mode tap user ubuntu
sudo ip link set $TAP up

# Bridge TAP to VF so guest traffic flows through VF to DPU
sudo ip link add br-protected type bridge
sudo ip link set $VF_NETDEV master br-protected
sudo ip link set $TAP master br-protected
sudo ip link set br-protected up

# Note: bridge MTU should match VF MTU (1500)
echo "TAP device: /dev/$(ip link show $TAP | grep -oP '(?<=^)\d+')"
```

**Spike question to resolve first** (half-day):

Does `krun_add_net_unixstream(ctx_id, NULL, fd, mac, features, 0)` work when `fd` is a raw TAP fd (from `/dev/tapN`)? If yes, the FFI is already sufficient. If no, try adding `krun_add_net_tap` binding by name from the loaded libkrun. If that symbol doesn't exist, implement a minimal `tap-to-unixstream` bridge process in Rust (< 100 lines using `tun` crate) and use the existing gvproxy socket path.

**Risks**:
- libkrun may not expose a stable TAP-fd API on this platform — MEDIUM risk. Fallback: tiny bridge process.
- MAC address conflict between macvtap and bridge — LOW risk. Assign distinct MACs.
- Guest eth1 accidentally acquiring a default route — LOW risk. Init script explicitly skips it.

**Exit criteria**:
- `ip link show eth1` inside the VM shows UP
- `tcpdump -i pf0vf0 -n` on DPU shows guest eth1 traffic
- DPU `pf0vf0` drop rule n_packets increments when guest sends via eth1

---

### Phase 3: Protected Egress Routing in the Guest

**Status: NOT STARTED**

**Goal**: Ensure the guest routes correctly — management traffic stays on eth0 (gvproxy path), protected egress traffic exits via eth1 (DPU path), and the two paths cannot cross.

**Deliverables**:
- [ ] Guest routing table: default via eth0 (gvproxy), specific external ranges via eth1
- [ ] Policy routing or marking: mark packets intended for protected egress, force them out eth1
- [ ] Verify no bypass: from inside the guest, traffic to a denied destination via eth1 is blocked; traffic via eth0 is NOT blocked (different path, different policy)
- [ ] Document the bypass-prevention model (the spec requires this claim to be testable)

**Implementation approach**:

Inside the guest (init script additions):
```bash
# Policy-based routing for protected egress
ip rule add fwmark 0x1 table 100
ip route add default dev eth1 table 100

# Any process wanting protected egress sets SO_MARK=1 or uses explicit routing
# OR: route all non-management traffic via eth1 by default:
ip route add default dev eth1 metric 200   # lower priority than eth0 default
# eth0 default stays at metric 100 (gvproxy-assigned)
```

For the MVP, the simplest model is: protected-egress-bound processes use eth1 explicitly (via `SO_BINDTODEVICE` or explicit routing). Automatic steering via eBPF or nftables marking is a Phase 4+ optimization.

**Exit criteria**:
- Curl via eth0 (management): reaches gvproxy endpoint, bypasses DPU policy
- Curl via eth1 (protected): DPU policy applies, drop/allow per flow rule

---

### Phase 4: DPU-Visible Ingress and First Enforcement Slice

**Status: NOT STARTED**

**Goal**: Replace static OVS flows with policy driven by the OpenShell policy API. Prove the end-to-end first slice: one sandbox, one allowed destination, one denied destination, DPU-originated audit.

**Deliverables**:
- [ ] `dpu/control-agent/`: Rust binary that runs on the DPU ARM, polls OpenShell policy API over mTLS, compiles received policy into OVS flows or in-memory allow/deny table, manages TTL
- [ ] `dpu/policy-compiler/`: Translates OpenShell policy rules to OVS flow format (priority, match fields, action)
- [ ] `dpu/egress-gateway/`: Rust process binding to `enp3s0f0s0` (SF0 app netdev). Handles L7-aware decisions (SNI, Host header) that OVS alone cannot do. For L4-only rules, OVS flows suffice.
- [ ] Sandbox binding: map VF0 (`pf0vf0`) to sandbox identity and policy revision
- [ ] Audit emission: allow/deny events emitted as OCSF-compatible JSON (see `proto/audit_event.proto`)
- [ ] Prove first slice:
  1. Sandbox sends to `api.anthropic.com:443` — DPU allows (via OVS or gateway) → reaches wire
  2. Sandbox sends to `evil.example.com:443` — DPU denies → OVS drops, audit emitted
  3. Policy revision updated in OpenShell → DPU recompiles within 30s → new rule takes effect
  4. Policy TTL expires → DPU blocks new flows → sandbox marked `fail_closed`

**DPU component placement**:
```
DPU ARM filesystem (/opt/openshell-dpu/ or similar):
├── control-agent   — systemd service, polls OpenShell API, manages policy
├── egress-gateway  — binds to enp3s0f0s0, handles L7 flows
└── policy-compiler — library used by control-agent
```

**OVS flow management** (control-agent responsibility):
```
For each sandbox VF (e.g. pf0vf0):
  DELETE existing policy flows for that VF
  For each allow rule in compiled policy:
    ADD: priority=100, in_port=pf0vf0, <match>, actions=output:p0
  ADD: priority=50,  in_port=pf0vf0, actions=output:en3f0pf0sf0  ← gateway for L7
  (gateway process on enp3s0f0s0 makes final decision and re-injects or drops)
```

**Code location**: new top-level directories in `~/work/OpenShell`:
```
dpu/
├── control-agent/   (Rust, cross-compiled for aarch64-unknown-linux-gnu)
├── egress-gateway/  (Rust, aarch64)
└── policy-compiler/ (Rust library, shared)
```

**Risks**:
- mTLS between DPU and OpenShell server needs PKI setup — MEDIUM. Use self-signed certs for pilot.
- Cross-compilation to aarch64 from x86 host — LOW. Standard Rust toolchain supports this.
- OVS flow API from Rust — LOW. Use `std::process::Command` wrapping `ovs-ofctl` initially; replace with OpenFlow socket later.
- L7 classification (SNI) requires the gateway process to be on-path — MEDIUM. Verify that traffic steered to `en3f0pf0sf0` via OVS actually arrives at `enp3s0f0s0` in the DPU process.

**Exit criteria**:
- One sandbox reaches one allowed destination, is blocked from one denied destination
- Audit events visible for both allow and deny
- Policy update propagates within 30 seconds
- TTL expiry blocks new flows

---

### Phase 5: Managed-Provider Routes, Audit Hardening, Fail-Closed Validation

**Status: NOT STARTED**

**Goal**: Complete the MVP feature set per the unified spec.

**Deliverables**:
- [ ] `dpu/credential-vault/`: DPU-resident secret store for managed provider routes
- [ ] Managed-proxy mode in egress-gateway: credential injection for one supported provider
- [ ] Fail-closed behavior validated under simulated policy-API outage
- [ ] Degraded state (`degraded` vs `fail_closed`) surfaced to operator
- [ ] Audit backlog buffering when sink unavailable
- [ ] Deployment hardening checklist (SR-IOV lock, DPU access control, uplink exclusivity)

**Exit criteria**: pilot checklist in `deploy/` passes on a second independent host.

---

## Implementation Decision Fork

```
Phase 2 spike: can libkrun attach a TAP fd to guest eth1?
       │
       ├── YES (krun_add_net_unixstream with fd, or krun_add_net_tap found)
       │    └── Continue openshell-vm path → Phase 3 → Phase 4 → Phase 5
       │
       └── NO (libkrun cannot accept tap fd without major changes)
            └── Option A: add a small Rust bridge process (tap ↔ UNIX socket, ~100 lines)
                          → adds one new host component, otherwise same path
            └── Option B: pivot Phase 2 to QEMU with macvtap/vhost-net
                          → proves end-to-end faster, libkrun ported later
                          → Phase 3–5 are runtime-agnostic
```

Decision owner: engineering team after spike results in Phase 2.

---

## Code Component Map

### Existing (in `~/work/OpenShell`)

| Path | Purpose | Phase |
|---|---|---|
| `crates/openshell-vm/src/lib.rs` | VmConfig, launch(), VmContext | Phase 2 |
| `crates/openshell-vm/src/ffi.rs` | libkrun FFI bindings | Phase 2 |
| `crates/openshell-vm/src/main.rs` | CLI entry point | Phase 2 |
| `crates/openshell-vm/scripts/openshell-vm-init.sh` | Guest PID 1 init | Phase 2, 3 |
| `proto/compiled_policy.proto` | Compiled policy contract | Phase 4 |
| `proto/audit_event.proto` | Audit event contract | Phase 4 |
| `proto/sandbox_binding.proto` | Host-to-DPU binding contract | Phase 4 |

### New (to be created in `~/work/OpenShell`)

| Path | Purpose | Phase | Target arch |
|---|---|---|---|
| `deploy/setup-protected-egress-vf.sh` | Host VF + TAP setup script | Phase 2 | x86 |
| `dpu/control-agent/` | Policy fetch, compile, OVS management, TTL | Phase 4 | aarch64 |
| `dpu/egress-gateway/` | L7 flow handler on enp3s0f0s0 | Phase 4 | aarch64 |
| `dpu/policy-compiler/` | OpenShell policy → compiled rules | Phase 4 | aarch64 |
| `dpu/credential-vault/` | DPU-resident managed secrets | Phase 5 | aarch64 |
| `host/runtime-manager/` | Protected microVM lifecycle | Phase 4 | x86 |
| `host/vf-manager/` | VF allocation, binding, release | Phase 2 | x86 |
| `tests/integration/` | Policy allow/deny, fail-closed, audit | Phase 4 | both |

### DPU-side deployment target

Files cross-compiled to `aarch64-unknown-linux-gnu` and deployed to DPU at `ubuntu@192.168.100.2` (via rshim SSH). Deployment mechanism TBD (scp + systemd, or a container on DPU).

---

## Immediate Next Actions (operator + agent)

### For the operator (minutes):
1. Clean up test ICMP allow flow on DPU:
   ```bash
   ssh ubuntu@192.168.100.2 'sudo ovs-ofctl del-flows ovsbr1 "icmp,in_port=pf0vf0"'
   ```
2. Decide: should `pf0hpf` flows (drop to 45.54.28.15, allow GitHub) stay? If they are intended production policy, document them; if test artifacts, clean them too.

### For the agent (this session):
1. Run the Phase 2 spike: check what symbols libkrun exposes on this host.
2. Scaffold `deploy/setup-protected-egress-vf.sh` in `~/work/OpenShell`.
3. Implement the openshell-vm dual-NIC changes (3 files) on `codex/bluefield-probe`.
4. Record all changes in STATUS.md with branch and SHA.

---

## Key Constraints Carried Forward

- **eSwitch management**: DPU-side only. Any OVS or devlink command must run via `ssh ubuntu@192.168.100.2`. Host devlink returns EOPNOTSUPP for eswitch commands.
- **No file deletion** on this host.
- **SSH to DPU via rshim only** (`ssh ubuntu@192.168.100.2`). No other DPU SSH path.
- **Reversible changes only**: VFs removed with `echo 0 > sriov_numvfs`; OVS flows removed with `ovs-ofctl del-flows`; bridges removed with `ip link del`.
- **Do not overclaim**: trust boundary holds only while the DPU's eSwitch config is correct. Any host-level bypass route (e.g. host PF default route to wire) would need to be audited separately.
