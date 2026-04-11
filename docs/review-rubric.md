# Review Rubric: Comparing Agent-Generated Designs

Use this when comparing this design package against another agent's output.

## Scoring dimensions

Score each dimension from 1 to 5.

| Dimension | What good looks like |
| --- | --- |
| Security realism | The design does not overclaim around TLS interception, binary identity, or host bypass resistance |
| Trust-boundary clarity | It is obvious what is trusted, what is not, and what assumptions must hold in deployment |
| MVP discipline | The first release is narrow, testable, and shippable |
| Technical specificity | APIs, control flow, failure handling, and data structures are concrete enough to build |
| Operational readiness | Provisioning, rollback, audit, health, and rollout states are described |
| Validation quality | The plan includes integration and adversarial testing, not just architecture diagrams |

## Comparison questions

1. Does the design separate "on-path through the DPU" from "fully hardware-offloaded"?
2. Does it explain how HTTPS credential injection would actually work?
3. Does it avoid treating host-asserted binary metadata as strong identity?
4. Does it specify fail-closed behavior when policy or the DPU becomes unavailable?
5. Does it identify the smallest end-to-end slice that proves value?
6. Does it define what the MVP will not do?
7. Does it separate zero-config protected egress from routes that require explicit proxy or trust-bundle support?
8. Does it avoid fallback paths that weaken the protected-mode trust boundary?

## Quick verdict template

```text
Stronger than baseline:
- ...

Weaker than baseline:
- ...

Ideas worth merging:
- ...

Claims that need evidence:
- ...
```
