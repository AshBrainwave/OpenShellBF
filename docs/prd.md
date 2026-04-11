# PRD: OpenShell x BlueField-3 Hardware-Enforced Agent Security

Status: Draft  
Last updated: 2026-04-10  
Primary audience: Product, platform engineering, security engineering, systems engineering

## 1. Executive summary

OpenShell already defines what an AI agent is allowed to do through network, filesystem, process, and identity-aware policy. BlueField-3 adds a hardware-separated enforcement point that sits between the host and the network. Together, they create a security plane where protected AI agent sandboxes keep working under policy even if the host OS is compromised.

The MVP goal is not to solve every security problem in one release. It is to deliver a credible first product that:

- runs protected sandboxes in a microVM-backed runtime,
- forces protected sandbox egress through the DPU,
- enforces deny-by-default outbound policy using live OpenShell policy data,
- keeps provider credentials on the DPU instead of the host, and
- emits tamper-resistant audit events from the enforcement boundary.

## 2. Problem

AI coding agents and runtime agents are unusually risky workloads because they:

- execute arbitrary code,
- make external network calls,
- interact with private repositories and APIs,
- hold high-value credentials, and
- often run on general-purpose hosts that are trusted too much.

Today, most agent security is enforced by host-side proxies or software shims. That model fails open under host compromise:

- a root attacker can kill or bypass the proxy,
- credentials stored on the host can be copied,
- traffic can be redirected before policy evaluation,
- host-observed process identity can be spoofed,
- audit logs generated on the host are not a trustworthy source of truth.

Customers who want to deploy agents in higher-risk environments need a stronger trust boundary than the host OS.

## 3. Target users

### Primary users

- Platform security engineers who define and enforce agent network policy
- AI infrastructure engineers who operate OpenShell sandboxes and provider integrations
- Security operations and compliance teams who need trustworthy audit trails

### Secondary users

- Internal AI platform teams exposing secured agent infrastructure to developers
- Enterprise buyers evaluating controls for regulated or sensitive environments

## 4. Jobs to be done

- As a security engineer, I need protected agent sandboxes to lose internet access when policy cannot be enforced, rather than quietly failing open.
- As an AI platform engineer, I need to attach OpenShell policy to a sandbox once and have the DPU enforce it without restarts.
- As a compliance owner, I need audit records from a trust boundary stronger than the host.
- As a platform operator, I need provider API credentials to remain off the host.
- As an application team, I need a secure default path that does not require every agent framework to build custom network controls.

## 5. Product goals

### Goals

1. Deliver hardware-separated outbound enforcement for protected OpenShell sandboxes.
2. Reuse OpenShell as the policy source of truth instead of inventing a second policy model.
3. Use a microVM-backed execution model for protected mode so agent sandboxes do not share the host kernel directly.
4. Ensure protected sandbox traffic fails closed if the DPU cannot validate or enforce current policy.
5. Store provider credentials only on the DPU for supported managed routes.
6. Provide centralized audit for policy decisions and security events.
7. Support a rollout path that starts with one host and one DPU and expands without redesign.

### Non-goals for MVP

1. Full transparent TLS credential injection for arbitrary HTTPS traffic without a trusted proxy or trust-bundle setup.
2. Strong binary identity guarantees under full host compromise.
3. DPU-backed shared storage, model-weight gating, or tamper-evident write volumes.
4. Inbound service protection or east-west workload segmentation beyond the protected sandbox egress path.
5. Complete multi-cluster, multi-DPU fleet management beyond a small number of pilot systems.
6. Support for every runtime or orchestrator in the first release; Kubernetes and OpenShift adapters can follow the microVM-backed MVP.

## 6. Product principles

- Security claims must match the actual trust boundary.
- Deny by default beats permissive fallback.
- Central policy, local enforcement.
- Keep the first release narrow enough to ship and prove.
- Advanced features should be opt-in when they require trust-bundle or runtime changes.

## 7. MVP scope

### In scope

- MicroVM-backed protected sandbox runtime for MVP
- Dual-homed protected sandboxes with a management path and a protected-egress path
- Per-sandbox BlueField VF assignment for protected sandboxes
- DPU-side control agent that syncs policy from OpenShell
- DPU-side deny-by-default outbound policy enforcement
- Central policy revision tracking and hot reload
- DPU-resident credential storage for managed upstream provider routes
- DPU-originated audit events for allow, deny, policy update, and credential-route events
- Health, status, and rollout tooling for operators

### Out of scope

- Generic transparent HTTPS header injection for any destination
- Host-compromise-proof binary identity enforcement
- Shared filesystem export from the DPU
- Policy compilation to full line-rate hardware offload for all traffic classes
- Automated tenant billing, quota management, or self-service admin UI
- Full OpenShift or generic Kubernetes integration as a day-one protected runtime requirement

## 8. User stories

### Security engineer

- I can define an OpenShell policy for a sandbox and know that new outbound connections are blocked within 30 seconds of a deny rule being added.
- I can see which sandbox, destination, and policy rule caused a deny event.
- I can verify that a protected sandbox cannot bypass policy even if host-side proxy processes are disabled.

### Platform operator

- I can attach a protected networking profile to a sandbox and have the required VF and DPU bindings provisioned automatically.
- I can run a protected sandbox in a microVM-backed runtime without exposing agent execution directly to the host kernel.
- I can rotate a provider secret on the DPU without touching the host filesystem.
- I can tell whether a sandbox is running in protected mode, degraded mode, or unprotected mode.

### Compliance or incident response

- I can export structured security events from the DPU-side enforcement point.
- I can prove which policy revision was active when a connection was allowed or denied.

## 9. Functional requirements

| ID | Requirement | Priority |
| --- | --- | --- |
| FR-1 | The system shall support a protected sandbox mode in which the sandbox runs in a microVM-backed runtime. | P0 |
| FR-2 | The system shall provide each protected sandbox with a management path and a BlueField-backed protected-egress attachment for primary external egress. | P0 |
| FR-3 | The system shall bind each protected sandbox to a unique policy context on the DPU. | P0 |
| FR-4 | The DPU shall fetch OpenShell sandbox policy over mTLS and refresh active policy without sandbox restart. | P0 |
| FR-5 | The DPU shall enforce deny-by-default outbound policy for protected sandboxes. | P0 |
| FR-6 | If current policy cannot be validated or enforcement is unavailable past a configured TTL, the DPU shall block new outbound flows for protected sandboxes. | P0 |
| FR-7 | The system shall emit structured audit events for allow, deny, policy sync, policy mismatch, and enforcement-health changes. | P0 |
| FR-8 | The system shall support DPU-resident secrets for managed upstream routes and ensure those secrets are never written to host disk. | P0 |
| FR-9 | The system shall expose operator-visible status for sandbox protection state, policy revision, protected-egress binding, runtime health, and DPU health. | P1 |
| FR-10 | The system shall support an optional managed-provider proxy mode for routes that require DPU-side credential injection. | P1 |
| FR-11 | The system shall preserve a clear mapping from policy decision to OpenShell policy group and revision in audit output. | P1 |
| FR-12 | The system shall support rollout and rollback controls at the sandbox or host level. | P1 |
| FR-13 | The system shall preserve an audit trail for policy changes and DPU credential updates. | P1 |

## 10. Non-functional requirements

| ID | Requirement | Target |
| --- | --- | --- |
| NFR-1 | Policy propagation latency | New policy active on DPU within 30 seconds p95 |
| NFR-2 | Audit delivery latency | Event visible centrally within 5 seconds p95 |
| NFR-3 | Protected sandbox provisioning | MicroVM launch plus protected-egress binding completed within 60 seconds p95 |
| NFR-4 | Enforcement default | Fail closed for new connections after policy TTL expiry |
| NFR-5 | Secret residency | 0 provider secrets stored on host disk for managed routes |
| NFR-6 | Direct egress latency overhead | Less than 5 ms p95 added latency for direct allow flows |
| NFR-7 | Managed proxy latency overhead | Less than 25 ms p95 added latency for proxied provider routes |
| NFR-8 | Availability target for pilot | 99.5% monthly for protected networking on pilot hosts |

## 11. Success metrics

### Pilot success metrics

- 100% of protected sandbox egress exits through the DPU-managed path
- 100% of attempted disallowed outbound connections from protected sandboxes are blocked
- 0 provider secrets for managed routes are present on the host filesystem
- At least one policy change and one deny event can be traced end-to-end with matching revision IDs
- Operators can detect and explain degraded protection state within 5 minutes

### Business and adoption signals

- At least one internal or design-partner deployment uses protected mode for production-adjacent agent workloads
- Security review accepts the architecture as materially stronger than host-side proxy enforcement

## 12. Key constraints and product truths

These are important enough to state directly in the PRD because they affect positioning and delivery:

- Transparent credential injection into arbitrary TLS traffic is not possible without either explicit proxy semantics or client trust of a DPU-managed certificate authority.
- If the DPU relies on host-supplied binary metadata alone, binary identity is still host-asserted, not host-compromise-proof.
- FQDN policy enforcement requires either DNS-aware resolution and cache management or TLS/HTTP metadata inspection at connection setup; IP-only allowlists are not enough for many SaaS APIs.

The MVP should embrace these constraints instead of hiding them.

## 13. Dependencies

- OpenShell server access to `GetSandboxConfig` or equivalent policy API
- mTLS identities for host components and DPU components
- BlueField-3 in a deployment mode where protected sandbox traffic is forced through the DPU path
- Host support for KVM or equivalent microVM execution, plus SR-IOV, IOMMU, VF assignment, and protected-egress attachment
- Central audit sink or OpenShell audit ingestion path

## 14. Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| MicroVM networking or second-NIC attachment is harder than expected | Delays protected sandbox launch | Keep the MVP runtime focused on the smallest viable microVM path and validate the protected-egress attachment before broad orchestration work |
| Transparent L7 claims prove infeasible | Product confusion and rework | Position managed-provider proxy mode as explicit MVP behavior |
| DPU software path adds too much latency | Lower adoption for chatty agent workloads | Start with pilot workloads, profile, then offload simple flows later |
| Policy drift between OpenShell and DPU | Security gaps or operator confusion | Track revisions, hashes, and last-known-good policy per sandbox |
| Host can still reconfigure PF or disable SR-IOV in some deployments | Trust boundary weakened | Treat secure DPU ownership and host lockdown as a deployment prerequisite |

## 15. Release plan

### Alpha

- Single host, single DPU, single protected sandbox
- MicroVM-backed protected runtime working
- VF-based protected egress path working
- DPU policy sync, deny-by-default enforcement, and audit events working

### Beta

- Multiple protected sandboxes per host
- Operator visibility and rollback flow
- Managed-provider proxy mode for one or two upstream APIs
- Evaluation of Kubernetes or OpenShift adapters if needed

### GA candidate

- Stable provisioning flow
- Audit export and operational dashboards
- Defined support envelope and deployment prerequisites

## 16. Launch criteria

The MVP is ready for a pilot when all of the following are true:

1. A protected sandbox cannot reach an unauthorized destination after host-side proxy processes are disabled.
2. A policy update on the OpenShell server blocks newly denied traffic within the propagation target.
3. Managed-provider secrets remain on the DPU and are rotatable without host secret distribution.
4. A DPU failure or expired policy state causes new flows to fail closed.
5. Audit events show sandbox ID, destination, decision, policy revision, and timestamp from the DPU-side enforcement path.

## 17. Future phases

- Attested binary identity using measured launch or signed execution tokens
- Hardware offload of simple L3/L4 allow rules
- DPU-backed secret mounts or audit volumes
- Policy-gated model-weight access
- Multi-host and multi-DPU fleet orchestration
