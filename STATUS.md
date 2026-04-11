# OpenShellBF Status

Last updated: 2026-04-10
Updated by: initial setup

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

- 2026-04-11 00:59:27 UTC HANDSHAKE
  - Agent online on host `lenny1`.
  - Machine type: host x86_64 (`uname -m` = `x86_64`), not DPU ARM.
  - Working directories: `/home/ubuntu/work/OpenShellBF` and `/home/ubuntu/work/OpenShell`.
  - BlueField tooling appears partially present: `devlink` and `ip` are installed; `mlxconfig`, `lspci`, and `ovs-vsctl` are not currently in `PATH`.
  - Code investigation and any code changes will happen in `/home/ubuntu/work/OpenShell`.
  - Next path to investigate after handshake publish: `/home/ubuntu/work/OpenShellBF/docs` and `/home/ubuntu/work/OpenShell/crates/openshell-vm`.
- 2026-04-10: Initial project handoff created.
