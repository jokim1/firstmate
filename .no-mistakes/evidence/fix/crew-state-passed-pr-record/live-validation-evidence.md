# Live Validation Evidence

Run: 01M2MNAY59ZXRM2FBTNQ45K7BY
Pipeline worktree: /Users/josephkim/.no-mistakes/worktrees/b48deb1e94ba/01M2MNAY59ZXRM2FBTNQ45K7BY
Pipeline head: da1f82194e89969c2cd630d9627c4b0415d5600e
Scratch FM_HOME: /tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home

## Tool Identity
```sh
$ command -v gh || true; gh --version | head -3 || true; command -v gh-axi || true; gh-axi pr view 4623 --repo kunchenguid/firstmate; gh-axi pr view 4586 --repo kunchenguid/firstmate; gh-axi pr view 54 --repo jokim1/firstmate
```
```text
/opt/homebrew/bin/gh
gh version 2.96.0 (2026-07-02)
https://github.com/cli/cli/releases/tag/v2.96.0
/opt/homebrew/bin/gh-axi
pull_request:
  number: 4623
  title: "fix(herdr): wait for shell readiness before worker launch"
  state: open
  author: beyourahi
  draft: no
  merged: no
  checks: "0 passed, 0 failed — this PR has no CI checks configured"
  body: "## Intent\n\nFix the underlying Herdr worker-launch problem so future sub-agents appear in the current Herdr sidebar. Preserve all existing tmux workers and their recorded backend metadata; let them finish normally without restart, migration, termination, or duplication. Investigate the reported shell-prompt corruption using actual launch evidence and the official FirstMate/Herdr documentation, fix the cause rather than merely switching backend settings, keep Herdr as the persistent backend for ne\n... (truncated, 7836 chars total - use --full to see complete body)"
  comment_count: 0 — use --comments to see full comments
  review_count: 0 — use --reviews to see full reviews
pull_request:
  number: 4586
  title: "fix(bin): honour a declared wait before wedge-escalating a quiet pane"
  state: merged
  author: aminry
  draft: no
  merged: "2026-09-16T02:21:22Z"
  checks: "14 passed, 0 failed, 14 total"
  body: "## Intent\n\nThe watcher escalates a lane as a possible wedge even when that lane has positively declared a bounded wait that has not elapsed. The escalation then repeats indefinitely, and each one costs a supervising turn.\n\nkunchenguid/firstmate#3909: a crewmate that declared a bounded external wait still escalates once the pane ages past `FM_STALE_ESCALATE_SECS`, reaching `demand-deep-inspection` on a lane that was verifiably working. `crew_absorb_class` returns `paused` for a declared wait, and\n... (truncated, 55611 chars total - use --full to see complete body)"
  comment_count: 1 — use --comments to see full comments
  review_count: 0 — use --reviews to see full reviews
pull_request:
  number: 54
  title: "fix(bin): keep undelivered decisions open"
  state: closed
  author: jokim1
  draft: no
  merged: no
  checks: "16 passed, 0 failed, 16 total"
  body: "## Intent\n\nbin/fm-send.sh --resolve-key writes the \"resolved\" status line even when the doorbell was skipped and the answer was never delivered, so a decision record reads answered while the worker is still parked waiting for it.\n\nEvidence 2026-09-14 on task fm-pr-poll-device-binding-drift: fm-send reported \"doorbell skipped (composer visibly holds pending text); the steer is durably recorded at ...003.msg and the watcher will re-ring\", AND wrote \"resolved [key=nm-01M2FH1FCFSTS618NPG29JEMY3-revi\n... (truncated, 26034 chars total - use --full to see complete body)"
  comment_count: 0 — use --comments to see full comments
  review_count: 0 — use --reviews to see full reviews
[exit 0]
```

## Live GitHub PR State Reads Through Real fm-crew-state.sh
```sh
$ PATH=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/bin-real:$PATH FM_HOME=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home FM_STATE_OVERRIDE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/state FM_FAKE_AXI_STATUS_FILE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/cases/live-open/status.toon /Users/josephkim/.no-mistakes/worktrees/b48deb1e94ba/01M2MNAY59ZXRM2FBTNQ45K7BY/bin/fm-crew-state.sh live-open
```
```text
state: done · source: run-step · run passed: PR open
[exit 0]
```
ASSERT PASS: open PR case is terminal done
ASSERT PASS: live open PR is reported open
```sh
$ PATH=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/bin-real:$PATH FM_HOME=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home FM_STATE_OVERRIDE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/state FM_FAKE_AXI_STATUS_FILE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/cases/live-closed/status.toon /Users/josephkim/.no-mistakes/worktrees/b48deb1e94ba/01M2MNAY59ZXRM2FBTNQ45K7BY/bin/fm-crew-state.sh live-closed
```
```text
state: done · source: run-step · run passed: PR closed
[exit 0]
```
ASSERT PASS: closed PR case is terminal done
ASSERT PASS: live closed unmerged PR is reported closed, not merged
```sh
$ PATH=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/bin-real:$PATH FM_HOME=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home FM_STATE_OVERRIDE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/state FM_FAKE_AXI_STATUS_FILE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/cases/live-merged/status.toon /Users/josephkim/.no-mistakes/worktrees/b48deb1e94ba/01M2MNAY59ZXRM2FBTNQ45K7BY/bin/fm-crew-state.sh live-merged
```
```text
state: done · source: run-step · run passed: PR merged
[exit 0]
```
ASSERT PASS: merged PR case is terminal done
ASSERT PASS: live merged PR is reported merged

## Matching Retirement Receipt With Forge Tools Removed From PATH
```sh
$ PATH=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/bin-noforge:/usr/bin:/bin:/usr/sbin:/sbin; command -v gh || true; command -v gh-axi || true; command -v glab || true
```
```text
[exit 0]
```
```sh
$ PATH=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/bin-noforge:/usr/bin:/bin:/usr/sbin:/sbin FM_HOME=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home FM_STATE_OVERRIDE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/state FM_FAKE_AXI_STATUS_FILE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/cases/live-receipt/status.toon /Users/josephkim/.no-mistakes/worktrees/b48deb1e94ba/01M2MNAY59ZXRM2FBTNQ45K7BY/bin/fm-crew-state.sh live-receipt
```
```text
state: done · source: run-step · run passed: PR merged
[exit 0]
```
ASSERT PASS: matching local retirement receipt reports merged with gh/gh-axi/glab removed from PATH

## Honest Unknown Without Receipt Or Forge Tools
```sh
$ PATH=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/bin-noforge:/usr/bin:/bin:/usr/sbin:/sbin FM_HOME=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home FM_STATE_OVERRIDE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/state FM_FAKE_AXI_STATUS_FILE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/cases/live-unknown/status.toon /Users/josephkim/.no-mistakes/worktrees/b48deb1e94ba/01M2MNAY59ZXRM2FBTNQ45K7BY/bin/fm-crew-state.sh live-unknown
```
```text
state: done · source: run-step · run passed: PR state unknown (unreadable)
[exit 0]
```
ASSERT PASS: no receipt plus no forge tool reports honest unreadable unknown

## No-Forge Switch Skips Present Forge Wrappers
```sh
$ PATH=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/bin-wrap:$PATH FM_FORGE_WRAPPER_LOG=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/forge-skip.log FM_CREW_STATE_NO_FORGE=1 FM_HOME=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home FM_STATE_OVERRIDE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/state FM_FAKE_AXI_STATUS_FILE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/cases/live-skip/status.toon /Users/josephkim/.no-mistakes/worktrees/b48deb1e94ba/01M2MNAY59ZXRM2FBTNQ45K7BY/bin/fm-crew-state.sh live-skip
```
```text
state: done · source: run-step · run passed: PR state unknown (forge read skipped)
[exit 0]
```
ASSERT PASS: FM_CREW_STATE_NO_FORGE=1 reports skipped unknown
ASSERT PASS: FM_CREW_STATE_NO_FORGE=1 did not invoke gh, gh-axi, or glab wrapper

## Inactive Reconciliation Propagates No-Forge Mode
```sh
$ PATH=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/bin-wrap:$PATH FM_FORGE_WRAPPER_LOG=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/inactive-forge.log FM_HOME=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home FM_STATE_OVERRIDE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/state FM_FAKE_AXI_STATUS_FILE=/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/cases/inactive-child/status.toon FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_RECONCILE_BUDGET_SECS=5 /Users/josephkim/.no-mistakes/worktrees/b48deb1e94ba/01M2MNAY59ZXRM2FBTNQ45K7BY/bin/fm-inactive-reconcile.sh scan --startup
```
```text
actionable: inactive terminal outcome awaiting captain presentation: child=inactive-child state=done pr=https://github.com/kunchenguid/firstmate/pull/4623
[exit 0]
```
ASSERT PASS: inactive reconciliation scan did not invoke gh, gh-axi, or glab wrapper
```sh
$ find /tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/state/terminal-outcomes -type f -maxdepth 1 -print -exec sed -n '1,80p' {} \; | sort
```
```text
/tmp/fm-fm-crewstate-false-merged-label/live-validation/scratch-home/state/terminal-outcomes/2e643262f15a449ce206549648080f03.pending
created_epoch=1789552118
fingerprint=2e643262f15a449ce206549648080f03
incarnation=live-inactive-child
notice_emitted=0
origin=direct
outcome_key=inactive-outcome-main-inactive-child-done
phase=presentation
pr=https://github.com/kunchenguid/firstmate/pull/4623
schema=fm-terminal-outcome.v1
state=done
status_head=e3b0c44298fc1c149afbf4c8996fb924
task_id=inactive-child
[exit 0]
```
ASSERT PASS: inactive reconciliation created a terminal outcome after real crew-state read
ASSERT PASS: inactive reconciliation classified the passed child as done

## GitLab Coverage Limitation
No live GitLab merge request fixture or authenticated GitLab project was available for this task, so no live GitLab MR run is fabricated.
```sh
$ cd /Users/josephkim/.no-mistakes/worktrees/b48deb1e94ba/01M2MNAY59ZXRM2FBTNQ45K7BY && rg -n 'test_terminal_passed_with_(open|merged|failed)_gitlab|fm_pr_gitlab_read_record' tests/fm-crew-state.test.sh bin/fm-pr-lib.sh
```
```text
bin/fm-pr-lib.sh:833:fm_pr_gitlab_read_record() {  # <host> <path> <number>
tests/fm-crew-state.test.sh:1163:test_terminal_passed_with_open_gitlab_mr_does_not_claim_merged() {
tests/fm-crew-state.test.sh:1184:test_terminal_passed_with_merged_gitlab_mr_reports_merged() {
tests/fm-crew-state.test.sh:1199:test_terminal_passed_with_failed_gitlab_read_reports_unknown() {
tests/fm-crew-state.test.sh:2772:test_terminal_passed_with_open_gitlab_mr_does_not_claim_merged
tests/fm-crew-state.test.sh:2773:test_terminal_passed_with_merged_gitlab_mr_reports_merged
tests/fm-crew-state.test.sh:2774:test_terminal_passed_with_failed_gitlab_read_reports_unknown
[exit 0]
```
```sh
$ cd /Users/josephkim/.no-mistakes/worktrees/b48deb1e94ba/01M2MNAY59ZXRM2FBTNQ45K7BY && bash tests/fm-crew-state.test.sh
```
```text
ok - active run-step is authoritative
ok - stale needs-decision over active run is superseded
ok - stale blocked over active run is superseded
ok - daemon/timeout blocked claim over a live fixing run reads as run alive
ok - socket refusal or missing socket over a stale fixing run reports blocked
ok - socket refusal over a terminal attributed run reports blocked
ok - broken-pipe blocker over a live run keeps the plain superseded reading
ok - genuine daemon-down blocked line still reports blocked
ok - genuine parked run is not flagged superseded
ok - scalar gate parked run is not flagged superseded
ok - gate block parked run is not flagged superseded
ok - ci-ready status log beats monitoring run
ok - ci-monitoring run with checks already green surfaces done
ok - top-level ci status uses ci log green marker
ok - terminal no-checks ci-monitor marker surfaces done
ok - base-advance rearm after green stays working
ok - pending no-checks ci-monitor marker stays working
ok - ci-monitoring run with checks not yet green stays working
ok - a fresh issue after an earlier green reading is not masked
ok - stale checks-green status log does not mask CI relapse
ok - ci fixing is not overridden by an earlier green marker
ok - top-level fixing is not overridden by a stale ci running row
ok - top-level fixing is not overridden by a stale done log
ok - terminal passed run is authoritative
ok - terminal passed run uses matching retirement receipt without forge
ok - terminal passed no-forge mode preserves local receipt evidence
ok - terminal passed run with open PR does not claim merged
ok - terminal passed run PR overrides stale task metadata
ok - terminal passed run without readable PR identity reports unknown
ok - terminal passed run reads open GitLab MR state
ok - terminal passed run reads merged GitLab MR state
ok - terminal passed run handles failed GitLab read
ok - terminal failed run is authoritative
ok - orphaned ci monitor after green reads as held-for-merge done
ok - status-only failed orphaned ci monitor after green reads done
ok - genuinely failing CI keeps the failed verdict
ok - a second failed step disqualifies the orphaned-monitor reclassification
ok - cross-branch run is attributed via the real runs list
ok - socket refusal over a coarse active run reports blocked
ok - failed ledger record reads unknown only when the daemon is provably down
ok - cross-branch attribution picks the branch's most recent row
ok - a live run outranks a terminal run bound to the same worktree
ok - runs-list selection prefers a live row over a newer terminal one
ok - an unfetched live sibling outranks a terminal row at the worktree's exact commit
ok - two terminal rows keep the existing newest-first precedence
ok - an unclassifiable status row keeps the ledger's newest-first precedence
ok - a terminal run with no live sibling is unchanged
ok - coarse run does not probe another branch's ci log
ok - another branch's run is ignored, falls back
ok - no run + a busy semantic record reads working, attributed to its source
ok - a converted adapter never reads working from rendered footer text
ok - grok still reads working through its isolated rendered-tail fallback
ok - herdr's native busy verdict reads working with no record present
ok - a herdr CLI that fails to answer reads unknown/unreachable, never gone
ok - an alive endpoint whose scrollback read failed stays working
ok - a husk pane (agent gone) still reads gone for reclaim
ok - a mid-tool-call crew stays working because its record outranks herdr's generation state
ok - an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)
ok - no run + idle pane uses the status-log verb
ok - no run + idle pane parses keyed status syntax
ok - no run + idle pane on a paused: status reports state: paused with its reason
ok - no run + idle pane honors the configured paused verb
ok - a trailing resolved: event does not corrupt state render (idle stays idle)
ok - dead window ignores stale status log
ok - a tmux that fails to answer reads unknown/unreachable, never gone
ok - closed pane still reports a terminal run-step
ok - closed pane still reports an active run-step
ok - no timeout command uses perl bound
ok - scout skips the run lookup
ok - torn-down worktree is handled gracefully
ok - fm-crew-state remote: alive endpoint falls through to the routed status log
ok - fm-crew-state remote: an idle alive endpoint reads alive, never gone or dead
ok - fm-crew-state remote: an unreachable host reads unknown-remote, never gone or dead
ok - fm-crew-state remote: the remote host's own dead verdict is reported truthfully
ok - missing meta is handled gracefully
ok - crew_is_provably_working absorbs a validating crew found only via the runs-list fallback
ok - crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)
ok - usage error exits 2
ok - historical same-branch rewritten head is not attributed as current
ok - active run with valid descendant fix head remains current
ok - local work advanced past run head invalidates attribution
ok - pipeline-owned active run binds without head equality and beats the failed row
ok - a genuinely failed run with no later run is not hidden
ok - coarse scan anchors the unresolvable active row instead of falling to an older one
ok - coarse scan with a mismatched anchor stays unknown and lets the pane answer
ok - the exemption requires branch_sync.state=pipeline_owned
ok - the exemption never applies to a terminal run
ok - missing run head falls back instead of matching by branch
ok - active fix round with an unfetched pipeline head reads working
ok - unanchored unverifiable active row is never attributed
ok - unresolvable terminal row never reads as current
ok - runs-list continuation attribution works when axi answers another branch
ok - herdr stale registration over a shell-only pane reads agent gone, not alive
ok - herdr stale working record never reports a shell-only pane busy
all fm-crew-state tests passed
[exit 0]
```
ASSERT FAIL: fm-crew-state regression suite with fake-glab fixtures passed
Expected to find: PASS
Actual output:
  ok - active run-step is authoritative
  ok - stale needs-decision over active run is superseded
  ok - stale blocked over active run is superseded
  ok - daemon/timeout blocked claim over a live fixing run reads as run alive
  ok - socket refusal or missing socket over a stale fixing run reports blocked
  ok - socket refusal over a terminal attributed run reports blocked
  ok - broken-pipe blocker over a live run keeps the plain superseded reading
  ok - genuine daemon-down blocked line still reports blocked
  ok - genuine parked run is not flagged superseded
  ok - scalar gate parked run is not flagged superseded
  ok - gate block parked run is not flagged superseded
  ok - ci-ready status log beats monitoring run
  ok - ci-monitoring run with checks already green surfaces done
  ok - top-level ci status uses ci log green marker
  ok - terminal no-checks ci-monitor marker surfaces done
  ok - base-advance rearm after green stays working
  ok - pending no-checks ci-monitor marker stays working
  ok - ci-monitoring run with checks not yet green stays working
  ok - a fresh issue after an earlier green reading is not masked
  ok - stale checks-green status log does not mask CI relapse
  ok - ci fixing is not overridden by an earlier green marker
  ok - top-level fixing is not overridden by a stale ci running row
  ok - top-level fixing is not overridden by a stale done log
  ok - terminal passed run is authoritative
  ok - terminal passed run uses matching retirement receipt without forge
  ok - terminal passed no-forge mode preserves local receipt evidence
  ok - terminal passed run with open PR does not claim merged
  ok - terminal passed run PR overrides stale task metadata
  ok - terminal passed run without readable PR identity reports unknown
  ok - terminal passed run reads open GitLab MR state
  ok - terminal passed run reads merged GitLab MR state
  ok - terminal passed run handles failed GitLab read
  ok - terminal failed run is authoritative
  ok - orphaned ci monitor after green reads as held-for-merge done
  ok - status-only failed orphaned ci monitor after green reads done
  ok - genuinely failing CI keeps the failed verdict
  ok - a second failed step disqualifies the orphaned-monitor reclassification
  ok - cross-branch run is attributed via the real runs list
  ok - socket refusal over a coarse active run reports blocked
  ok - failed ledger record reads unknown only when the daemon is provably down
  ok - cross-branch attribution picks the branch's most recent row
  ok - a live run outranks a terminal run bound to the same worktree
  ok - runs-list selection prefers a live row over a newer terminal one
  ok - an unfetched live sibling outranks a terminal row at the worktree's exact commit
  ok - two terminal rows keep the existing newest-first precedence
  ok - an unclassifiable status row keeps the ledger's newest-first precedence
  ok - a terminal run with no live sibling is unchanged
  ok - coarse run does not probe another branch's ci log
  ok - another branch's run is ignored, falls back
  ok - no run + a busy semantic record reads working, attributed to its source
  ok - a converted adapter never reads working from rendered footer text
  ok - grok still reads working through its isolated rendered-tail fallback
  ok - herdr's native busy verdict reads working with no record present
  ok - a herdr CLI that fails to answer reads unknown/unreachable, never gone
  ok - an alive endpoint whose scrollback read failed stays working
  ok - a husk pane (agent gone) still reads gone for reclaim
  ok - a mid-tool-call crew stays working because its record outranks herdr's generation state
  ok - an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)
  ok - no run + idle pane uses the status-log verb
  ok - no run + idle pane parses keyed status syntax
  ok - no run + idle pane on a paused: status reports state: paused with its reason
  ok - no run + idle pane honors the configured paused verb
  ok - a trailing resolved: event does not corrupt state render (idle stays idle)
  ok - dead window ignores stale status log
  ok - a tmux that fails to answer reads unknown/unreachable, never gone
  ok - closed pane still reports a terminal run-step
  ok - closed pane still reports an active run-step
  ok - no timeout command uses perl bound
  ok - scout skips the run lookup
  ok - torn-down worktree is handled gracefully
  ok - fm-crew-state remote: alive endpoint falls through to the routed status log
  ok - fm-crew-state remote: an idle alive endpoint reads alive, never gone or dead
  ok - fm-crew-state remote: an unreachable host reads unknown-remote, never gone or dead
  ok - fm-crew-state remote: the remote host's own dead verdict is reported truthfully
  ok - missing meta is handled gracefully
  ok - crew_is_provably_working absorbs a validating crew found only via the runs-list fallback
  ok - crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)
  ok - usage error exits 2
  ok - historical same-branch rewritten head is not attributed as current
  ok - active run with valid descendant fix head remains current
  ok - local work advanced past run head invalidates attribution
  ok - pipeline-owned active run binds without head equality and beats the failed row
  ok - a genuinely failed run with no later run is not hidden
  ok - coarse scan anchors the unresolvable active row instead of falling to an older one
  ok - coarse scan with a mismatched anchor stays unknown and lets the pane answer
  ok - the exemption requires branch_sync.state=pipeline_owned
  ok - the exemption never applies to a terminal run
  ok - missing run head falls back instead of matching by branch
  ok - active fix round with an unfetched pipeline head reads working
  ok - unanchored unverifiable active row is never attributed
  ok - unresolvable terminal row never reads as current
  ok - runs-list continuation attribution works when axi answers another branch
  ok - herdr stale registration over a shell-only pane reads agent gone, not alive
  ok - herdr stale working record never reports a shell-only pane busy
  all fm-crew-state tests passed
