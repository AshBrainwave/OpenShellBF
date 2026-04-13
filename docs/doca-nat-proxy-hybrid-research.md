# DOCA NAT + DPU Proxy Hybrid Research

## Goal

Define a BF3-supported hybrid design that combines:

- a **direct egress path** for protected traffic that only needs destination/IP/port enforcement, and
- an **explicit DPU proxy path** for routes that need L7 handling, credential injection, or an explicit client trust model.

This note supersedes further work on transparent NAT through OVS CT/NAT or Linux netfilter NAT on the current BF3 path.

## External Sources Reviewed

- NVIDIA DOCA NAT Application Guide v2.7.0
  - https://docs.nvidia.com/doca/archive/2-7-0/nvidia+doca+nat+application+guide/index.html
- NVIDIA DOCA Flow guide, switch mode
  - https://docs.nvidia.com/doca/sdk/doca-flow/index.html
- NVIDIA DOCA Simple Forward VNF Application Guide
  - https://docs.nvidia.com/doca/archive/2-9-2/doca+simple+forward+vnf+application+guide/index.html
- NVIDIA BlueField DPU Setup Notes
  - https://github.com/j3soon/bluefield-dpu-setup-notes
  - https://tutorial.j3soon.com/hpc/extras/bluefield-dpu-setup-notes/
- j3soon example files inspected directly:
  - `examples/README.md`
  - `examples/doca-dma-sample.md`

## What The NVIDIA Docs Say

### 1. `doca_nat` is a DOCA Flow reference app, not an OVS/netfilter design

The NAT guide describes a DPU-native NAT application built on **DOCA Flow**. It runs on the DPU, classifies ingress traffic, rewrites addresses/ports, and forwards to an egress port. This is materially different from:

- `ovs-ofctl ct(...)` on representors, and
- Linux `iptables` / `nftables` NAT after punting to the Arm Linux stack.

Implication for OpenShell:

- our failed OVS/netfilter experiments do **not** disprove supported BF3 NAT;
- they show that we were using the wrong datapath for supported NAT.

### 2. `doca_nat` is SF-centric and two-port only

The NAT guide's execution example is:

```text
./doca_nat -a auxiliary:mlx5_core.sf.4,dv_flow_en=2 \
           -a auxiliary:mlx5_core.sf.5,dv_flow_en=2 \
           -- -m static -r nat_static_rules.json -lan sf3 -wan sf4
```

The same section explicitly says:

- the SF flags are mandatory,
- the SF identifiers must match the configured SFs, and
- only **2 ports are supported**.

Implication for OpenShell:

- if we want NVIDIA's supported NAT path, the next spike should use **SFs** and **DOCA Flow**, not OVS CT/NAT on a VF representor;
- we should not assume the NAT application can simply be dropped into the current `pf1vf0 -> ovsbr2 -> Linux` path.

### 3. DOCA Flow switch mode supports representor-driven hybrid pipelines

The DOCA Flow switch-mode documentation says:

- switch mode is for internal switching,
- only representor ports are allowed,
- unmatched traffic can be received on Arm-side RSS queues from the relevant representor.

That is important because it suggests a supported pattern for a hybrid fast/slow path:

- hardware-handled flows stay in DOCA Flow,
- software-handled or exceptional flows can be punted to Arm-side software.

Implication for OpenShell:

- a future BF3-native design can use **hardware fast-path for direct flows** and **software slow-path for proxy/L7 flows**;
- this looks much closer to our product model than trying to force Linux NAT onto an OVS-punted path.

### 4. The `j3soon` repo is useful as a DOCA bring-up checklist, not as a NAT/proxy blueprint

The linked repo and examples are still useful, but mostly for environment discipline:

- host and DPU DOCA versions should match,
- compile and run a simple DOCA sample first,
- validate that the DPU SDK and BF image are healthy before attempting a more complex app.

The `examples/` tree is minimal:

- `README.md` — framework overview and version-alignment advice
- `doca-dma-sample.md` — step-by-step DMA sample bring-up

The main value here is procedural:

- before touching `doca_nat`, run a known-good sample such as DMA on the same BF image;
- use that as a gate for "is DOCA working at all on this DPU/host pair?"

## What The Local Codebase Already Has

OpenShell already contains a significant part of the proxy lane:

- `crates/openshell-sandbox/src/dpu_proxy.rs`
  - standalone `openshell-dpu-proxy` binary
- `crates/openshell-sandbox/src/lib.rs`
  - `run_dpu_proxy(...)`
  - `run_dpu_proxy_cc(...)`
- `crates/openshell-sandbox/src/proxy.rs`
  - HTTP CONNECT proxy with OPA evaluation, TLS handling, and audit
- `crates/openshell-router/`
  - inference route handling
- `crates/openshell-ocsf/`
  - audit/event emission

Important local findings:

- TCP mode already exists for DPU-side listening (`--listen 0.0.0.0:8080`)
- Comm Channel mode already exists for host-to-DPU transport
- credentials file loading is already implemented
- inference route handling is already implemented
- OPA REST evaluation is already implemented

Implication:

- we do **not** need to invent a DPU proxy stack from scratch;
- the first proxy slice should be an adaptation/deployment exercise, not a greenfield build.

## Recommended Product Split

The product should explicitly separate two paths:

### Direct mode

Use a BF3-native direct egress path for traffic that only needs:

- destination/IP/port enforcement,
- fail-closed DPU enforcement,
- audit at connection level.

Recommended implementation direction:

- `doca_nat` or a custom DOCA Flow app on an SF-based lane.

### Managed proxy mode

Use an explicit DPU proxy for traffic that needs:

- provider-specific credential injection,
- request/header rewriting,
- L7-aware allow/deny,
- explicit client trust semantics.

Recommended implementation direction:

- reuse `openshell-dpu-proxy`.

This aligns with the existing OpenShell documentation and avoids pretending that a single transparent datapath solves both problems.

## Recommended Hybrid Architecture

### First practical hybrid

Use **two paths over the same protected guest NIC**:

1. **Direct egress path**
   - guest traffic uses protected `eth1`
   - DPU steers approved direct traffic into a DOCA-native NAT/forwarder lane
   - no TLS interception, no credential injection

2. **Explicit proxy path**
   - guest uses `HTTPS_PROXY=http://10.99.2.1:3128`
   - DPU proxy handles CONNECT, OPA, credentials, inference routing, audit
   - outbound from the proxy may initially use ordinary DPU routing

This gives the user-visible "combo" without forcing proxied traffic through the same NAT machinery as direct traffic.

### Why this is the right first combination

- It matches the current OpenShell spec split between `direct` and `managed_proxy`.
- It reuses existing OpenShell proxy code.
- It avoids more time on unsupported or broken transparent-NAT experiments.
- It lets us prove value in two independent increments:
  - BF3-native direct enforcement
  - DPU-resident managed proxy

## Operational Recommendations For The Next Spike

### Track A: DOCA sanity gate

Before `doca_nat` work:

1. verify host and DPU DOCA versions are aligned
2. run a simple DOCA sample on the same image
3. compile `doca_nat` from `/opt/mellanox/doca/applications/nat/`

If the DMA sample or a trivial DOCA app fails, do not debug NAT yet.

### Track B: Proxy-first proof

Bring up `openshell-dpu-proxy` in **TCP mode** on the DPU-side protected network:

- bind it to the protected DPU LAN IP, e.g. `10.99.2.1:3128`
- point the guest or sandbox to that proxy explicitly
- prove:
  - CONNECT works over `eth1`
  - OPA decisioning works
  - audit events land in OCSF
  - credential injection works for one provider route

Why TCP mode first:

- it matches guest-over-`eth1` better than Comm Channel;
- Comm Channel remains the production option for host-originated/untrusted-host transports.

### Track C: `doca_nat` proof, isolated from OpenShell

Treat `doca_nat` as a separate BF3 bring-up spike:

- create the required SFs
- allocate hugepages
- run `doca_nat` on a minimal LAN/WAN SF pair
- prove packet translation works independently of the microVM

Only after that proof should we decide how to connect the guest protected-egress lane into the LAN side of the NAT app.

## Open Questions

These remain unresolved and should be answered before implementation:

1. Which PF/port should own the **direct NAT lane** on this machine?
   - PF0 currently has the most proven guest visibility path.
   - PF1 currently has the known-routable DPU-side internet configuration.

2. What is the cleanest SF topology for `doca_nat` on this BF3 image?
   - which SF is LAN-facing,
   - which SF is WAN-facing,
   - and whether the guest protected-egress path should move to that PF entirely.

3. Should the DPU proxy's outbound traffic initially use:
   - ordinary DPU Linux routing, or
   - a later DOCA-native WAN egress lane?

4. Can the direct `doca_nat` lane and the explicit proxy lane share a physical uplink cleanly, or should they use separate SF allocations?

## Current Recommendation

Do **not** resume transparent NAT debugging.

Resume with this order:

1. verify DOCA health with a simple sample
2. bring up `openshell-dpu-proxy` over the guest protected network
3. independently prove `doca_nat` on an SF pair
4. then join them under a product split of:
   - `direct`
   - `managed_proxy`

That is the most credible path to a BF3-supported hybrid design.
