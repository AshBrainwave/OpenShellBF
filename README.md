# OpenShellBF

OpenShell x BlueField-3

Hardware-enforced security for AI agent runtimes.

This repository starts with a product and technical foundation for an MVP that combines OpenShell's policy model with NVIDIA BlueField-3's hardware-separated enforcement path. The goal is to give any coding agent a clean, rigorous starting point that is strong enough for implementation work and honest about the hard parts.

## Documents

- [Unified spec](./docs/unified-spec.md): the current recommended single-document PRD + technical design spec, now including the v2 implementation appendix
- [PRD](./docs/prd.md): product requirements, scope, users, success metrics, and release criteria
- [Design spec](./docs/design-spec.md): system architecture, trust boundaries, interfaces, threat model, and rollout plan
- [Implementation plan](./docs/implementation-plan.md): phased backlog and concrete next steps
- [Status](./STATUS.md): shared running log for implementation findings, blockers, and next steps
- [Review rubric](./docs/review-rubric.md): a comparison checklist for future design reviews, including side-by-side comparisons with other agent outputs
- [Gemini comparison](./docs/gemini-comparison.md): strengths, gaps, and merge recommendations for the Gemini "Project Aegis" draft
- [Grok comparison](./docs/grok-comparison.md): strengths, gaps, and merge recommendations for the Grok draft
- [Claude comparison](./docs/claude-comparison.md): comparison note for the Claude draft

## MVP thesis

The first release should prioritize four things:

1. Move the enforcement path off the host and onto the DPU.
2. Prefer a microVM-backed sandbox runtime for protected mode.
3. Fail closed when policy or enforcement is unavailable.
4. Keep claims realistic around TLS interception and binary identity.

That means the MVP focuses on microVM-backed protected sandboxes, hardware-separated egress control, live policy sync, DPU-resident secrets, and centralized audit. Advanced features like transparent L7 credential injection for arbitrary HTTPS traffic, attested binary identity, policy-gated storage, and alternate runtime adapters are treated as later phases unless their prerequisites are also delivered.
