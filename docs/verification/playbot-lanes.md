# Playbot lanes verification

Active guarantees for the additive Playbot lane components (`bin/fm-playbot-lanes.mjs`, `bin/backends/playbot.sh`, `bin/fm-playbot-reconcile.mjs`).
Design contract: plan v3 (`data/lanemcp-impl-plan/report.md`, captain-private).

## Hermetic suite (current)

Date: 2026-08-14
Host: macOS, Node v26.5.0, no live Playbot interaction of any kind.

```text
node --check bin/fm-playbot-lanes.mjs
node --check bin/fm-playbot-reconcile.mjs
bash -n bin/backends/playbot.sh
bash tests/fm-playbot-lanes.test.sh
bash tests/fm-playbot-backend.test.sh
bash tests/fm-playbot-reconcile.test.sh
```

Result: all three suites pass (last lines `fm-playbot-lanes: all tests passed`, `fm-playbot-backend: all tests passed`, `fm-playbot-reconcile: all tests passed`).

Covered guarantees:

- doctor fails closed on an unknown release and on a malformed schema, and reports `mutationsEnabled: false` until verified smoke evidence exists.
- every mutation CLI and adapter function refuses with `PHASE1-EVIDENCE-REQUIRED` before any IPC call when evidence is absent or hash-mismatched.
- smoke-written mutation evidence has a signed receipt binding the overlay, record-root, release, disposable-project identity, and lanes-script digest; hand-edited overlay/record pairs stay refused; write-denial failure yields `courier-only-confinement`.
- confinement evidence requires exact paired runtime tool-call records for both attempts; worker-authored prose or files and absence of a write artifact alone cannot enable native operation.
- strict per-line JSONL rollout parsing rejects a forged `task_complete` embedded in worker-controlled text (V2SIM-3).
- the outbox state machine is replay-safe (`pending` reprints without a queued key, stays silent with one, and only the recorded live lock owner can acknowledge).
- the reconciler touches `state/<id>.turn-ended` for each newly completed turn and never otherwise (amendment 1A wedge-timer regression; the watcher half is covered by the unchanged `tests/fm-watch-triage.test.sh` suite).
- a worker result over 32 KiB is copied with `truncated=true` plus the full-source hash; a scout report over 1 MiB produces a static failure event with no truncated copy (amendment 4A).
- the CDP transport rejects every pending request on close, error, and timeout, skips dead targets, and serializes channel/payload only as JSON inside the fixed invoke bridge.
- the MCP server exposes `health` only until per-thread caller identity is proven, denies task-data tools with the phase marker, and exposes no mutation tools.
- concurrent registered checks collapse onto one outbox event set through the per-task lock in the generated wrapper.

## Phase 0 live gate (read-only, already recorded)

The live Playbot 0.90.0 read-only compatibility gate passed on 2026-08-13; the full evidence is retained captain-privately at `data/playbot-lanes-lab/evidence/live-gate-2026-08-13.json` with the report at `data/playbot-phase0-lab/report.md`.
The compatibility manifest embedded in `bin/fm-playbot-lanes.mjs` carries that proven 0.90.0 shape.

## Phase 1 mutation evidence

The landed smoke command (`bin/fm-playbot-lanes.mjs smoke`) records per-operation evidence under `docs/verification/playbot-mutation-evidence/`.
IPC request/result shapes are frozen by the private phase1 smoke report; restart/V2SIM-7 delivery proof remains in that private lab evidence and is not re-required for overlay flips of the mutation ops that enable spawn/steer/observe.
Confinement follows the gate-8 re-scope in `docs/playbot-lanes.md#confinement-gate-8-re-scope`.
Per-thread MCP process identity remains unproved and continues to gate Phase 3 task-data tools only.

Refresh this record after each smoke run and after every Playbot release's read-only compatibility run.

## Phase 1 live smoke (2026-08-14 / 2026-08-15)

Host: macOS, Playbot 0.92.0, disposable project `project_07474ac1d119` only.
Command: `node bin/fm-playbot-lanes.mjs smoke --json`
Smoke run id: `2026-08-15T08-19-52-693Z` (bound to the lanes script at `8890285b`).
Result: `operatingState: native-enabled`, confinement `readAllowed=true` / `writeDenied=true` via fixed worktree probe scripts + structured tool proof.

Post-smoke:

```text
node bin/fm-playbot-lanes.mjs doctor --json
# appVersion 0.92.0, operatingState native-enabled, readOnlyReady true, mutationsEnabled true

node bin/fm-playbot-lanes.mjs ready --json --capability native
# ready true, operatingState native-enabled, mutationsEnabled true, reason null
```

Disposable workspace/thread created by the smoke were archived/deleted and verified absent; MAIN and the pre-existing ground-tile worktree were not targeted.
