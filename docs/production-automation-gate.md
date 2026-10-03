# Production policy gate safety and scope

Run from the repository root:

```sh
just wasm
python3 scripts/internal/test-production-automation-faults.py
env -u CONTINUUM_BASELINE_WASM python3 scripts/internal/test-production-automation.py
CONTINUUM_BASELINE_WASM=/path/to/pre-policy.wasm python3 scripts/internal/test-production-automation.py
```

The integration gate exclusively creates a random-name Docker container with a
random ownership label, an ephemeral loopback port, and read-only WASM mounts.
It does not use existing servers, credentials, Docker volumes, or databases.
Every subprocess has a 45-second deadline; interrupted/timed-out subprocess
groups receive TERM then KILL with bounded two-second waits. HTTP requests have
30-second limits (one second during the 15-second readiness window).

SIGINT and SIGTERM unwind into `finally`. During bounded cleanup, additional
interrupts are ignored. Cleanup inventories the exact random name, verifies its
nonce label, removes only its full container ID, and verifies absence. Inventory,
removal, or verification failure exits nonzero with disposal **unverified**.
PASS is emitted only after both contract checks and cleanup succeed. No command
argv, captured command output, bearer token, raw exception, or HTTP error body
is printed on failure. A cleanup failure requires operator investigation; the
gate never substitutes a broad removal command or claims cleanup succeeded.

Audit assertions compare event IDs before and after each policy write and
require exactly one new event with the exact action, resource, target (sets),
and authenticated caller. Earlier membership-grant events cannot satisfy them.
Negative reducer calls require HTTP 530 and the exact authorization or target
validation message; transport, parsing, traps and unrelated errors fail closed.
Non-member, invalid-target and revoked-operator checks compare unchanged intent
and audit state, with clock/order checks as applicable.

The backend-free fault suite covers subprocess timeout/reaping, secret-free
nonzero/timeout diagnostics, SIGINT/SIGTERM during an active subprocess, cleanup
inventory/removal/verification failures, ownership mismatch, audit false
positives and rejection-class false positives. It starts only owned temporary
Python processes and mocks Docker; it never contacts a database.

## Follow-up verification on `257d06c`

Rebuilt candidate WASM SHA-256:
`4d94ac8d82d156bcfbef7fa188490e5da57297b193c4512435a0b18db56592cc`.
The genuine pre-policy artifact built from `d14f89af` has SHA-256
`83ac103f6ca60e76cb287fc6359ae4eef425740872cd7c078940a92785a03d72`.
The migration command used:

```sh
CONTINUUM_BASELINE_WASM=/tmp/opencode/continuum-connected-review-fv7v4x4l/baseline-target/wasm32-unknown-unknown/release/continuum_module.wasm python3 scripts/internal/test-production-automation.py
```

Fresh and genuine additive runs passed after the fixes. Eight backend-free fault
tests passed. Separate real-server interruption probes delivered SIGINT and
SIGTERM immediately after publishing/pausing each exclusively owned server:
both exited 1, emitted no PASS, and independent Docker inventory confirmed each
recorded container absent. Final inventory found no production-gate containers.
The parent live QA server on port 45053 was not contacted.

This gate proves reducer/persistence contracts, not target suspension/resume
gameplay, client subscriptions, multiplayer concurrency, or durable server
restart. Additive migration compares six legacy table snapshots: config, colony,
work_order, tile, colonist, item_stack. Same-candidate republish checks policy
durability, and scheduled load/save checks policy/order intent preservation;
neither is claimed as a full authoritative-state or runtime-restart comparison.
