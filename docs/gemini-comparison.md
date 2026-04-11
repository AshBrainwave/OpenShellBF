# Gemini Comparison: Project Aegis Draft

Status: Draft  
Last updated: 2026-04-10

## Overall verdict

Gemini's draft is strong as a pitch and fast to read. It is weaker as an implementation source of truth because it overclaims in a few places that matter to the trust model.

The best merge strategy is:

- keep Gemini's concise narrative and rollout energy,
- keep our narrower MVP boundaries,
- reject any claim that depends on transparent TLS interception or host-unspoofable binary identity unless the spec also delivers the required trust mechanism.

## Where Gemini is stronger

### 1. Better branding and executive framing

"Project Aegis" is a useful codename, and the "OpenShell defines the law; BlueField is the sheriff" framing is memorable. That is valuable for internal alignment and design-partner conversations.

### 2. Stronger sense of implementation momentum

Gemini usefully names a current focus:

- hardware provisioning,
- VF attachment,
- transparent proxy transition.

That makes it feel closer to execution than a pure architecture memo.

### 3. More explicit zero-config operator intent

The requirement that agents should not need `HTTPS_PROXY` for protected networking is a good product goal for direct egress mode.

### 4. Better concrete plumbing in the later revision

The later Gemini revision adds three useful implementation details:

- a dual-homed pod model using a VF-backed secondary interface,
- a more explicit mTLS heartbeat plus policy-validity contract,
- and DNS-derived hostname mapping as one possible classification signal for direct mode.

These are good additions as long as they stay recommendations rather than unqualified truths.

## Where Gemini is weaker

### 1. Binary identity is overstated

Gemini says the system "must distinguish between `claude` and `curl` even if the host attempts to spoof the process" and later suggests OCPP plus process-hash verification.

That is not a safe MVP claim.

If the host is fully compromised, host-originated process metadata is still host-asserted unless at least one stronger mechanism exists:

- measured launch,
- signed execution tokens,
- DPU-verifiable attestation rooted outside the host,
- or a similarly strong identity scheme.

Without that, binary identity should stay `advisory` or be deferred.

### 2. Transparent TLS credential injection is overstated

Gemini presents transparent TLS MITM as part of the core design while also requiring zero-config networking.

Those two goals conflict for arbitrary HTTPS traffic.

DPU-side header injection requires one of:

- explicit proxy semantics, or
- a trust-bundle distribution model where the sandbox trusts a DPU-managed CA.

Without that, the product should not claim universal transparent credential injection at the hardware boundary.

### 3. Fail-closed behavior is implied, not designed

Gemini states that "if the proxy dies, the hardware drops the packets."

That can be true, but only if the deployment intentionally implements:

- default-drop behavior on the DPU path,
- health-gated steering rules,
- and no alternate bypass route from the sandbox VF to the uplink.

It is not an automatic property of using OVS or a VF representor.

### 4. `0.0.0.0/0:443` interception is too coarse

The proposed Phase 5c task to redirect all `:443` traffic to the proxy is too broad to serve as the design primitive.

It leaves open several questions:

- how destination identity is determined,
- how DNS is handled,
- how non-HTTPS or non-443 flows are classified,
- how SNI-less traffic is treated,
- how direct mode differs from managed proxy mode.

The spec needs a destination-classification strategy, not just a port-443 redirection rule.

### 5. The hardware setup script is too environment-specific to adopt as-is

The included script is useful as a sketch, but it is not safe as a general "begin here" artifact because it hardcodes assumptions:

- PCI addresses,
- VF numbering,
- device reset behavior,
- VFIO binding flow,
- and host-side `mlxconfig` usage.

A production-worthy next step should start with a preflight checklist, not a mutable script that may disrupt the control plane.

### 6. DNS snooping is helpful but not sufficient on its own

The newer Gemini draft improves the destination-classification story by introducing DNS snooping. That is directionally useful, but it should not be treated as a complete answer by itself because:

- clients may use cached DNS,
- DNS TTLs and rebinding matter,
- DNS over HTTPS or alternate resolvers may bypass simple observation,
- and hostname identity still benefits from SNI or explicit proxy metadata when available.

The best use of DNS in MVP is as one input into destination classification, not the only one.

### 7. Some protocol details are still more specific than the spec can safely assume

The newer Gemini draft introduces a hardware-backed certificate in a secure element and a precise `ValidUntil` policy contract.

The `ValidUntil` concept is good and worth keeping.

The secure-element statement is deployment-specific and should stay optional unless the team already knows that exact hardware-backed identity path is available and required in the target environment.

## Best merged solution

The best version combines Gemini's framing with the stricter implementation boundaries already in this repo.

### Product position

- Use "Project Aegis" as an optional codename if desired.
- Keep the core value proposition: move enforcement beyond the host OS.
- Describe direct protected egress as zero-config.
- Describe credential injection as opt-in managed-provider proxy mode.

### Security position

- Promise DPU-enforced egress, fail-closed policy TTLs, DPU-side audit, and DPU-resident secrets for supported managed routes.
- Do not promise host-compromise-proof binary identity in MVP.
- Do not promise transparent TLS MITM for arbitrary traffic in MVP.

### Technical position

- Separate `direct` mode from `managed_proxy` mode.
- Make compiled policy and sandbox-to-VF binding first-class contracts.
- Treat destination classification and deployment prerequisites as first-order work items.

## What should happen next

Binary identity should not be the next section expanded.

The next blocker is the first end-to-end protected egress slice:

1. Bind one sandbox to one VF.
2. Map VF identity to sandbox identity on the DPU.
3. Fetch and compile policy from OpenShell.
4. Allow one approved destination and deny one unapproved destination.
5. Emit DPU-side audit for both outcomes.
6. Prove fail-closed behavior after policy TTL expiry.

If that slice works, the architecture has proven its main claim. After that, the next major addition should be managed-provider proxy mode for one provider. Binary identity can follow once the team chooses a real attestation strategy.

## Recommendation on the Gemini draft

Adopt:

- the codename,
- the concise pitch,
- the stronger sense of phase-based execution,
- the operator-friendly zero-config goal for direct mode,
- the dual-homed pilot plumbing model,
- and the policy-validity window concept.

Do not adopt without revision:

- REQ-03 as written,
- transparent TLS MITM as a default assumption,
- "proxy dies, hardware drops" as an unqualified statement,
- the hardcoded provisioning script as a canonical next step.

## Suggested replacement language for the risky claims

Instead of:

- "The system must distinguish between `claude` and `curl` even if the host attempts to spoof the process."

Use:

- "The MVP may record host-supplied binary metadata for audit, but policy enforcement will not rely on binary identity until an attestation-backed mechanism is implemented."

Instead of:

- "The DPU proxy performs a transparent TLS MITM."

Use:

- "The MVP supports two paths: direct DPU-enforced egress for destination control, and an opt-in managed-provider proxy mode for routes that require DPU-resident credentials and an explicit client trust model."

Instead of:

- "If the proxy dies, the hardware drops the packets."

Use:

- "Protected mode is designed to fail closed, but this requires explicit default-drop and health-gated steering rules on the DPU path."
