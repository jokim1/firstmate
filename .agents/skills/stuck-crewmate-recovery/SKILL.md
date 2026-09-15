---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Also use when a task has surviving records but no state/<id>.meta, including when bin/fm-status-gc.sh refuses that shape and names the surviving families.
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

Use this procedure when a task has surviving records but no `state/<id>.meta`, including when `bin/fm-status-gc.sh <id>` refuses and names those survivors.
The refusal is the work list for finishing the interrupted teardown through the existing record owners.

1. Run `FM_HOME=<home> bin/fm-status-gc.sh <id>` and retain its complete refusal before changing anything.
   The janitor enumerates every surviving record family and fails closed on unknown records, so its refusal defines the exact remaining work rather than a partial glob-based guess.
2. Before retiring anything, check for every different legal sibling id that becomes the same marker key when `.` and `_` are normalized to `_`.
   Inspect the current backlog, state records, and durable `data/<sibling-id>/` task records for those sibling ids, and STOP if any colliding sibling exists.
   The notification marker families normalize separators, so two legal ids such as `a.b` and `a_b` can alias and cleanup for one can otherwise retire the other's markers.
3. If the refusal names a Grok or Kimi turn-end token, source `bin/fm-control-lib.sh`, read the token from `state/<id>.<harness>-turnend-token`, and resolve the corresponding firstmate-owned registry entry with `fm_control_harness_turnend_auth_path <harness> <token>`.
   REFUSE if the helper fails or returns no path.
   Require the registry entry's contents to match the canonical absolute `<state>/<id>.turn-ended` path exactly, and REFUSE on a missing, unreadable, or mismatched entry.
   Only after an exact match may the registry entry, the task token, and `state/<id>.turn-ended` be retired.
   Matching the registry entry's contents is mandatory because trusting the token text alone can deregister a different live task's hook.
4. If the refusal names `state/<id>.herdr-presentation`, source `bin/fm-backend.sh`, load the Herdr adapter with `fm_backend_source herdr`, and validate the journal with `fm_backend_herdr_projection_journal_snapshot <journal> <id>`.
   Probe the validated `$FM_BACKEND_HERDR_JOURNAL_SESSION` and `$FM_BACKEND_HERDR_JOURNAL_PANE_ID` with `fm_backend_herdr_pane_agent_state <session> <pane>`, and retire the display journal only when the result is exactly `dead`.
   STOP the runbook on `live`, `no-agent`, `unknown`, an invalid journal, an unavailable probe, or any other result.
   This recovery-grade check is mandatory because assuming the pane is dead can delete the durable endpoint record of a worker that is still running.
5. Immediately before the final GC, repeat the colliding-sibling check from step 2 and STOP if a sibling has appeared since the first check.
   The check is point-in-time, so repeat it at the last moment before the destructive step.
   A colliding sibling that starts spawning inside the final GC step remains outside this procedure's coverage.
   Then re-run `FM_HOME=<home> bin/fm-status-gc.sh <id>` after every family named by the first refusal has been retired safely.
   Once the remaining shape is exact, the janitor retires the status log, open-decisions cursor, presentation-cursor row, and watcher notification markers through their existing owners.

For a journal-only orphan, perform the colliding-sibling check and the Herdr journal step only.
For a tmux-class backend orphan, replace the endpoint-probe part of step 4 with a HUMAN check of every tmux session for a pane named `fm-<id>`, and proceed only when none exists.
The tmux endpoint check must remain human because no machine-safe id-keyed endpoint proof exists after metadata is gone.
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
