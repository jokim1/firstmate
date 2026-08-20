# Playbot lanes verification

Active guarantees for the additive Playbot lane components (`bin/fm-playbot-lanes.mjs`, `bin/backends/playbot.sh`, `bin/fm-playbot-reconcile.mjs`).
Design contract: plan v3 (`data/lanemcp-impl-plan/report.md`, captain-private).

## Hermetic suite (current)

Date: 2026-08-20
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
- release-aware wire contracts resolve thread-open and workspace-create to `threads:launch` (app-minted `chat-*` id, fused create) on `0.94.0`, keep the legacy channels for `0.93.1` and unknown releases, and assert a `0.94.0` static IPC surface that omits the removed `workspace:create` / `threads:openThread` / `db:workspaceThreads:open` channels.
- `validateThreadLaunchResult` rejects a missing or non-`chat-` thread id, a wrong-workspace binding, an existing-workspace launch that created a workspace, and a new-workspace launch that did not report `createdWorkspace`.
- the doctor's static IPC scan matches channel needles as exact bounded tokens (an event string such as `workspace:created` cannot satisfy the `workspace:create` needle), while the generic preload-bridge scan keeps substring matching.

## Phase 0 live gate (read-only, already recorded)

The live Playbot 0.90.0 read-only compatibility gate passed on 2026-08-13; the full evidence is retained captain-privately at `data/playbot-lanes-lab/evidence/live-gate-2026-08-13.json` with the report at `data/playbot-phase0-lab/report.md`.
The compatibility manifest embedded in `bin/fm-playbot-lanes.mjs` carries that proven 0.90.0 shape.

## Phase 1 mutation evidence

The landed smoke command (`bin/fm-playbot-lanes.mjs smoke`) records per-operation evidence under `docs/verification/playbot-mutation-evidence/`.
Legacy (`<=0.93.1`) IPC request/result shapes are frozen by the private phase1 smoke report, and the release-aware `0.94.0` `threads:launch` contract is owned by the compatibility seed in `bin/fm-playbot-lanes.mjs`; restart/V2SIM-7 delivery proof remains in that private lab evidence and is not re-required for overlay flips of the mutation ops that enable spawn/steer/observe.
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

## Phase 1 live smoke (2026-08-19, Playbot 0.93.1)

Host: macOS, Playbot 0.93.1, disposable project `project_07474ac1d119` only.
Command: `node bin/fm-playbot-lanes.mjs smoke --json`
Smoke run id: `2026-08-19T04-09-54-769Z` (receipt bound to the lanes script at `0cdfa1e2`).
The signed publication records evidence for every required operation plus confinement `readAllowed=true` / `writeDenied=true`, preserving the `0.92.0` evidence, so `0.93.1` operates `native-enabled`.

## Phase 1 live smoke (2026-08-20, Playbot 0.94.0)

Host: macOS, Playbot 0.94.0, disposable project `project_07474ac1d119` only.
Command: `node bin/fm-playbot-lanes.mjs smoke --json`
Smoke run id: `2026-08-20T16-17-04-891Z` (receipt bound to the lanes script at `30975d99`).
Result: `operatingState: native-enabled`; confinement `readAllowed=true` / `writeDenied=true` via the fixed worktree probe with structured tool proof.
Because `0.94.0` fuses workspace creation into `threads:launch`, the `workspace:create` and `threads:openThread` records both come from the single fused launch and annotate `wireChannel: threads:launch` (`fused: true` / `fusedWith: workspace:create`, app-minted thread id); the disposable workspace and thread were archived/deleted and verified absent, and MAIN was never targeted.
The `0.92.0` and `0.93.1` evidence is preserved in the same publication.

Overlay integrity re-verified hermetically on 2026-08-20: `loadCompatibilityManifest` with `FM_PLAYBOT_EVIDENCE_ROOT=docs/verification/playbot-mutation-evidence` reports the overlay present, zero refusals, 21 verified scopes, and allowed evidence with `writeDenied=true` for `0.92.0`, `0.93.1`, and `0.94.0`, confirming the committed lanes script matches the receipt's attested digest.
