---
name: patch-queue-prune
description: >-
  Agent-only adversarial audit of the fork's lila-main patch stack that argues every carried patch toward consolidation or removal.
  Load at every lila-main upstream rebase, when the captain asks for a patch-stack prune, refactor, or simplification audit, and when the patch-queue rebase records show roughly six weeks without a rebase.
  Owns the pass trigger and its staleness backstop, the per-patch evidence procedure with executable proof of redundancy as the only bar for a drop, the consolidation-first ordering and its one-owner-guarantee criterion, the refusal cases, and the report the captain reads.
user-invocable: false
metadata:
  internal: true
---

# patch-queue-prune

The fork's patch stack accretes: guards grow exceptions, exceptions grow further exceptions, and patches cluster into the same subsystems again and again.
Arguing from a diff is how that accretion stays safe-looking while defects ship, and retiring on weak evidence is how load-bearing patches get dropped - both shapes are on record in the fork's own rebase history, including a retirement that over-fired against upstream's reworked code and one that silently dropped a live capability.
This pass shrinks the stack without repeating either failure: consolidation first, deletion only behind executable proof.

## Trigger

Load and run this pass:

- At every `lila-main` upstream rebase, inside the rebase job, after the per-fetch retire scan the queue discipline already requires.
- When the captain asks for a patch-stack prune, refactor, or simplification audit.
- As a staleness backstop: when roughly six weeks have passed with no rebase, the pass is due, and any agent that observes that staleness fires it.

The rebase records in `data/patch-queue/README.md` own the dates; judge staleness from them, never from a timer.
There is no calendar job and no scheduler: the rebase is the trigger, the backstop is a staleness observation against existing records, and this pass manufactures no second recurring mechanism.
Never fire on a plain fetch, on upstream PR activity alone, or on a cadence.

## Relationship to queue discipline

`data/patch-queue/README.md` owns queue discipline: the stack table, the `retire-when` trailer format, the per-fetch retire scan, the rebase mechanics, and the force-push authority.
This skill restates none of it.
The pass runs inside the rebase job after that retire scan and audits what the scan left standing; publishing any rebuilt stack stays with the rebase procedure and its own gates.

## Per-patch procedure

Audit every patch on the stack, taken from the stack table plus the overlay git log, one at a time.

1. Gather evidence: the patch commit and its `retire-when` trailer, its PR body, the tests it carries, the upstream files and contracts it touches, and what upstream tip does in that code today.
2. Classify: covered by upstream (a drop candidate), load-bearing (upstream lacks the behavior), or chained (one of several patches defending a single guarantee - a consolidation candidate).
3. Prove redundancy before any drop.
   The bar is executable, and nothing else counts:
   - The patch's own test FAILS on our stack with the patch reverted, proving the test actually exercises the patch and the result is not vacuous.
   - The same test PASSES against upstream tip without the patch, cherry-picking the test alone onto upstream tip when the test itself is fork-only.
   Record both executions with exact commands and output.
   An argument from the diff, a reading of upstream changes, or a judgment that upstream looks like it covers the behavior is never sufficient; that is the failure shape this pass exists to kill.
4. A fork-only standing divergence whose `retire-when` names a fork-internal condition (for example CI shard count or fork test load) cannot pass against upstream tip by construction.
   Its proof is the recorded executable check of its own `retire-when` condition instead.
5. Before a drop lands, a reviewer must see the two recorded executions, the upstream evidence behind them (the commit, PR, or issue present on tip), and a capability statement naming any behavior that is lost.
   Any lost behavior makes the retire capability-narrowing, which `data/patch-queue/README.md` rule 1 reserves for the captain's explicit per-item word; this pass never grants itself that authority.

## Consolidation pass, run first

Consolidation is weighted ahead of deletion: merging several patches that serve one guarantee is lower risk than dropping any of them, and it attacks the chained-guard shape directly.
Evaluate every group before evaluating any single patch for removal.

A group of patches serves one owner guarantee when they defend a single behavioral guarantee of one owner contract (one refusal, one watcher guarantee, one lifecycle rule), their changes overlap or chain (a guard plus its exceptions is the canonical shape), and their `retire-when` conditions are facets of one upstream condition.
State the guarantee in one sentence before folding; a group that cannot be stated as one guarantee is not a group.

Fold the group into one squash commit carrying one `retire-when` for that guarantee, then run the group's combined tests.
Consolidation changes commit structure, never behavior: if a fold requires a behavior change, stop, because that is a refactor and belongs to its own task, not to this pass.

## Refusals

This pass must never, on its own authority:

- Drop a patch without the recorded executable proof above.
- Retire a capability-narrowing patch without the captain's explicit per-item word.
- Drop a patch whose evidence is incomplete: a patch without a demonstrating test or without a live `retire-when` is kept, and the gap is reported, never filled by invention.
- Change behavior while consolidating, or trim a partially covered patch; narrowing a patch is a behavior change and belongs to its own task.
- Auto-resolve conflicts, push, force-push, merge, or publish; all of that belongs to the rebase procedure.
- Add patches or expand any patch's scope; this pass only removes and consolidates.
- Build machinery: no new scripts, state directories, registries, or schedulers, because the pass is this procedure plus its report.

## Output

The pass produces a self-contained report - the executing task's report file, or `data/patch-queue-prune-<date>/report.md` when run outside a task - containing:

- A summary with the stack size before and after, and the counts dropped, consolidated, and kept.
- A per-patch verdict: dropped, consolidated into a named fold, or kept, with the recorded commands and output behind every drop, the capability statement, and for every keep the one-line reason (load-bearing, evidence gap, or fork-only divergence).
- The note that every proposed stack change lands only under the standing adversarial-review bar recorded with the queue discipline.

The captain must be able to see what was dropped, what was consolidated, and what was kept and why without reading a single diff.
