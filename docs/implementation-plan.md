# Implementation Plan: OpenShell x BlueField-3

Status: Draft  
Last updated: 2026-04-10

## Objective

Turn the PRD and design spec into an execution plan that a coding agent can pick up immediately.

## Recommended repository shape

```text
docs/
proto/
host/
dpu/
tests/
deploy/
```

Suggested ownership:

- `proto/`: shared contracts for policy, audit, and host-DPU control
- `host/`: microVM lifecycle management, protected-egress attachment, and sandbox integration
- `dpu/`: control agent, policy compiler, egress gateway, credential vault integration
- `tests/`: integration, adversarial, and hardware-in-loop harnesses
- `deploy/`: pilot deployment scripts and configuration examples

## Phase 0: document and contract first

### Deliverables

- PRD approved
- design spec approved
- initial API contracts sketched
- explicit list of deployment assumptions agreed
- hardware-readiness checklist and pilot-validation commands captured

### Tasks

1. Create a `proto/` contract for compiled policy, audit event, and sandbox binding.
2. Decide whether host-to-DPU control traffic will be gRPC, DOCA Comm Channel messages, or a thin wrapper around existing transport.
3. Choose a single pilot provider route for managed proxy mode, if any.
4. Lock the MVP claim set for external communication.
5. Validate eSwitch mode, VF capacity, IOMMU grouping, VFIO readiness, KVM readiness, and microVM runtime constraints before making protected-egress integration the critical path.

### Definition of done

- Engineering and product agree on what the MVP will and will not claim.
- The team has enough hardware and runtime facts to choose the first viable protected-egress handoff path.

## Phase 1: protected egress path

### Deliverables

- Host can launch one protected microVM sandbox with management and protected-egress paths.
- DPU can fetch policy and activate a compiled policy for that sandbox.
- Protected sandbox traffic is allow or deny controlled by the DPU.
- Audit events are visible centrally.

### Tasks

1. Implement DPU control-agent skeleton with policy fetch, cache, and TTL logic.
2. Implement host runtime-manager flow with microVM launch, management-path setup, and protected-egress attachment.
3. Implement host vf-manager flow with protected-egress allocation and release.
4. Implement direct-mode egress gateway for one protocol family and one allowlisted destination.
5. Implement allow and deny audit events.
6. Add health endpoint or status output for active policy revision and protection state.
7. Use a compiled in-memory policy structure for flow decisions rather than a per-flow OPA REST call.

### Definition of done

- A protected sandbox reaches an allowlisted endpoint and is blocked from a denied endpoint without relying on a host proxy.
- The sandbox runtime is microVM-backed for protected mode.

## Phase 2: policy hot reload and failure handling

### Deliverables

- Policy change propagation validated
- fail-closed behavior validated
- degraded-state visibility added

### Tasks

1. Implement revision-aware policy swap.
2. Add last-known-good policy persistence on the DPU with a bounded validity window.
3. Add TTL expiry behavior that blocks new flows.
4. Add operator-visible state transitions: `protected`, `degraded`, `fail_closed`.
5. Add audit for policy update and policy sync failure.
6. Validate that protected-egress traffic stays off the management-path NIC.

### Definition of done

- Adding a deny rule in OpenShell blocks new matching traffic within the target propagation window.

## Phase 3: managed-provider proxy mode

### Deliverables

- One provider integration using DPU-resident secrets
- route-level method and path enforcement
- secret rotation path

### Tasks

1. Implement credential vault abstraction on the DPU.
2. Implement one provider route in managed proxy mode.
3. Add secret reference in compiled policy.
4. Add secret rotation audit events.
5. Add latency and error-path instrumentation.

### Definition of done

- A supported upstream route works with DPU-held credentials and without host secret distribution.

## Phase 4: hardening and optimization

### Deliverables

- deployment checks,
- performance profiling,
- optional partial offload,
- security review package.

### Tasks

1. Add startup checks for SR-IOV, IOMMU, VF availability, and policy API reachability.
2. Profile direct mode and managed proxy mode.
3. Offload stable simple rules where performance justifies it.
4. Document residual risks and support envelope.

### Definition of done

- The pilot can be repeated reliably on a second host with the same deployment guide.

## Immediate next work items

If we continue from this repository, the highest-value next changes are:

1. Scaffold `host/runtime-manager` with placeholder interfaces for launch, attach-control-nic, attach-protected-egress, and terminate.
2. Scaffold `dpu/control-agent` with a mock policy fetcher, validity-window handling, and local compiled-policy cache.
3. Scaffold `host/vf-manager` with placeholder interfaces for protected-egress allocate, bind, and release.
4. Add `tests/integration/` with a minimal policy-allow, policy-deny, dual-path routing, and TTL-expiry harness.
5. Add a pilot preflight checklist in `deploy/` that captures hardware-readiness commands and expected operator decisions.

## Suggested backlog priorities

| Priority | Item | Why it matters |
| --- | --- | --- |
| P0 | Sandbox-to-protected-egress binding contract | Core identity bridge between orchestration and enforcement |
| P0 | Compiled policy format | Prevents implementation drift across host, DPU, and tests |
| P0 | Direct-mode allow and deny path | Proves the fundamental value proposition |
| P0 | Audit schema and sink | Required for trust and operator usability |
| P1 | Policy hot reload | Required for operational credibility |
| P1 | Managed-provider route | Proves DPU secret residency value |
| P2 | Partial hardware offload | Performance optimization after correctness |
| P2 | Attested binary identity design | Important, but not blocking the MVP |

## What is already done in this repo

- Product framing is written in [PRD](/Users/amalegaonkar/Documents/New project/docs/prd.md).
- Technical architecture is written in [design spec](/Users/amalegaonkar/Documents/New project/docs/design-spec.md).
- Comparison criteria for future iterations are written in [review rubric](/Users/amalegaonkar/Documents/New project/docs/review-rubric.md).
- Initial shared contracts are started in [proto/compiled_policy.proto](/Users/amalegaonkar/Documents/New project/proto/compiled_policy.proto), [proto/audit_event.proto](/Users/amalegaonkar/Documents/New project/proto/audit_event.proto), and [proto/sandbox_binding.proto](/Users/amalegaonkar/Documents/New project/proto/sandbox_binding.proto).
