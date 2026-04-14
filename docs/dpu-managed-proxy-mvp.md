# DPU Managed Proxy MVP

This note captures the first BF3 implementation slice to build now.

## Scope

Implement only the `managed_proxy` lane first:

- host workload remains `openshell-vm`
- guest uses protected `eth1`
- DPU runs the existing `openshell-dpu-proxy` in **TCP mode**
- DPU policy and credentials are synced by a new **DPU control agent**
- Comm Channel is **not** part of this MVP

## Why this is the right first slice

- It reuses existing OpenShell proxy code instead of inventing a new dataplane.
- It avoids more time on BF3-transparent NAT paths that were already disproven.
- It matches the trust model:
  - host untrusted
  - guest is a policy subject
  - DPU owns enforcement
  - DPU owns policy/credential pull

## MVP runtime model

### Host

- `openshell-vm` stays in place.
- `eth0` remains management / gvproxy.
- `eth1` remains protected egress toward the DPU.

### DPU

- `openshell-dpu-proxy --mode tcp` listens on the protected DPU-side IP, e.g. `10.99.2.1:3128`.
- local OPA daemon evaluates destination policy for that sandbox.
- local credentials file supplies provider env / header injection inputs.
- one DPU control agent pulls policy from OpenShell and writes local runtime state.

### OpenShell

- still acts as source of truth for:
  - sandbox policy
  - provider environment
  - policy status

## Files the DPU agent should materialize

Per sandbox:

- `opa/policy.rego`
- `opa/data.json`
- `credentials.json`
- `state.json`

`state.json` should include:

- `sandbox_id`
- `version`
- `policy_hash`
- `config_revision`
- `policy_source`
- compile warnings (for example: binary-scoped rules ignored in DPU proxy MVP)

## Known MVP simplifications

- Policy remains **per sandbox**, but the first DPU OPA compiler is **destination-based**.
- Binary-level policy distinctions from the host-side supervisor are not preserved in the first DPU proxy slice.
- This is acceptable because the proxy unit is sandbox-specific and the goal is to preserve sandbox isolation first.

## Explicit non-goals

- no Comm Channel
- no transparent TLS interception claims beyond the explicit proxy model
- no OVS CT/NAT
- no Linux `iptables` / `nftables` NAT on the DPU protected path
- no DPU VM per sandbox yet

## Follow-on work after MVP

1. Package the proxy isolation unit as a DPU container if needed.
2. Add shared DPU control-agent orchestration for multiple sandboxes.
3. Start the `direct` lane as a DOCA-native spike.
