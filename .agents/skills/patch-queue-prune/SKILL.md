---
name: patch-queue-prune
description: >-
  Agent-only adversarial audit of the fork's lila-main patch stack that argues every carried patch toward consolidation or removal.
  Load automatically at every lila-main upstream rebase and when the patch-queue rebase records show roughly six weeks without a rebase; separately, the captain may invoke the pass at any time.
  Owns the pass trigger and its staleness backstop, the per-patch evidence procedure with executable proof of redundancy as the only bar for a drop, the consolidation-first ordering and its one-owner-guarantee criterion, the refusal cases, and the report the captain reads.
user-invocable: false
metadata:
  internal: true
---

# patch-queue-prune

The fork's patch stack accretes: guards grow exceptions, exceptions grow further exceptions, and patches cluster into the same subsystems again and again.
Arguing from a diff is how that accretion stays safe-looking while defects ship, and retiring on weak evidence is how load-bearing patches get dropped - both shapes are on record in the fork's own rebase history, including a retirement that over-fired against upstream's reworked code and one that silently dropped a live capability.
This pass identifies how to shrink the stack without repeating either failure: consolidation first, deletion only behind executable proof.

## Trigger

This recurring pass has exactly two automatic triggers:

- At every `lila-main` upstream rebase, inside the rebase job, after the per-fetch retire scan the queue discipline already requires.
- As a staleness backstop: when roughly six weeks have passed with no rebase, the pass is due, and any agent that observes that staleness fires it.

Separately, the captain may invoke the pass at any time; a direct request is not an automatic trigger.
The rebase records in `data/patch-queue/README.md` own the dates; judge staleness from them, never from a timer.
There is no calendar job and no scheduler: the rebase is the trigger, the backstop is a staleness observation against existing records, and this pass manufactures no second recurring mechanism.
An ordinary fetch must never be mistaken for a rebase and does not fire the pass by itself; this exclusion does not suppress the staleness trigger when the observer finds that roughly six weeks have passed without a rebase.
Never fire on upstream PR activity alone or on a cadence.

## Relationship to queue discipline

`data/patch-queue/README.md` owns queue discipline: the stack table, the `retire-when` trailer format, the per-fetch retire scan, the rebase mechanics, and the force-push authority.
This skill restates none of it.
The pass runs inside the rebase job after that retire scan and audits what the scan left standing.
It reports proposed changes only; after the captain explicitly approves each specific item, the rebase procedure owns making that approved change and applying its own gates.

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
4. A patch whose redundancy cannot be proven by those two executions is kept, never dropped.
   This includes a fork-only standing divergence, such as CI shard count, that has no upstream counterpart against which the patch's test can pass.
   Retiring such a patch anyway is a capability-narrowing decision that requires the captain's explicit per-item word; this pass cannot make it.
5. Recommend a drop only when the report can show the two recorded executions, the upstream evidence behind them (the commit, PR, or issue present on tip), and a capability statement naming any behavior that would be lost.
   Any lost behavior makes the retire capability-narrowing, which `data/patch-queue/README.md` rule 1 reserves for the captain's explicit per-item word; this pass never grants itself that authority.

## Consolidation pass, run first

Consolidation is weighted ahead of deletion: merging several patches that serve one guarantee is lower risk than dropping any of them, and it attacks the chained-guard shape directly.
Evaluate every group before evaluating any single patch for removal.

A group of patches serves one owner guarantee when they defend a single behavioral guarantee of one owner contract (one refusal, one watcher guarantee, one lifecycle rule), their changes overlap or chain (a guard plus its exceptions is the canonical shape), and their `retire-when` conditions are facets of one upstream condition.
State the guarantee in one sentence before proposing a fold; a group that cannot be stated as one guarantee is not a group.

Propose the group as one squash commit carrying one `retire-when` for that guarantee, and identify the combined tests the approved fold must pass.
Do not create the commit or change the stack until the captain explicitly approves that specific fold.
A proposed consolidation may change commit structure, never behavior; if a fold would require a behavior change, keep the patches separate because that is a refactor and belongs to its own task, not to this pass.

## Refusals

This pass must never, on its own authority:

- Start a commit, drop a patch, fold patches, or otherwise mutate the stack; proof earns a recommendation, and every specific change waits for the captain's explicit per-item approval.
- Drop a patch without the recorded executable proof above.
- Retire a capability-narrowing patch without the captain's explicit per-item word.
- Drop a patch whose evidence is incomplete: a patch without a demonstrating test or without a live `retire-when` is kept, and the gap is reported, never filled by invention.
- Change behavior while consolidating, or trim a partially covered patch; narrowing a patch is a behavior change and belongs to its own task.
- Auto-resolve conflicts, push, force-push, merge, or publish; all of that belongs to the rebase procedure.
- Add patches or expand any patch's scope; this pass only proposes removals and consolidations.
- Build machinery: no new scripts, state directories, registries, or schedulers, because the pass is this procedure plus its report.

## Output

The pass produces a self-contained report - the executing task's report file, or `data/patch-queue-prune-<date>/report.md` when run outside a task - containing:

- A summary with the current and projected stack sizes, and the counts proposed for dropping, consolidation, and keeping.
- A per-patch recommendation: propose dropping, propose consolidation into a named fold, or keep, with the recorded commands and output behind every proposed drop, the capability statement, and for every keep the one-line reason (load-bearing, evidence gap, or fork-only divergence).
- The note that every proposed stack change waits for the captain's explicit approval of that specific item before any commit starts, then lands only through the rebase procedure under the standing adversarial-review bar recorded with the queue discipline.

The captain must be able to see what would be dropped, what would be consolidated, and what would be kept and why without reading a single diff.
