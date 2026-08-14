# Playbot lanes (experimental, Phase-1-gated)

Playbot lanes are an experimental Firstmate backend plus an optional read-only MCP cockpit, designed by plan v3 (`data/lanemcp-impl-plan/report.md`, captain-private).
This page documents the additive tracked components and their current behavior.
The backend is **not spawn-capable**: every mutation path refuses with `PHASE1-EVIDENCE-REQUIRED` until the supervised Phase 1 disposable smoke records live evidence on Playbot 0.90.0 for macOS.
The courier remains the production Playbot delivery path.

## Components

- `bin/fm-playbot-lanes.mjs` - read-only topology/rollout client, compatibility manifest and doctor, content-addressed stdio MCP server, controller lease validation, and the lock-owner setup CLI (`bind-project`, `bind-controller`).
- `bin/backends/playbot.sh` - the `fm_backend_playbot_*` adapter interface the shared-core seam dispatches to; read-only operations work today, mutation operations refuse.
- `bin/fm-playbot-reconcile.mjs` - durable completion reconciliation driven only by the registered per-task custom check; owns the outbox state machine and the `state/<id>.turn-ended` touch.
- `.agents/skills/playbot-lanes/SKILL.md` - the agent operating procedure.
- `docs/verification/playbot-lanes.md` - the verification record.

## Trust boundaries

Every CDP endpoint, WebSocket frame, SQLite row, and rollout line is untrusted input.
Playbot's loopback DevTools surface is unauthenticated to same-UID processes, so controller chat contents are untrusted even when the lane MCP is exact.
Databases are opened read-only through fixed allowlisted topology queries, and the application settings table is never read.
Worker output is bounded, JSON-escaped, labelled `untrusted-worker-data`, and never becomes controller user input or wake payload text.
The MCP exposes four read-only tools at most (`health`, `identify_controller`, `get_task_status`, `read_task_result`); dispatch, steering, acknowledgement, archive, and install are deliberately not MCP tools.

## Current operating states

- `phase1-evidence-required` - the shipped default: read-only doctor and resolution work; every mutation refuses before any IPC call.
- `courier-only-confinement` - the supported terminal state if the Phase 1 confinement negative test fails.
- `native-enabled` - reachable only after the Phase 1 smoke records per-operation evidence into the manifest.

## Read-only operator commands

```sh
bin/fm-playbot-lanes.mjs doctor --json [--thread-id <exact-thread>]
bin/fm-playbot-lanes.mjs ready --json --capability <read-only|native|courier>
bin/fm-playbot-lanes.mjs resolve --thread-id <exact>
bin/fm-playbot-lanes.mjs completion --thread-id <exact>
bin/fm-playbot-lanes.mjs task-status <task-id>
```

`doctor` reports each compatibility and security dimension separately, including the reconcile-liveness latency budget (typical single event about one watcher interval plus the 3-second reconcile deadline; worst case at the four-task cap is cap x interval plus the deadline).
`ready --capability native` exits nonzero until Phase 1 evidence exists.
Live Playbot paths default to the standard macOS install locations and every one has an `FM_PLAYBOT_*` environment override used by the hermetic test fixtures.

## Verification

The hermetic suite (`tests/fm-playbot-lanes.test.sh`, `tests/fm-playbot-backend.test.sh`, `tests/fm-playbot-reconcile.test.sh`, fixtures under `tests/playbot-fixtures/`) is green without a live Playbot and covers the forged-completion, size-cap, wedge-timer, and concurrent-check regressions.
Current evidence and the live Phase 0 gate result are recorded in `docs/verification/playbot-lanes.md`.
