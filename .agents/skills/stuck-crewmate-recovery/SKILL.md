---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Also use when a task has surviving records but no state/<id>.meta, including when bin/fm-status-gc.sh refuses that shape and names candidate records for inspection.
  Also use on the inverse case: a live crewmate reporting the no-mistakes pipeline dead, unreachable, or timed out.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Interrupt, stop, and relaunch a worker through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which resolves the recorded runtime itself, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
That plane covers workers running in this home; a remotely placed secondmate is refused by name and reconciled through `secondmate-provisioning` instead.
Load `harness-adapters` before a resume command or a harness-specific skill invocation, and whenever the adapter's own quirks matter.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

For a REMOTE secondmate, `fm-crew-state` and `fm-peek` read the actual remote endpoint over `fm-on.sh`, and `fm-send` reports a delivered-with-pending-confirmation steer as delivered (their headers own the contracts); an `unknown-remote` read or unreachable-host failure means the remote state could not be read, never that the mate is dead or the send failed.
Recover a genuinely stuck remote mate only through `bin/fm-spawn.sh <id> --secondmate`, never raw herdr pane close/kill surgery, which strands the endpoint binding.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, or cmux tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch the recorded harness in that existing worktree with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Finish a partial teardown after metadata is gone

Use this procedure when a task has surviving records but no `state/<id>.meta`, including when `bin/fm-status-gc.sh <id>` refuses and names candidate records for inspection.
This procedure manages this failure class rather than removing it.
Removing the failure class belongs to separate prevention work.
`bin/fm-status-gc.sh` does not probe backend endpoints and can report success after retiring records whose worker is still running; this defect is tracked as `fm-statusgc-retires-live-endpoint`.
Once metadata is gone, the recorded backend class is gone too, so neither the janitor nor this procedure can machine-prove endpoint death except from a valid version 2 Herdr journal.
For every shape without that journal, require a HUMAN to identify the original backend, inspect every plausible endpoint, and confirm that the worker is gone before any janitor invocation or manual retirement; STOP if the backend or endpoint state cannot be established.
An agent must STOP and escalate the exact endpoint check to its supervising human, then resume only after the human returns the result.
A complete machine-safe remedy requires code for id-keyed endpoint discovery and is outside this documentation-only procedure.
Do not run this procedure while anything might spawn the same task id; if there is any doubt that the id could be respawned, STOP.
A fresh same-id spawn can publish a new registry entry and turn-end token before its metadata appears, making those live records indistinguishable from the dead records this procedure retires.
The registry check can then pass and delete live replacement hook state, and a later GC refusal detects the replacement only after that damage.
Before starting, confirm that `/tmp/fm-<id>` is absent and STOP if it exists.
That temp root is durable evidence that a spawn ran for this id and cleanup never finished, and the janitor's surviving-records refusal can hide it until after a manual retirement.
Immediately before every janitor invocation and every file retirement, re-check that `state/<id>.meta` and `/tmp/fm-<id>` are both absent, repeat the applicable endpoint check, and STOP on any doubt or changed result.

1. Before invoking the janitor or retiring anything, check for every different legal sibling id that becomes the same marker key when `.` and `_` are normalized to `_`.
   Inspect the current backlog, state records, and durable `data/<sibling-id>/` task records for those sibling ids, and STOP if any colliding sibling exists.
   The notification marker families normalize separators, so two legal ids such as `a.b` and `a_b` can alias and cleanup for one can otherwise retire the other's markers.
   Also perform the required endpoint check before invoking the janitor.
   For a valid version 2 Herdr journal, source `bin/fm-backend.sh`, load the Herdr adapter with `fm_backend_source herdr`, validate it with `fm_backend_herdr_projection_journal_snapshot <journal> <id>`, and probe the captured session and pane with `fm_backend_herdr_pane_agent_state <session> <pane>`.
   Proceed only when the probe returns exactly `dead`, retain the validated session and pane for later checks, and STOP on `live`, `no-agent`, `unknown`, version 1, an invalid journal, an unavailable probe, or any other result.
2. After step 1 and the immediate metadata and temp-root re-check, run `FM_HOME=<home> bin/fm-status-gc.sh <id>`.
   The janitor can complete retirement immediately when only its exact leak shape remains, so this first invocation is destructive and must never precede the collision and endpoint checks.
   If it reports successful retirement, the procedure is complete.
   Otherwise retain its complete refusal and treat every named record as a candidate that must be inspected individually before retirement.
   A path in another task's subdirectory may be a false positive caused by active or archived prose that mentions the target id, and correspondence investigating the stranded record can make the refusal stronger by adding more matching prose.
   A `pending-replies/<corr>` record can instead be a genuine task binding and must not be dismissed as a text match.
   This scanner limitation is tracked as `fm-statusgc-scan-matches-message-text`.
   STOP on a task-set lock, a home-wide status id, an unreadable status log, a last line other than `done:` or `failed:`, an unanswered decision, a temp root, or any record family not covered by steps 3 and 4.
3. If the refusal names a Grok or Kimi turn-end token, source `bin/fm-control-lib.sh`, read the token from `state/<id>.<harness>-turnend-token`, and resolve the corresponding firstmate-owned registry entry with `fm_control_harness_turnend_auth_path <harness> <token>`.
   Immediately before retiring any file, repeat step 1's endpoint check and the metadata and temp-root checks above.
   REFUSE if the helper fails or returns no path.
   Require the registry entry's contents to match the canonical absolute `<state>/<id>.turn-ended` path exactly, and REFUSE on a missing, unreadable, or mismatched entry.
   Only after an exact match may the registry entry, the task token, and `state/<id>.turn-ended` be retired.
   The exact-content match proves ownership only, not that the worker is dead, so it never replaces the endpoint check.
   Matching the registry entry's contents is mandatory because trusting the token text alone can deregister a different live task's hook.
   If a prior attempt removed the registry entry but left the token or marker, this runbook cannot safely finish that partially retired shape; STOP and leave the remaining records intact.
4. If the refusal names `state/<id>.herdr-presentation` or the orphan is journal-only, source `bin/fm-backend.sh`, load the Herdr adapter with `fm_backend_source herdr`, and validate the journal with `fm_backend_herdr_projection_journal_snapshot <journal> <id>`.
   If `$FM_BACKEND_HERDR_JOURNAL_VERSION` is `1`, STOP without probing or retiring it because the snapshot leaves the session and pane empty and the probe therefore returns `unknown`.
   This stop is the correct outcome for this manual runbook, which leaves the version 1 journal untouched.
   Probe the validated `$FM_BACKEND_HERDR_JOURNAL_SESSION` and `$FM_BACKEND_HERDR_JOURNAL_PANE_ID` with `fm_backend_herdr_pane_agent_state <session> <pane>`, and retire the display journal only when the result is exactly `dead`.
   STOP the runbook on `live`, `no-agent`, `unknown`, an invalid journal, an unavailable probe, or any other result.
   This recovery-grade check is mandatory because assuming the pane is dead can delete the durable endpoint record of a worker that is still running.
   Other owners may still consume or retire a journal this runbook leaves untouched, including `bin/fm-herdr-session-cleanup.sh`.
5. Immediately before the final GC, repeat the colliding-sibling check from step 1 and STOP if a sibling has appeared since the first check.
   The check is point-in-time, so repeat it at the last moment before the destructive step.
   A colliding sibling that starts spawning inside the final GC step remains outside this procedure's coverage.
   Repeat the applicable endpoint check, using the retained validated Herdr session and pane from step 4 or a fresh HUMAN check for every other shape, then re-check the metadata and temp root.
   Re-run `FM_HOME=<home> bin/fm-status-gc.sh <id>` only after every confirmed target-owned family from the first refusal has been retired safely and all gates still pass.
   The janitor then retires the status log, open-decisions cursor, presentation-cursor row, and watcher notification markers through their existing owners.
   This final run can still refuse when its scan matches the task id as text inside another task's subdirectory; if so, STOP and leave the status log in place.
   NEVER bypass that refusal or hand-delete the log.
   Bypassing it destroys the last durable record of the work and can break other records that point at that log.
   `bin/fm-supervise-daemon.sh` continues to scan every retained `state/*.status` log, so leaving it in place has an ongoing supervision cost.

For a journal-only orphan, perform step 1's collision and Herdr endpoint checks and step 4 only; do not invoke the janitor because there is no readable status log.
For an orphan that a human identifies as tmux-class, every endpoint check in this procedure is a HUMAN check for a window named `fm-<id>` across every live tmux server, and the runbook proceeds only when none exists.
On each server, use `tmux list-windows -a -F '#{session_name}:#{window_name}'`; use `bin/fm-teardown.sh`'s socket enumeration as the authority for the complete server set rather than checking only the default socket.
The tmux endpoint check must remain human because a window label is not a machine-safe id-keyed ownership proof after metadata is gone.
For optional depth, see the home-local `data/fm-teardown-cleanup-firstprinciples/report.md` when present; it may be absent in other homes and is not required to execute this runbook.

## A live crewmate claiming the pipeline is dead

This is the inverse of the dead-endpoint case above: the worker is alive and the pipeline it declares dead usually is too.
A drive call blocks until the next gate or outcome, far longer than a harness lets one command run, and the daemon accepts a response immediately and runs the round in the background.
So a crewmate's timed-out, killed, or errored drive call leaves it waiting on a read it never got, and the "the daemon is gone" conclusion it draws from that is a guess, not evidence.

Read the two authoritative sources yourself before believing the claim:

1. `no-mistakes daemon status` for the socket.
2. `no-mistakes axi status --run <id>` for the run, or `bin/fm-crew-state.sh <id>`, which already folds this contradiction in and reports a non-socket daemon-or-timeout `blocked:` line over a running or fixing run with fresh activity as superseded because the run is alive.

A refused connection or missing socket from `daemon status` is positive daemon-down evidence and must be escalated even if the persisted run record still says running or fixing; that record can be stale after the daemon exits.
Otherwise, if the run is still running or fixing with recent activity, the claim is wrong: steer the crewmate to reattach with `no-mistakes axi run` from its own worktree, which is safe and idempotent while the run still matches its `HEAD`, and tell it a timeout is not daemon death.
Nothing reaches the captain in that case.

Never restart, stop, or update the shared daemon on a crewmate's claim.
It is one instance serving every lane and home, so a restart kills other lanes' in-flight runs.
Only positive socket refusal or absence is a daemon-down finding; escalate that finding, or a failed run record that names a daemon error, to the captain.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane, and check the task's steering inbox (`state/<id>.inbox/`) for unhandled `*.msg` records - a stale wake naming an unread firstmate instruction means the worker never acknowledged a durable steer, and the record itself shows exactly what was intended.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> interrupt`, then redirect with one corrective line through `fm-send`.
4. If the crewmate is genuinely wedged after redirection, relaunch it with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> relaunch --note '<progress so far>'`, which stops the agent, carries the brief plus that note into a replacement in the same local copy, and restores the prior record if the replacement cannot start.
   Pass `--harness`, `--model`, or `--effort` on that same command when the worker should come back on a different runtime.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.
