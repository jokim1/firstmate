# Playbot lanes (experimental)

Playbot lanes are an experimental Firstmate backend plus an optional read-only MCP cockpit, designed by plan v3 (`data/lanemcp-impl-plan/report.md`, captain-private).
This page documents the additive tracked components and their current behavior.
The backend is registered spawn-capable in `bin/fm-backend.sh`.
Live mutation paths call `bin/fm-playbot-lanes.mjs` and refuse with `PHASE1-EVIDENCE-REQUIRED` until the Phase 1 disposable smoke has recorded verified per-operation evidence for the live Playbot release.
The courier remains available as an independent delivery path.

## Components

- `bin/fm-playbot-lanes.mjs` - topology/rollout client, compatibility manifest and doctor, mutation IPC, native approval policy, Phase 1 smoke recorder, content-addressed stdio MCP server, controller lease validation, lock-owner setup CLI, and dispatch-transaction record writers.
- `bin/backends/playbot.sh` - the `fm_backend_playbot_*` adapter interface the shared-core seam dispatches to.
- `bin/fm-playbot-reconcile.mjs` - durable completion and pending-input approval reconciliation driven only by the registered per-task custom check.
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

The compatibility seed in `bin/fm-playbot-lanes.mjs` is the authoritative per-release record of read-only schema, IPC string, and wire-contract facts for proven releases.
Playbot `0.94.0` removed the standalone `workspace:create` and `threads:openThread` channels, and later certified releases retain that contract, so each seed entry also fixes the release's thread-open and workspace-create wire contracts: the abstract operation names and evidence keys stay stable, while on those releases both operations go over `threads:launch` (workspace creation is fused with opening the workspace's first thread, and thread ids are minted by the app) and each evidence record annotates the real wire channel.
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
On a certified release with the fused contract (`0.94.0` and later), the create step already opens the workspace's first thread, so the smoke adopts that thread instead of opening a second one and still records both the `workspace:create` and `threads:openThread` evidence keys from the single launch.
It never targets MAIN `ws_00159507e225` or any pre-existing non-smoke workspace.

## Confinement gate-8 re-scope

Authoritative rationale: `data/fm-playbot-phase1-smoke/report.md#gate-8-confinement-re-scope` (captain-private).

Operator contract: write denial must be explicitly proved; read allowance does not block native operation when write denial is proved. Ambiguous evidence blocks native operation.

Build threads keep Playbot's `default` approval posture and the Codex sandbox.
When reconciliation observes `pending_input`, it reads that exact thread's snapshot and applies the data policy exported as `PLAYBOT_APPROVAL_POLICY`.
The policy session-allows filesystem grants confined to the worktree, the platform Godot user directory, or the uv cache, accepts each validated in-worktree file-change proposal for that request only, and session-allows Playbot asset-generation confirmations whose targets remain in the worktree.
Command escalations are never auto-approved because Playbot runs an approved command outside the Codex sandbox, where Firstmate cannot bound the command or its child effects to the confinement roots.
Command requests, out-of-worktree paths, network approvals, unknown approval methods, arbitrary user input, and unknown MCP elicitations remain pending and append a `blocked:` status for firstmate.
Each new decision is recorded with the bounded request text in the mode-0600 `state/<id>.playbot-approvals.jsonl` journal.
The outbox retains a bounded fingerprint cursor, so an unchanged request is neither answered nor reported twice.
Each poll examines at most four new requests and uses only `threads:respondToApproval` and `threads:respondToMcpElicitation` to answer them.
Those two response operations deliberately do not have separate per-operation mutation-evidence entries.
Before reading or answering a pending request, the responder requires the release's verified `threads:send` evidence and confinement write-denial proof; an uncertified release still refuses with `PHASE1-EVIDENCE-REQUIRED`.
The response calls are limited to request IDs returned by that exact existing thread's snapshot, cannot create or retarget a workspace, and do not change the thread's sandbox posture, so the certified native-thread and confinement gates remain the fail-closed boundary.
The captain's build-thread auto-approve ruling is therefore satisfied for structured filesystem grants, individually validated file changes, and asset elicitations only until Playbot offers a sandbox-preserving command approval kind.
The native responder replaces the prior computer-use approval loop for those safe request kinds without changing launch posture or relaxing gate 8.

## Operating states

- `phase1-evidence-required` - missing or unverified mutation evidence for required ops, or missing confinement record.
- `courier-only-confinement` - confinement write denial failed; native workers stay disabled for that release.
- `native-enabled` - verified evidence for create, openThread, send, stop, archiveThread, and delete, plus confinement write denial.

Native backend dispatch adopts the fused first thread returned by workspace creation and labels it with the task and delivery identity instead of opening a second thread.
Playbot build threads retain the lane's native default approval posture so the disposable-smoke confinement write-denial remains enforceable; the bounded native responder above handles policy-approved requests, and `--yolo` remains the separate merge-authority control.
The initial brief uses the task's recorded effort: an absent effort defaults to `medium`, `low` is refused because `medium` is the floor, and `medium`, `high`, `xhigh`, `max`, and `ultra` pass through unchanged.
Playbot owns workspace creation and base convergence, so spawn preserves its expected app-injected Godot files while refusing unrelated uncommitted work; the [`fm-spawn.sh` header](../bin/fm-spawn.sh) owns the exact fresh-worktree gate.
If a dispatch transaction reached `worker-started` but its task record and backlog transition are missing, rerun the original spawn command to adopt and validate the existing worker without creating or messaging another one; the [`fm-spawn.sh` header](../bin/fm-spawn.sh) owns the exact recovery command, matching rules, and failure cleanup.

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
On the fused `threads:launch` releases (`0.94.0` and later certified), the app mints thread ids, so `create` also reports the fused first thread id and `open-thread` returns the app-minted id.
A caller-chosen `--thread-id` on `open-thread` is rejected on those releases (legacy client-minted releases still accept it).
Live Playbot paths default to the standard macOS install locations and every one has an `FM_PLAYBOT_*` environment override used by the hermetic test fixtures.

## Verification

The hermetic suite (`tests/fm-playbot-lanes.test.sh`, `tests/fm-playbot-backend.test.sh`, `tests/fm-playbot-reconcile.test.sh`, fixtures under `tests/playbot-fixtures/`) is green without a live Playbot and covers gating, evidence integrity, shape parsing, approval response/refusal/idempotence, spawn commit and recovery, forged-completion, size-cap, wedge-timer, and concurrent-check regressions.
Current evidence and live gate results are recorded in `docs/verification/playbot-lanes.md`.
