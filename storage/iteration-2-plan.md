# Storage Service Iteration 2 Plan

## Goal

Replace the iteration-1 standalone command executables with one long-running
storage service. The service owns the storage index in memory, avoiding repeated
index serialization and deserialization for every command. An unclean shutdown
requires reconciliation before the service resumes storage operations.

## Service

- Add `service.lua` as the long-running storage executable.
- Load the full index snapshot once at startup and retain it in memory.
- Provide local terminal commands through a REPL: `import`, `get`, `list`,
  `status`, `register`, `reconcile`, and `exit`.
- Use an event-driven input layer rather than blocking `read()`. The service
  must be able to dispatch peripheral, timer, and future network events while
  it is waiting for local input.
- Process one request at a time. Inventory-mutating operations are serialized.
- Retain explicit `import` behavior; inbox changes do not automatically start
  an import.

## Persistence Model

- `index` is the last clean full index snapshot.
- `service.running` is a small lifecycle marker, created at service startup and
  removed only after a successful clean-exit index checkpoint.
- `list` and `status` use in-memory state and do not write to disk.
- `import`, `get`, `register`, and `reconcile` update only in-memory state while
  the service runs.
- On a clean `exit`, atomically save the complete in-memory index and then exit.

## Startup Recovery

1. Load `index`.
2. Treat the loaded index as untrusted when `service.running` exists, because
   the previous service execution did not finish with a clean `exit` checkpoint.
3. Require `reconcile` before accepting storage operations when the index is
   untrusted.

An inventory transfer cannot be atomic with the clean-exit snapshot. If the
computer stops after any in-memory or physical inventory change, the persisted
index may be stale. Startup must require `reconcile` rather than assuming the
index is accurate.

## Command Refactor

- Move reusable operation logic from `import.lua`, `get.lua`, `list.lua`,
  `status.lua`, `register.lua`, and `reconcile.lua` into functions exposed by
  `storage.lua`.
- Have `service.lua` invoke those functions with the shared in-memory index.
- Preserve iteration-1 behavior: query matching, top-match-only export,
  empty-outbox-slot exports, indexed lookup updates, and recovery rules.
- Do not remove iteration-1 executables until the service passes manual testing.

## Lifecycle

- Validate the loaded index and required peripherals before accepting commands.
- `exit` refuses while an operation is active, checkpoints the index, and then
  removes `service.running` before exiting.
- `terminate` is unclean: do not checkpoint. The next service startup requires
  `reconcile` because `service.running` remains.

## Implementation Sequence

### Milestone 1: In-Memory Service Shell

Implement `service.lua` with startup loading, in-memory index ownership, an
event-driven local REPL, `status`, `list`, and clean `exit` checkpointing.
Refactor the existing `status.lua` and `list.lua` executables to retain their
index loading while delegating shared presentation to `storage.printStatus` and
`storage.printList`; the service calls the same functions with its in-memory
index.

### Milestone 2: In-Memory Registration And Reconciliation

Move `register` and `reconcile` into service operations. Verify pool expansion
and reconciliation through the service. Refactor the standalone executables to
load an index, call `storage.register` or `storage.reconcile`, and save only if
the shared operation changed the index or its trust state.

### Milestone 3: In-Memory Import And Export

Move `import` and `get` into service operations. Preserve current indexed slot
updates and require reconciliation after an unclean shutdown.
