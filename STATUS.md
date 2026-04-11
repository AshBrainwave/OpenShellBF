# OpenShellBF Status

Last updated: 2026-04-11
Updated by: bluefield-codex

## Current focus

- Bootstrap a microVM-first MVP for OpenShell x BlueField-3.
- Verify whether a BlueField-backed protected-egress path can be attached to `openshell-vm`.

## Snapshot

- Source of truth: `docs/unified-spec.md`
- Runtime direction: microVM-first
- Open question: can `openshell-vm` expose a second NIC suitable for DPU-protected egress?

## Latest findings

- Upstream OpenShell already has an experimental `openshell-vm` runtime built on `libkrun`.
- The current VM path appears centered on `gvproxy` / `virtio-net`.
- The missing MVP piece is the BlueField SR-IOV protected-egress path.

## Immediate next steps

1. Verify BlueField SR-IOV, representor, and eSwitch readiness on the lab machine.
2. Inspect `openshell-vm` for second-NIC support and the cleanest attachment point.
3. Try the smallest possible proof slice: one microVM, one control path, one protected-egress path.

## Blockers and risks

- Direct VF-backed attachment into the microVM is not yet proven.
- If `openshell-vm` cannot expose a usable second NIC, the fallback architecture may need a different runtime adapter.

## Working notes

- Update this file at least when:
  - a new hardware fact is verified,
  - a blocker is discovered,
  - an implementation decision changes,
  - or a new next step is chosen.
- Prefer short dated entries below instead of rewriting history.

### Log

- 2026-04-11 06:33:43 UTC HANDSHAKE
  - Agent online on host `lenny1`.
  - Date/time: 2026-04-11 06:33:43 UTC.
  - Machine type: host x86_64 (`uname -m` = `x86_64`, kernel 6.8.0-107-generic). Not DPU ARM.
  - Tooling present in PATH: `devlink` (/usr/sbin/devlink), `mlxconfig` (/usr/bin/mlxconfig), `lspci` (/usr/bin/lspci), `ovs-vsctl` (/usr/bin/ovs-vsctl), `ip` (/usr/sbin/ip). All five confirmed present.
  - Code investigation and any code changes will happen in `/home/ubuntu/work/OpenShell` on branch `codex/bluefield-probe`.
  - Remote for OpenShell: SSH only (`git@github.com:AshBrainwave/OpenShell.git`); no writable HTTPS remote detected.
  - Next path to investigate: hardware SR-IOV readiness (BF3 eSwitch mode, VF count, IOMMU) and openshell-vm second-NIC feasibility.
  - All docs read: unified-spec.md, design-spec.md, implementation-plan.md, bluefield-codex-handoff.txt.

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
