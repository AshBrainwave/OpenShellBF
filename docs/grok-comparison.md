# Grok Comparison: OpenShell x BlueField-3 Draft

Status: Draft  
Last updated: 2026-04-10

## Overall verdict

Grok's draft is polished, confident, and easy to present. It is the weakest of the external drafts so far on security realism because it turns several hard future-state ideas into unconditional MVP promises.

The right merge strategy is:

- keep its clean formatting, personas, and use-case framing,
- keep its sense of sequencing and measurable outcomes,
- reject its absolute claims, fallback model, and "must-have" requirements that depend on undeveloped trust mechanisms.

## Where Grok is stronger

### 1. Clean PRD structure

Grok does a good job packaging the material into a single, presentation-friendly document:

- executive summary,
- personas,
- use cases,
- requirements,
- risks,
- metrics.

That format is useful for internal review and stakeholder circulation.

### 2. Better product storytelling

The document reads like a launch narrative rather than a lab notebook. It makes the business case clearer, especially for:

- regulated enterprise environments,
- developer simplicity,
- credential protection,
- zero-trust positioning.

### 3. Useful persona and use-case sections

The target-user section is stronger than most of the external drafts. It helps explain who benefits from the platform and how they would actually use it.

### 4. Stronger emphasis on measurable outcomes

The success-metrics section is useful as a forcing function, even though some of the numbers need revision.

## Where Grok is weaker

### 1. It overclaims in absolute terms

Several phrases are too strong to survive serious architecture review:

- "world's first,"
- "unbreakable trust boundary,"
- "cannot exfiltrate API keys,"
- "cannot bypass network policies,"
- "all credentials, policy enforcement, and inference routing live exclusively on the DPU."

Those statements are not acceptable as MVP truth without very explicit deployment assumptions and tighter scope.

For example:

- credentials may live on the DPU for managed routes, but not for every possible sandbox workflow,
- policy survives host compromise only if the DPU truly remains the sole outbound path,
- inference routing is only meaningful for routes the DPU actually handles.

### 2. Binary identity is treated as solved

Grok lists "Binary identity enforcement via OCPP metadata over DOCA Comm Channel" as a `Must`.

That is not credible for MVP under a hostile-host model.

If the host is compromised, host-originated metadata is not strong identity by itself. Without attestation or a stronger verification chain, binary identity remains advisory. Making it a `Must` pushes the spec into fiction.

### 3. Transparent TLS MITM is treated as a default platform feature

The draft lists "Credential vault + TLS MITM injection exclusively on DPU" as a `Must`.

That is too broad.

Transparent TLS credential injection requires:

- explicit proxy semantics, or
- client trust of a DPU-managed CA, or
- some narrower provider-specific trust arrangement.

Without that, it should not be described as a universal core feature of the platform.

### 4. The fallback model contradicts the security thesis

This is one of the biggest issues in the draft.

Under non-functional requirements it says:

- "graceful fallback to software proxy"

That undermines the whole trust-boundary story. If the product falls back to host-side software enforcement when the hardware path fails, then the system no longer preserves its core guarantee under host compromise.

For protected mode, the correct behavior is fail closed, not graceful fallback to a weaker host path.

### 5. Performance claims are unrealistic for the stated feature set

The draft claims both:

- `<=5 ms p99` added latency,
- and "full 400 Gb/s hardware offload,"

while also requiring:

- OPA-driven policy decisions,
- TLS MITM,
- credential injection,
- inference routing,
- and potentially L7 enforcement.

Those claims do not belong together in an MVP spec unless backed by benchmark evidence and a very careful split between direct-mode offloaded flows and software-handled proxy flows.

### 6. NVMe-oF and DPU-backed storage are presented too early

The draft makes policy-gated NVMe-oF mounts part of the technical design and roadmap early on.

That is interesting future work, but it should not sit near the core MVP unless there is already evidence that the team can deliver:

- protected egress,
- hot policy reload,
- DPU audit,
- and managed credential routing.

Otherwise the spec becomes too broad and hard to ship.

### 7. "L3-L7 hardware enforcement" is too imprecise

Grok says:

- "Hardware-enforced network policy (L3-L7) at DPU eSwitch + OPA"

That mixes very different enforcement layers into one statement.

The better model is:

- DPU on-path enforcement for protected traffic,
- selective hardware offload for simple L3 or L4 rules later,
- software gateway handling for L7-sensitive flows.

Without that distinction, the spec sounds cleaner than the implementation reality.

### 8. "DPU OS unreachable from host" is too categorical

That may be a deployment goal, but it is not universally guaranteed merely because a BlueField exists. The real claim should be narrower:

- the host should not be able to read DPU memory or bypass the protected traffic path,
- and management access to the DPU must be deployment-controlled and hardened.

## Best merged solution

The strongest combined version uses Grok's packaging and our stricter trust-boundary rules.

### Keep from Grok

- the clean unified PRD-plus-design-doc structure,
- the personas and use cases,
- the success-metrics framing,
- the clear sequencing by phase.

### Do not keep as written

- "world's first" and similar unsupported marketing claims,
- "unbreakable" or absolute security language,
- binary identity as an MVP `Must`,
- universal TLS MITM as an MVP `Must`,
- graceful fallback to a software proxy in protected mode,
- full 400 Gb/s offload claims for the complete feature set.

## What the Grok draft should say instead

### Replace the core promise

Instead of:

- "the AI coding agent cannot exfiltrate API keys, bypass network policies, or access unauthorized resources."

Use:

- "In protected mode, outbound policy and managed-route credentials are enforced from the DPU path rather than the host, materially reducing the impact of host compromise when deployment prerequisites hold."

### Replace the binary identity requirement

Instead of:

- "Binary identity enforcement via OCPP metadata over DOCA Comm Channel" as `Must`

Use:

- "Binary metadata may be recorded or used in advisory mode in MVP. Enforcement based on binary identity requires a future attestation-backed mechanism."

### Replace the TLS MITM requirement

Instead of:

- "Credential vault + TLS MITM injection exclusively on DPU" as `Must`

Use:

- "The MVP supports direct protected egress for destination control and an opt-in managed-provider proxy mode for routes that require DPU-resident credentials."

### Replace the reliability requirement

Instead of:

- "graceful fallback to software proxy"

Use:

- "Protected mode fails closed for new flows when the DPU cannot validate or enforce current policy."

## Recommended next step after Grok

The next thing to build is still not binary identity or NVMe-oF.

The next thing to build is the smallest proof of value:

1. One protected sandbox attached to one VF.
2. One DPU-side sandbox binding.
3. One pulled-and-compiled policy revision.
4. One allowlisted external destination.
5. One denied external destination.
6. DPU-side audit for allow, deny, and policy sync.
7. Fail-closed behavior after policy TTL expiry.

If that slice works, then the project has earned the right to add:

- managed-provider proxy mode,
- secret rotation flows,
- stronger performance targets,
- attestation-backed identity,
- and later DPU-backed storage.

## Recommendation on the Grok draft

Adopt:

- the document structure,
- the personas,
- the use cases,
- the clearer phase-based packaging.

Do not adopt without revision:

- the absolute security claims,
- the binary-identity `Must`,
- the TLS-MITM `Must`,
- the fallback-to-software-proxy requirement,
- the full-throughput performance claims.
