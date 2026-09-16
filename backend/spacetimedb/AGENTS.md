# Simulation Guardrails

Read `../../docs/simulation-architecture.md` before changing simulation structure.

- Keep simulation behavior free of database handles, I/O, and Godot types.
- Compose data by capability; do not grow a universal actor struct or inheritance
  hierarchy. Prefer narrow component inputs where shared-world access is not needed.
- Preserve the documented per-actor ordering. Batching or parallelizing systems
  changes gameplay and is not a mechanical extraction.
- Use durable IDs for relationships and events, never collection indices or ECS
  runtime handles. Do not derive persisted IDs from enum/list length.
- Keep component representation separate from the public/persisted schema.
  Schema changes require an explicit migration decision, not incidental refactoring.
- Do not update golden traces to hide behavior changes. Run `just test`,
  `just fmt-check`, and `just wasm` from the repository root.
