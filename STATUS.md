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
