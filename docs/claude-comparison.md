# Claude Comparison: Unified Draft

Status: Draft  
Last updated: 2026-04-10

## Overall verdict

Claude's draft is effectively the current baseline. It does not materially change the architecture, scope, trust model, or implementation priorities already captured in this repository.

That is a good outcome.

It means the strongest cross-model result so far is convergence on the same core design:

- DPU-enforced protected egress,
- deny-by-default plus fail-closed policy handling,
- DPU-resident managed-route secrets,
- explicit separation of direct mode and managed-provider proxy mode,
- and deferral of strong binary identity and universal TLS interception.

## What Claude adds

Very little that is new.

The draft appears to preserve the same:

- executive framing,
- MVP boundaries,
- direct-mode versus managed-proxy split,
- policy-validity model,
- rollout phases,
- and first implementation slice.

## What Claude gets right

### 1. Security realism

Claude keeps the most important trust-boundary discipline:

- no overclaim around binary identity,
- no universal transparent MITM promise,
- no fallback to weaker host-side enforcement in protected mode.

### 2. MVP discipline

Claude preserves the narrow first slice that actually proves value:

1. one sandbox,
2. one VF,
3. one policy pull,
4. one allow,
5. one deny,
6. DPU-side audit,
7. fail-closed behavior.

### 3. Good implementation posture

Claude keeps the useful later refinements:

- dual-homed pod plumbing as a recommendation,
- policy heartbeats with a validity window,
- DNS as one classification input rather than the whole answer.

## What Claude does not change

- It does not introduce a stronger binary identity mechanism.
- It does not solve the trust model for generic TLS interception.
- It does not materially refine the rollout beyond the current baseline.
- It does not change the protobuf-contract-first implementation direction.

## Recommendation

Treat the Claude result as validation, not as a competing design.

Compared with the other external drafts:

- it is stronger than Grok on realism,
- at least as strong as the best Gemini revision,
- and closest to the current baseline in both language and architectural judgment.

## What to do next

Do not spend more time merging documents that say the same thing.

The highest-value next step is implementation:

1. scaffold `host/`, `dpu/`, and `tests/`,
2. anchor them on the existing proto contracts,
3. build the first protected egress slice end to end.
