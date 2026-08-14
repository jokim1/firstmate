# Playbot lanes (experimental)

Playbot lanes are an experimental Firstmate backend plus an optional read-only MCP cockpit, designed by plan v3 (`data/lanemcp-impl-plan/report.md`, captain-private).
This page documents the additive tracked components and their current behavior.
The backend is registered spawn-capable in `bin/fm-backend.sh`.
Live mutation paths call `bin/fm-playbot-lanes.mjs` and refuse with `PHASE1-EVIDENCE-REQUIRED` until the Phase 1 disposable smoke has recorded verified per-operation evidence for the live Playbot release.
The courier remains available as an independent delivery path.

## Components

- `bin/fm-playbot-lanes.mjs` - topology/rollout client, compatibility manifest and doctor, mutation IPC, Phase 1 smoke recorder, content-addressed stdio MCP server, controller lease validation, lock-owner setup CLI, and dispatch-transaction record writers.
- `bin/backends/playbot.sh` - the `fm_backend_playbot_*` adapter interface the shared-core seam dispatches to.
- `bin/fm-playbot-reconcile.mjs` - durable completion reconciliation driven only by the registered per-task custom check.
- `.agents/skills/playbot-lanes/SKILL.md` - the agent operating procedure.
- `docs/verification/playbot-lanes.md` - the verification record.
- `docs/verification/playbot-mutation-evidence/` - smoke-written, content-hash-bound mutation evidence overlay (see below).

## Trust boundaries

Every CDP endpoint, WebSocket frame, SQLite row, and rollout line is untrusted input.
Playbot's loopback DevTools surface is unauthenticated to same-UID processes, so controller chat contents are untrusted even when the lane MCP is exact.
Databases are opened read-only through fixed allowlisted topology queries, and the application settings table is never read.
Worker output is bounded, JSON-escaped, labelled `untrusted-worker-data`, and never becomes controller user input or wake payload text.
The MCP exposes four read-only tools at most (`health`, `identify_controller`, `get_task_status`, `read_task_result`); dispatch, steering, acknowledgement, archive, and install are deliberately not MCP tools.

## Mutation evidence and the Phase 1 smoke

The compatibility seed in `bin/fm-playbot-lanes.mjs` carries read-only schema and IPC string facts for proven releases (including `0.90.0` and `0.92.0`).
Per-operation `mutationEvidence` starts at `PHASE1-EVIDENCE-REQUIRED`.
Only the `smoke` command may extend the overlay under `docs/verification/playbot-mutation-evidence/`:

- each evidence record is a dated JSON file under `records/<release>/<smokeRunId>/`;
- `overlay.v1.json` atomically points to one versioned publication whose overlay body stores relative evidence pointers plus `contentSha256`;
- the smoke-only publisher writes a signed receipt binding the overlay digest, record digest root, release, disposable-project identity, and current lanes-script digest;
- each smoke writes a complete versioned publication directory, then atomically replaces the pointer file;
- `loadCompatibilityManifest` resolves that pointer and verifies the receipt, pinned signer, script digest, and every pointed file, refusing coordinated edits and mismatched bodies (the op stays refused).

The receipt prevents ordinary overlay/record editing and use of the test publisher against the production evidence root. It does not create a privilege boundary against a same-UID operator who can modify the smoke program and use the configured signing key; live smoke provenance remains an operator-controlled trust boundary.

```sh
# Operator-only live command (not a CI step). Requires an idle Playbot, no courier-run.py driver,
# and targets only the registered disposable project project_07474ac1d119.
bin/fm-playbot-lanes.mjs smoke --json
```

The smoke creates a disposable non-MAIN workspace and thread on that project only, exercises create / openThread / send / stop / archiveThread / delete, runs the confinement probe, archives the thread, deletes the workspace, verifies both are absent (fail-closed on ambiguity), and writes the overlay.
It never targets MAIN `ws_00159507e225` or any pre-existing non-smoke workspace.

## Confinement gate-8 re-scope

Authoritative rationale: `data/fm-playbot-phase1-smoke/report.md#gate-8-confinement-re-scope` (captain-private).

Operator contract: write denial must be explicitly proved; read allowance does not block native operation when write denial is proved. Ambiguous evidence blocks native operation.

## Operating states

- `phase1-evidence-required` - missing or unverified mutation evidence for required ops, or missing confinement record.
- `courier-only-confinement` - confinement write denial failed; native workers stay disabled for that release.
- `native-enabled` - verified evidence for create, openThread, send, stop, archiveThread, and delete, plus confinement write denial.

## Operator commands

```sh
bin/fm-playbot-lanes.mjs doctor --json [--thread-id <exact-thread>]
bin/fm-playbot-lanes.mjs ready --json --capability <read-only|native|courier>
bin/fm-playbot-lanes.mjs resolve --thread-id <exact>
bin/fm-playbot-lanes.mjs completion --thread-id <exact>
bin/fm-playbot-lanes.mjs task-status <task-id>
bin/fm-playbot-lanes.mjs smoke --json
bin/fm-playbot-lanes.mjs create --project-id <id> --project-root-id <id> --branch <slug> --base-ref <ref> --expected-commit <sha>
bin/fm-playbot-lanes.mjs open-thread --workspace-id <id> [--thread-id <native-id>]
bin/fm-playbot-lanes.mjs send --thread-id <id> --text <text>
bin/fm-playbot-lanes.mjs stop --thread-id <id>
bin/fm-playbot-lanes.mjs archive --thread-id <id>
bin/fm-playbot-lanes.mjs delete --workspace-id <id>
```

Exact CLI flags and error exits are owned by `bin/fm-playbot-lanes.mjs --help`.
Live Playbot paths default to the standard macOS install locations and every one has an `FM_PLAYBOT_*` environment override used by the hermetic test fixtures.

## Verification

The hermetic suite (`tests/fm-playbot-lanes.test.sh`, `tests/fm-playbot-backend.test.sh`, `tests/fm-playbot-reconcile.test.sh`, fixtures under `tests/playbot-fixtures/`) is green without a live Playbot and covers gating, evidence integrity, shape parsing, forged-completion, size-cap, wedge-timer, and concurrent-check regressions.
Current evidence and live gate results are recorded in `docs/verification/playbot-lanes.md`.
