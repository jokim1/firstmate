# Playbot lanes verification

Active guarantees for the additive Playbot lane components (`bin/fm-playbot-lanes.mjs`, `bin/backends/playbot.sh`, `bin/fm-playbot-reconcile.mjs`).
Design contract: plan v3 (`data/lanemcp-impl-plan/report.md`, captain-private).

## Hermetic suite (current)

Date: 2026-09-10
Host: macOS, Node v26.5.0, no live Playbot interaction of any kind.

```text
node --check bin/fm-playbot-lanes.mjs
node --check bin/fm-playbot-reconcile.mjs
bash -n bin/backends/playbot.sh
bash -n bin/fm-spawn.sh
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
- a fake Playbot snapshot/response IPC server proves an allow-listed in-worktree command is session-approved, while an out-of-worktree write and unknown network request stay pending with one journal record and one `blocked:` status.
- repeat reconciliation answers and journals one unchanged request only once, and a known-safe Playbot asset-generation elicitation passes through `threads:respondToMcpElicitation` with session persistence.
- the approval responder processes at most four new requests per poll, denies unknown user-input and MCP requests by default, and exposes only the three approved response operations.
- the MCP server exposes `health` only until per-thread caller identity is proven, denies task-data tools with the phase marker, and exposes no mutation tools.
- concurrent registered checks collapse onto one outbox event set through the per-task lock in the generated wrapper.
- release-aware wire contracts resolve thread-open and workspace-create to `threads:launch` (app-minted `chat-*` id, fused create) on `0.94.0`, `0.101.0`, and `0.104.0`, keep the legacy channels for `0.93.1` and unknown releases, and assert a static IPC surface for those fused releases that includes snapshot plus approval responses while omitting the removed `workspace:create` / `threads:openThread` / `db:workspaceThreads:open` channels.
- on the fused releases, `open-thread` refuses a caller-chosen thread id before any IPC call, and the fused create keeps polling until the provisioned workspace row carries a non-empty worktree path (an empty path times out instead of being adopted).
- the spawn dirt gate accepts only a clean worktree or Playbot's known Godot injection while preserving and refusing every unrelated dirty path.
- the Playbot build-thread launch boundary retains approval mode `default` so the confinement write-denial stays enforceable, while the reconciler answers only policy-approved pending requests and an explicit task effort passes through the initial `threads:send` request unchanged.
- a fresh Playbot spawn binds mode and yolo in its transaction, preserves its published task record, commits its backlog row to In flight through the shared final commit, and installs the hash-bound reconciliation check; a failed final backlog transition retires the unowned worker and removes provisional state.
- a same-id `worker-started` transaction recovery requires the recorded project binding and delivery posture, restricts legacy posture-free records to local-only/yolo-off, validates the recorded live endpoint, republishes its workspace, thread, and worktree with a refreshed bound route, commits the backlog row, preserves worker edits, and makes no workspace-create, thread-open, or brief-send call.
- a refused or failed recovery preserves the existing worker and transaction plus any wiring it did not replace, while a final backlog failure removes only route/check/trust artifacts created by that recovery attempt and reports the exact-command retry path.
- `validateThreadLaunchResult` rejects a missing or non-`chat-` thread id, a wrong-workspace binding, an existing-workspace launch that created a workspace, and a new-workspace launch that did not report `createdWorkspace`.
- the doctor's static IPC scan matches channel needles as exact bounded tokens (an event string such as `workspace:created` cannot satisfy the `workspace:create` needle), while the generic preload-bridge scan keeps substring matching.

## Phase 0 live gate (read-only, already recorded)

The live Playbot 0.90.0 read-only compatibility gate passed on 2026-08-13; the full evidence is retained captain-privately at `data/playbot-lanes-lab/evidence/live-gate-2026-08-13.json` with the report at `data/playbot-phase0-lab/report.md`.
The compatibility manifest embedded in `bin/fm-playbot-lanes.mjs` carries that proven 0.90.0 shape.

## Phase 1 mutation evidence

The landed smoke command (`bin/fm-playbot-lanes.mjs smoke`) records per-operation evidence under `docs/verification/playbot-mutation-evidence/`.
Legacy (`<=0.93.1`) IPC request/result shapes are frozen by the private phase1 smoke report, and the release-aware `0.94.0` / `0.101.0` / `0.104.0` `threads:launch` contract is owned by the compatibility seed in `bin/fm-playbot-lanes.mjs`; restart/V2SIM-7 delivery proof remains in that private lab evidence and is not re-required for overlay flips of the mutation ops that enable spawn/steer/observe.
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

## Phase 1 live smoke (2026-08-27, Playbot 0.101.0)

Host: macOS, Playbot 0.101.0, disposable project `project_07474ac1d119` only.
Installed `app.asar` SHA-256: `4f9206bbb335e892868975b228264728985917ea392956a87a158113f678291a`.
Read-only bundle inspection found every `0.94.0` lane channel as an exact token and found none of the removed `workspace:create`, `threads:openThread`, or `db:workspaceThreads:open` channels.
The `threads:launch` request still selects a `new-workspace` or `existing-workspace` destination and returns the app-minted `{ workspace, thread, selectedWorkspaceId, activate, createdWorkspace }` result shape.
Playbot's new multi-agent orchestration enables Codex `multi_agent` / `multi_agent_v2`, routes child `thread/started` and agent activity through the parent thread, and exposes child-history hydration through `threads:fetchSubAgentThread`; those additions do not replace any native-lane mutation dependency.
Command: `bin/fm-playbot-lanes.mjs smoke --json`
Smoke run id: `2026-08-27T16-27-32-783Z`.
Result: `operatingState: native-enabled`; confinement `readAllowed=true` / `writeDenied=true` via the fixed worktree probe with structured tool proof.
The fused `threads:launch` created workspace `ws_3485095685dc` and app-minted thread `chat-424d59ee-c41e-4393-b6d0-e2b84d2e5944` only under the disposable project.
Post-smoke database and filesystem checks found that workspace, thread, and worktree absent while MAIN `ws_00159507e225` remained active and local.
Post-smoke `doctor --json` and `ready --json --capability native` both report `ready=true`, `operatingState=native-enabled`, and `mutationsEnabled=true`.
The signed publication preserves earlier releases and verifies 28 scopes with zero refusals.

## Phase 1 live smoke (2026-09-04, Playbot 0.104.0)

Host: macOS, Playbot 0.104.0, disposable project `project_07474ac1d119` only.
Installed `app.asar` SHA-256: `3facfec8068c0efd5c911a1b2e81d3037c3969df4e6600edeb98a694ebdbd099`.
Read-only bundle inspection found every fused-lane channel as an exact token and found none of the removed `workspace:create`, `threads:openThread`, or `db:workspaceThreads:open` channels.
The `threads:launch` request still selects a `new-workspace` or `existing-workspace` destination and returns the app-minted `{ workspace, thread, selectedWorkspaceId, activate, createdWorkspace }` result shape.
Additive multi-agent surfaces (`multi_agent` / `multi_agent_v2`, `threads:fetchSubAgentThread`) remain present and do not replace a native-lane mutation dependency.
Command: `bin/fm-playbot-lanes.mjs smoke --json`
Smoke run id: `2026-09-04T09-52-57-857Z` (receipt bound to the lanes script at `328ba246`).
Result: `operatingState: native-enabled`; confinement `readAllowed=true` / `writeDenied=true` via the fixed worktree probe with structured tool proof.
The fused `threads:launch` created workspace `ws_61230b4ed186` and app-minted thread `chat-09048ddd-95b5-4eb5-9f63-3c814ecfba66` only under the disposable project.
Post-smoke database and filesystem checks found that workspace, thread, and worktree absent while MAIN `ws_00159507e225` remained active and local.
Post-smoke `doctor --json` and `ready --json --capability native` both report `ready=true`, `operatingState=native-enabled`, and `mutationsEnabled=true`.
The signed publication preserves earlier releases and verifies 35 scopes with zero refusals.

## Static contract re-assessment (2026-09-07, Playbot 0.106.0, no live smoke)

Playbot 0.106.0 was assessed read-only against the same fused-lane contract before the pin advanced to 0.107.0, so it is carried as a static-contract manifest entry with no live smoke of its own.
Installed `app.asar` SHA-256 at that assessment: `28498b583945bd6c87830b7309bb3336655704035205c0a54afc0cde1cfef580`.
Bundle inspection found every fused-lane channel as an exact token and none of the removed `workspace:create`, `threads:openThread`, or `db:workspaceThreads:open` channels; the `threads:launch` payload `{ destination, thread, message?, activate? }` and result `{ workspace, thread, selectedWorkspaceId, activate, createdWorkspace }` shapes were unchanged from 0.104.0.
The live mutation evidence for the installed host is the 0.107.0 smoke below; 0.106.0's manifest entry certifies only its static schema/IPC contract.

## Phase 1 live smoke (2026-09-09, Playbot 0.107.0)

Host: macOS, Playbot 0.107.0, disposable project `project_07474ac1d119` only.
Installed `app.asar` SHA-256: `73e16bfeca6cfebafbac96c0f4e436b6524f5799e4ac0f164fab33470b2a2a2e`.
Read-only bundle inspection found every fused-lane channel as an exact token and found none of the removed `workspace:create`, `threads:openThread`, or `db:workspaceThreads:open` channels.
The `threads:launch` request still selects a `new-workspace` or `existing-workspace` destination and returns the app-minted `{ workspace, thread, selectedWorkspaceId, activate, createdWorkspace }` result shape.
0.107.0 introduces the GPT 6 Astra execution model (`gpt-6-astra`) as the default and carries per-thread `executionModel` / `executionReasoningLevel` / `planningModel` / `planningReasoningLevel` selection fields; the `threads:launch` payload carries no model field, so these additive model-selection surfaces do not replace a native-lane mutation dependency.
Command: `bin/fm-playbot-lanes.mjs smoke --json`
Smoke run id: `2026-09-09T04-31-32-470Z` (receipt bound to the lanes script at sha256 `9fe6459cef395d7ffdc0a28dfe23f5b439c563f0c9ffecc825d805f022dafa37`).
Result: `operatingState: native-enabled`; confinement `readAllowed=true` / `writeDenied=true` via the fixed worktree probe with structured tool proof.
The fused `threads:launch` created workspace `ws_2c997b779e23` and app-minted thread `chat-172f566b-8065-4ba1-b3fc-7dd6a7313af9` only under the disposable project.
Post-smoke database and filesystem checks found that workspace, thread, and worktree absent while MAIN `ws_00159507e225` remained active and local.
Post-smoke `doctor --json` and `ready --json --capability native` both report `ready=true`, `operatingState=native-enabled`, and `mutationsEnabled=true`.
The signed publication preserves earlier releases and verifies 42 scopes with zero refusals.
