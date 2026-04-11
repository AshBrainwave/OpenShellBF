# Proto Contracts

These protobuf files are the first implementation artifact for the MVP.

They are intentionally narrow:

- `compiled_policy.proto` defines what the DPU actually enforces.
- `audit_event.proto` defines the minimum structured events required for trust and operations.
- `sandbox_binding.proto` defines the identity bridge between the host orchestrator and the DPU.

The goal is to keep host code, DPU code, and tests aligned on a single contract before the implementation branches into separate services.
