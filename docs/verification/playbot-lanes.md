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

- doctor fails closed on an unknown release and on a malformed schema, and always reports `mutationsEnabled: false` in this phase.
- every mutation CLI and adapter function refuses with `PHASE1-EVIDENCE-REQUIRED` before any IPC call.
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

## Pending live evidence (Phase 1 gate)

The following remain unproved and keep every mutation path refused:

1. `workspace:create` exact payload/result and fresh non-MAIN worktree creation.
2. Native thread ID minting and exact session attachment.
3. `threads:send` submission versus persisted acceptance versus worker start, including busy-queue delivery across a restart (V2SIM-7).
4. `threads:stop` targeting the exact current turn.
5. Archive/delete result shapes and safe cleanup.
6. Restart reconciliation without duplicate mutation.
7. The confinement negative test (failure yields the supported `courier-only-confinement` state).
8. Per-thread MCP process identity (gates the Phase 3 cockpit's task-data tools).

Refresh this record after each phase gate and after every Playbot release's read-only compatibility run.
