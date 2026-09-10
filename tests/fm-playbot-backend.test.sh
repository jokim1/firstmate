#!/usr/bin/env bash
# tests/fm-playbot-backend.test.sh - hermetic contract tests for the Playbot
# backend adapter bin/backends/playbot.sh (plan v3 section 1.2's adapter
# table, 3.4's dispatch transaction, 3.7's control/cleanup integration, and
# 4.1's send semantics). The adapter is sourced directly and every function is
# exercised through the exact names the landed shared-core seam
# (bin/fm-backend.sh, bin/fm-spawn.sh, bin/fm-teardown.sh) dispatches to.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-playbot-backend-tests)
FIX="$TMP_ROOT/fixtures"
mkdir -p "$FIX"
node "$ROOT/tests/playbot-fixtures/generate.mjs" "$FIX" >/dev/null || fail "fixture generation failed"

HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE"

export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$STATE"
export FM_PLAYBOT_APP_DB="$FIX/playbot.db"
export FM_PLAYBOT_CODEX_DB="$FIX/harness/state_5.sqlite"
export FM_PLAYBOT_APP_RUN_STATE="$FIX/playbot-app-run-state.json"
export FM_PLAYBOT_DEVTOOLS_PORT_FILE="$FIX/DevToolsActivePort"
export FM_PLAYBOT_APP_BUNDLE="$FIX/fixture-app.asar"
export FM_PLAYBOT_APP_VERSION="0.90.0"

# shellcheck source=bin/backends/playbot.sh
. "$ROOT/bin/backends/playbot.sh"

# --- target shape -------------------------------------------------------------

[ "$(fm_backend_playbot_target_thread playbot:thread-complete)" = thread-complete ] \
  || fail "playbot:<thread-id> must parse to the exact thread id"
if fm_backend_playbot_target_thread "session:window" >/dev/null 2>&1; then
  fail "a tmux-style session:window target must be refused"
fi
if fm_backend_playbot_target_thread "thread-complete" >/dev/null 2>&1; then
  fail "a bare thread id without the playbot: scheme must be refused"
fi
if fm_backend_playbot_target_thread "" >/dev/null 2>&1; then
  fail "an empty target must be refused"
fi
pass "target parsing accepts only exact playbot:<thread-id>"

# --- runtime check: not spawn-capable until Phase 1 ----------------------------

if fm_backend_playbot_runtime_check > /dev/null 2>"$TMP_ROOT/rtc.err"; then
  fail "runtime check must refuse before Phase 1 evidence exists"
fi
grep -Eq 'PHASE1-EVIDENCE-REQUIRED|read-only compatibility|reachability' "$TMP_ROOT/rtc.err" \
  || fail "runtime check refusal must name the evidence or runtime-health gate"
pass "runtime check refuses spawn intake until evidence and runtime health pass"

# --- send semantics (plan 4.1) --------------------------------------------------

for key in Enter Escape C-c enter; do
  if fm_backend_playbot_send_key playbot:thread-complete "$key" >/dev/null 2>&1; then
    fail "send_key must reject '$key' before any mutation"
  fi
done
KEY_OUT=$(fm_backend_playbot_send_key playbot:thread-complete Enter 2>&1 || true)
printf '%s' "$KEY_OUT" | grep -q 'does not support sending keys' || fail "send_key refusal must explain the no-key contract"
pass "send_key rejects every named key, including Enter, Escape, and C-c"

SEND_OUT=$(fm_backend_playbot_send_text_submit playbot:thread-complete "one literal line" 3 0.1 0.1 2>"$TMP_ROOT/send.err") && RC=0 || RC=$?
[ "$RC" -ne 0 ] || fail "send_text_submit must exit nonzero before Phase 1 evidence"
[ -z "$SEND_OUT" ] || fail "send_text_submit must keep stdout empty on refusal (only exact empty confirms acceptance)"
grep -q 'PHASE1-EVIDENCE-REQUIRED' "$TMP_ROOT/send.err" || fail "send refusal must carry the stable phase diagnostic"
pass "send_text_submit matches the fm-send empty-success contract: nonempty failure, nonzero exit, nothing sent"

# --- composer state (plan 1.2) --------------------------------------------------

[ "$(fm_backend_playbot_composer_state playbot:thread-pending)" = pending ] \
  || fail "composer_state must map exact queued input to pending"
[ "$(fm_backend_playbot_composer_state playbot:thread-complete)" = empty ] \
  || fail "composer_state must map exact no-queue evidence to empty"
[ "$(fm_backend_playbot_composer_state playbot:thread-malformed-queue)" = unknown ] \
  || fail "composer_state must map a malformed queue to unknown"
[ "$(fm_backend_playbot_composer_state playbot:no-such)" = unknown ] \
  || fail "composer_state must map absence to unknown"
pass "composer_state maps exact pending-queue evidence to empty/pending/unknown"

# --- busy / target-exists / agent-state ----------------------------------------

[ "$(fm_backend_playbot_busy_state playbot:thread-multi)" = busy ] || fail "running thread must be busy"
[ "$(fm_backend_playbot_busy_state playbot:thread-complete)" = idle ] || fail "ready thread must be idle"
[ "$(fm_backend_playbot_busy_state playbot:no-such)" = unknown ] || fail "Playbot absence must report unknown, never guessed dead"
fm_backend_playbot_target_exists playbot:thread-complete || fail "exact unarchived thread+workspace must exist"
if fm_backend_playbot_target_exists playbot:thread-archived 2>/dev/null; then
  fail "an archived thread must not exist"
fi
if fm_backend_playbot_target_exists playbot:no-such 2>/dev/null; then
  fail "an absent thread must not exist"
fi
[ "$(fm_backend_playbot_agent_state playbot:thread-complete)" = alive ] || fail "exact usable thread must be alive"
[ "$(fm_backend_playbot_agent_state playbot:thread-archived)" = missing ] || fail "archived thread must be missing"
[ "$(fm_backend_playbot_agent_state playbot:thread-no-session)" = ambiguous ] || fail "session-less thread must be ambiguous"
for t in thread-complete thread-archived thread-no-session no-such; do
  [ "$(fm_backend_playbot_agent_state "playbot:$t")" != dead ] \
    || fail "agent_state must never invent dead (only proven states license lifecycle actions)"
done
if FM_PLAYBOT_APP_DB="$TMP_ROOT/nonexistent.db" fm_backend_playbot_agent_state playbot:thread-complete >/dev/null 2>&1; then :; fi
[ "$(FM_PLAYBOT_APP_DB="$TMP_ROOT/nonexistent.db" fm_backend_playbot_agent_state playbot:thread-complete)" = unreadable ] \
  || fail "an unreadable app database must report unreadable"
pass "busy/target-exists/agent-state honor the recovery-grade vocabulary with no invented dead"

# --- capture: bounded untrusted rollout data ------------------------------------

CAP=$(fm_backend_playbot_capture playbot:thread-complete 40) || fail "capture of an exact thread failed"
printf '%s' "$CAP" | grep -q '"turnId": "turn-fixture-complete"' || fail "capture must return the exact-thread rollout identity"
pass "capture returns the bounded exact-thread rollout as data"

# --- worktree path and Phase-1-gated lifecycle ----------------------------------

WT_PATH=$(fm_backend_playbot_worktree_path workspace-task) || fail "worktree_path failed"
[ "$(cd "$WT_PATH" && pwd -P)" = "$(cd "$FIX/worktrees/task" && pwd -P)" ] \
  || fail "worktree_path must return the exact workspace_roots.path"
if fm_backend_playbot_worktree_path no-such-ws >/dev/null 2>&1; then
  fail "worktree_path must fail for an unknown workspace"
fi
# Combined pre-seam create shape stays a loud refusal (not an evidence gate).
if fm_backend_playbot_create some-task /tmp/whatever >/dev/null 2>"$TMP_ROOT/lc.err"; then
  fail "combined create must refuse the pre-seam shape"
fi
grep -qi 'split into workspace_create' "$TMP_ROOT/lc.err" || fail "combined create must name the split seam"

# Evidence-gated mutations refuse with the phase marker before any IPC.
for call in "fm_backend_playbot_kill playbot:thread-complete" \
            "fm_backend_playbot_remove_worktree workspace-task" \
            "fm_backend_playbot_interrupt playbot:thread-complete be-ep $STATE/be-ep.meta" \
            "fm_backend_playbot_thread_create workspace-task some-task delivery-x"; do
  if $call >/dev/null 2>"$TMP_ROOT/lc.err"; then
    fail "'$call' must refuse before Phase 1 evidence"
  fi
  grep -q 'PHASE1-EVIDENCE-REQUIRED' "$TMP_ROOT/lc.err" || fail "'$call' must refuse with the phase marker"
done
INTERRUPT_PROOF=$(
  fm_backend_playbot_tool_check() { return 0; }
  # Bash 3.2 cannot parse nested case inside command substitution; use if/elif.
  fm_backend_playbot_lane() {
    if [ "${1:-}" = stop ]; then
      return 0
    elif [ "${1:-}" = busy-state ]; then
      printf 'idle\n'
    else
      return 1
    fi
  }
  fm_backend_playbot_interrupt playbot:thread-complete be-ep "$STATE/be-ep.meta"
) || fail "interrupt must accept an exact idle postcondition"
[ "$INTERRUPT_PROOF" = stopped ] || fail "interrupt must print stopped only after idle proof"
printf '0\n' > "$TMP_ROOT/interrupt-polls"
INTERRUPT_PROOF=$(
  fm_backend_playbot_tool_check() { return 0; }
  fm_backend_playbot_lane() {
    if [ "${1:-}" = stop ]; then
      return 0
    elif [ "${1:-}" = busy-state ]; then
      poll_count=$(cat "$TMP_ROOT/interrupt-polls")
      poll_count=$((poll_count + 1))
      printf '%s\n' "$poll_count" > "$TMP_ROOT/interrupt-polls"
      if [ "$poll_count" -gt 20 ]; then printf 'idle\n'; else printf 'busy\n'; fi
    else
      return 1
    fi
  }
  sleep() { :; }
  fm_backend_playbot_interrupt playbot:thread-complete be-ep "$STATE/be-ep.meta"
) || fail "interrupt must allow the native stop transition beyond two seconds"
[ "$INTERRUPT_PROOF" = stopped ] || fail "slower verified interrupt must print stopped"
if (
  printf '0\n' > "$TMP_ROOT/interrupt-timeout-polls"
  fm_backend_playbot_tool_check() { return 0; }
  fm_backend_playbot_lane() {
    if [ "${1:-}" = stop ]; then
      return 0
    elif [ "${1:-}" = busy-state ]; then
      poll_count=$(cat "$TMP_ROOT/interrupt-timeout-polls")
      printf '%s\n' "$((poll_count + 1))" > "$TMP_ROOT/interrupt-timeout-polls"
      printf 'busy\n'
    else
      return 1
    fi
  }
  sleep() { SECONDS=1000; }
  fm_backend_playbot_interrupt playbot:thread-complete be-ep "$STATE/be-ep.meta"
) >/dev/null 2>"$TMP_ROOT/interrupt-unverified.err"; then
  fail "interrupt must refuse when the exact thread never becomes idle"
fi
grep -q 'stop was not verified' "$TMP_ROOT/interrupt-unverified.err" \
  || fail "unverified interrupt must name the missing stop postcondition"
[ "$(cat "$TMP_ROOT/interrupt-timeout-polls")" -eq 1 ] \
  || fail "interrupt verification must stop at its wall-clock deadline"
pass "interrupt reports success only after exact idle-state proof"
# workspace_create and send_initial fail at binding/file preflight or the gate.
if fm_backend_playbot_workspace_create /tmp/whatever fm-some-task HEAD some-task >/dev/null 2>"$TMP_ROOT/lc.err"; then
  fail "workspace_create must refuse without a binding/evidence"
fi
[ -s "$TMP_ROOT/lc.err" ] || fail "workspace_create refusal must print a diagnostic"
printf '%s' "$(cat "$TMP_ROOT/lc.err")" | grep -Eqi 'PHASE1-EVIDENCE-REQUIRED|binding|project|ENOENT|no such file|refuse|error' \
  || fail "workspace_create refusal must be fail-closed"
echo 'brief body' > "$TMP_ROOT/brief.md"
if fm_backend_playbot_send_initial playbot:thread-complete "$TMP_ROOT/brief.md" delivery-x digest-x >/dev/null 2>"$TMP_ROOT/lc.err"; then
  fail "send_initial must refuse before Phase 1 evidence"
fi
grep -q 'PHASE1-EVIDENCE-REQUIRED' "$TMP_ROOT/lc.err" || fail "send_initial must refuse with the phase marker"
pass "lifecycle mutations refuse fail-closed before Phase 1 evidence; pre-seam create stays split"

# --- binding resolution (plan 3.3; seam dispatch transaction step "prepared") ---

ALPHA_PATH=$(cd "$FIX/projects/alpha" && pwd -P)
cat > "$STATE/.playbot-project-bindings.json" <<EOF
{
  "schema": "firstmate.playbot.project-bindings.v1",
  "bindings": [
    {
      "canonicalProjectPath": "$ALPHA_PATH",
      "playbotProjectId": "project-alpha",
      "playbotRootId": "root-alpha",
      "liveRootPath": "$ALPHA_PATH",
      "bindingGeneration": 7,
      "lastVerifiedAppVersion": "0.90.0"
    }
  ]
}
EOF
RESOLVED=$(fm_backend_playbot_binding_resolve "$FIX/projects/alpha") || fail "binding_resolve failed for the bound project"
[ "$RESOLVED" = "$(printf 'project-alpha\troot-alpha\t7')" ] \
  || fail "binding_resolve must print the exact tab-separated project/root/generation triple"
if fm_backend_playbot_binding_resolve "$FIX" >/dev/null 2>&1; then
  fail "binding_resolve must refuse an unbound project path"
fi
pass "binding_resolve returns the exact bound triple and refuses unbound projects"

# --- endpoint validation through the adapter ------------------------------------
# The route record is written through the adapter's route_write, the same
# function the seam's meta-published dispatch stage calls.

WORKTREE_TASK=$(cd "$FIX/worktrees/task" && pwd -P)
cat > "$STATE/be-ep.meta" <<EOF
window=playbot:thread-complete
endpoint_task_id=be-ep
worktree=$WORKTREE_TASK
project=$FIX/projects/alpha
harness=codex
kind=ship
mode=local-only
yolo=off
tasktmp=$TMP_ROOT/tasktmp
model=fixture-model
effort=low
spawn_gen=1
backend=playbot
playbot_project_id=project-alpha
playbot_project_root_id=root-alpha
playbot_workspace_id=workspace-task
playbot_thread_id=thread-complete
playbot_route_gen=1
playbot_delivery_id=delivery-be-ep
EOF
fm_backend_playbot_route_write "$STATE" be-ep 1 1 project-alpha root-alpha \
  workspace-task thread-complete delivery-be-ep "$WORKTREE_TASK" \
  || fail "route_write must accept the meta-consistent dispatch identity"
[ -f "$STATE/be-ep.playbot-route.json" ] || fail "route_write must write state/<id>.playbot-route.json"
if [ "$(uname)" = Darwin ]; then ROUTE_MODE=$(stat -f %Lp "$STATE/be-ep.playbot-route.json"); else ROUTE_MODE=$(stat -c %a "$STATE/be-ep.playbot-route.json"); fi
[ "$ROUTE_MODE" = 600 ] || fail "route record must be mode 0600"
sed -i.bak -e 's/^spawn_gen=1$/spawn_gen=2/' -e 's/^playbot_route_gen=1$/playbot_route_gen=2/' "$STATE/be-ep.meta"
rm -f "$STATE/be-ep.meta.bak"
fm_backend_playbot_route_write "$STATE" be-ep 2 2 project-alpha root-alpha \
  workspace-task thread-complete delivery-be-ep "$WORKTREE_TASK" \
  || fail "route_write must accept same-endpoint re-entry with fresh generations"
[ "$(jq -r '.spawnGen' "$STATE/be-ep.playbot-route.json")" = 2 ] \
  || fail "re-entry route_write did not replace the spawn generation"
[ "$(jq -r '.routeGen' "$STATE/be-ep.playbot-route.json")" = 2 ] \
  || fail "re-entry route_write did not replace the route generation"
cp "$STATE/be-ep.meta" "$STATE/be-bad.meta"
if fm_backend_playbot_route_write "$STATE" be-bad 2 2 project-alpha root-alpha \
  workspace-task thread-WRONG delivery-be-ep "$WORKTREE_TASK" >/dev/null 2>&1; then
  fail "route_write must refuse a dispatch identity that disagrees with the published meta"
fi
[ ! -e "$STATE/be-bad.playbot-route.json" ] || fail "a refused route_write must not leave a record behind"
fm_backend_playbot_validate_endpoint "$STATE/be-ep.meta" || fail "adapter endpoint validation must accept the bound endpoint"
sed -i.bak 's/window=playbot:thread-complete/window=session:window/' "$STATE/be-ep.meta" && rm -f "$STATE/be-ep.meta.bak"
if fm_backend_playbot_validate_endpoint "$STATE/be-ep.meta" >/dev/null 2>&1; then
  fail "adapter endpoint validation must reject a non-playbot window shape"
fi
pass "endpoint validation enforces the exact playbot:<thread-id> window and the route_write-bound route"

# --- endpoint-gone proof and teardown retirement (plan 3.7) ----------------------

fm_backend_playbot_endpoint_confirmed_gone playbot:thread-archived \
  || fail "an archived thread must be confirmed gone"
if fm_backend_playbot_endpoint_confirmed_gone playbot:thread-complete; then
  fail "a live thread must NOT be confirmed gone"
fi
if FM_PLAYBOT_APP_DB="$TMP_ROOT/nonexistent.db" fm_backend_playbot_endpoint_confirmed_gone playbot:thread-complete; then
  fail "an unreadable inventory must never confirm an endpoint gone"
fi
pass "endpoint_confirmed_gone proves gone only from an authoritative inventory"

if fm_backend_playbot_abort_cleanup_confirmed thread-complete workspace-task "$WORKTREE_TASK"; then
  fail "abort cleanup confirmation must refuse persisted resources"
fi
fm_backend_playbot_abort_cleanup_confirmed thread-gone workspace-gone "$TMP_ROOT/missing-worktree" \
  || fail "abort cleanup confirmation must accept independently proved absence"
pass "abort cleanup confirmation requires thread, workspace, and worktree absence"

TD_OUT=$(fm_backend_playbot_teardown "$STATE/be-ep.meta" be-ep playbot:thread-complete \
  "$WORKTREE_TASK" workspace-task thread-complete : 2>"$TMP_ROOT/td.err") && TD_RC=0 || TD_RC=$?
[ "$TD_RC" -ne 0 ] || fail "teardown must refuse a live endpoint when archive/stop cannot complete"
case "$TD_OUT" in refuse:*) : ;; *) fail "teardown refusal must print a refuse:<reason> proof token, got $TD_OUT" ;; esac
TD_RET=$(fm_backend_playbot_teardown "$STATE/be-ep.meta" be-ep playbot:thread-archived \
  "$WORKTREE_TASK" workspace-task thread-archived :) \
  || fail "an already-gone endpoint must report retained or retired, not refuse"
case "$TD_RET" in retained:*|retired) : ;; *) fail "already-gone teardown must print retained:<reason> or retired, got $TD_RET" ;; esac
TD_MM=$(fm_backend_playbot_teardown "$STATE/be-ep.meta" be-ep playbot:thread-complete \
  "$WORKTREE_TASK" workspace-task thread-OTHER : 2>/dev/null) && TD_RC=0 || TD_RC=$?
[ "$TD_RC" -ne 0 ] && [ "$TD_MM" = 'refuse:target-thread-mismatch' ] \
  || fail "teardown must refuse a target/thread identity mismatch"
pass "teardown refuses live/mismatched endpoints and reports retained/retired for a confirmed-gone thread"

PLAYBOT_TEARDOWN_LOG="$TMP_ROOT/teardown-order.log"
playbot_teardown_safety_check() {
  [ ! -e "$WORKTREE_TASK/late-worker-write" ]
}
fm_backend_playbot_lane() {
  case "${1:-}" in
    agent-state) printf '%s\n' "${PLAYBOT_TEST_STATE:-alive}" ;;
    stop) printf 'stop\n' >> "$PLAYBOT_TEARDOWN_LOG" ;;
    archive)
      printf 'archive\n' >> "$PLAYBOT_TEARDOWN_LOG"
      printf 'late\n' > "$WORKTREE_TASK/late-worker-write"
      ;;
    delete) printf 'delete\n' >> "$PLAYBOT_TEARDOWN_LOG" ;;
    *) return 1 ;;
  esac
}
: > "$PLAYBOT_TEARDOWN_LOG"
TD_RACE=$(fm_backend_playbot_teardown "$STATE/be-ep.meta" be-ep playbot:thread-complete \
  "$WORKTREE_TASK" workspace-task thread-complete playbot_teardown_safety_check) \
  && TD_RC=0 || TD_RC=$?
[ "$TD_RC" -ne 0 ] && [ "$TD_RACE" = 'refuse:worktree-safety-recheck-failed' ] \
  || fail "teardown must refuse a worker write created while the endpoint quiesces"
grep -qxF archive "$PLAYBOT_TEARDOWN_LOG" \
  || fail "race fixture did not archive the endpoint before the safety recheck"
if grep -qxF delete "$PLAYBOT_TEARDOWN_LOG"; then
  fail "teardown deleted the workspace after the post-quiescence safety recheck failed"
fi
pass "teardown rechecks worktree safety after Playbot quiescence and before workspace deletion"

PLAYBOT_TEST_STATE=missing
: > "$PLAYBOT_TEARDOWN_LOG"
TD_MISSING=$(fm_backend_playbot_teardown "$STATE/be-ep.meta" be-ep playbot:thread-archived \
  "$WORKTREE_TASK" workspace-task thread-archived playbot_teardown_safety_check) \
  && TD_RC=0 || TD_RC=$?
[ "$TD_RC" -ne 0 ] && [ "$TD_MISSING" = 'refuse:worktree-safety-recheck-failed' ] \
  || fail "teardown must safety-check an already-gone endpoint before workspace deletion"
if grep -qxF delete "$PLAYBOT_TEARDOWN_LOG"; then
  fail "teardown deleted the workspace after the confirmed-gone safety recheck failed"
fi
rm -f "$WORKTREE_TASK/late-worker-write"
: > "$PLAYBOT_TEARDOWN_LOG"
TD_SAFE=$(fm_backend_playbot_teardown "$STATE/be-ep.meta" be-ep playbot:thread-archived \
  "$WORKTREE_TASK" workspace-task thread-archived :) \
  || fail "teardown must remove an already-gone endpoint when the safety recheck passes"
[ "$TD_SAFE" = retired ] || fail "safe confirmed-gone teardown must report retired"
grep -qxF delete "$PLAYBOT_TEARDOWN_LOG" \
  || fail "safe confirmed-gone teardown did not reach workspace deletion"
pass "confirmed-gone Playbot deletion also requires a passing worktree safety recheck"

# --- fused create record parse (0.94.0+ three-field workspace:create) ----------
# Live 0.107.0 create prints workspace_id<TAB>worktree<TAB>fused_thread_id.
# The spawn isolation check must see the worktree path alone; the pre-fix
# remainder-after-first-tab parse left the thread id fused into WT so the path
# was not a directory.

FUSED_WT="$FIX/worktrees/fused-create"
mkdir -p "$FUSED_WT"
FUSED_WT_ABS=$(cd "$FUSED_WT" && pwd -P)
FUSED_RAW=$(printf 'ws_fused_test\t%s\tchat-fused-abc' "$FUSED_WT_ABS")
FUSED_PARSED=$(fm_backend_playbot_parse_workspace_create "$FUSED_RAW") \
  || fail "three-field create record must parse"
FUSED_WS=${FUSED_PARSED%%$'\t'*}
FUSED_REST=${FUSED_PARSED#*$'\t'}
FUSED_PATH=${FUSED_REST%%$'\t'*}
FUSED_THREAD=${FUSED_REST#*$'\t'}
[ "$FUSED_WS" = ws_fused_test ] || fail "parse must keep the workspace id"
[ "$FUSED_PATH" = "$FUSED_WT_ABS" ] || fail "parse must yield the worktree path alone, got '$FUSED_PATH'"
[ "$FUSED_THREAD" = chat-fused-abc ] || fail "parse must surface the fused thread id"
case "$FUSED_PATH" in *$'\t'*) fail "parsed worktree must not contain a tab" ;; esac
[ -d "$FUSED_PATH" ] || fail "isolation check must see the parsed path as a directory"
NAIVE_WT=${FUSED_RAW#*$'\t'}
[ ! -d "$NAIVE_WT" ] || fail "naive remainder-after-first-tab must not be a directory"
if fm_backend_playbot_parse_workspace_create "$(printf 'ws_legacy\t%s' "$FUSED_WT_ABS")" >/dev/null 2>&1; then
  fail "two-field create record must be refused"
fi
if fm_backend_playbot_parse_workspace_create "$(printf 'ws\t%s\t' "$FUSED_WT_ABS")" >/dev/null 2>&1; then
  fail "create record with an empty fused thread id must be refused"
fi
if fm_backend_playbot_parse_workspace_create "$(printf 'ws\t%s\tchat\textra' "$FUSED_WT_ABS")" >/dev/null 2>&1; then
  fail "four-field create record must be refused"
fi
if fm_backend_playbot_parse_workspace_create "ws-only" >/dev/null 2>&1; then
  fail "single-field create record must be refused"
fi
pass "fused three-field create parse isolates the worktree path for the isolation check"

: > "$TMP_ROOT/create-title.args"
CREATE_TITLE_OUT=$(
  fm_backend_playbot_tool_check() { return 0; }
  fm_backend_playbot_binding_resolve() { printf 'project-title\troot-title\t1\n'; }
  git() { printf '0123456789012345678901234567890123456789\n'; }
  fm_backend_playbot_lane() {
    printf '%s\n' "$*" > "$TMP_ROOT/create-title.args"
    printf 'ws-title\t%s\tthread-title\n' "$FUSED_WT_ABS"
  }
  fm_backend_playbot_workspace_create "$FIX/projects/alpha" fm-title-task HEAD \
    title-task firstmate:title-task:delivery-title
) || fail "workspace_create with a task-specific fused thread title must succeed under a mocked lane"
[ "$CREATE_TITLE_OUT" = "$(printf 'ws-title\t%s\tthread-title' "$FUSED_WT_ABS")" ] \
  || fail "workspace_create must return the lane's fused create record unchanged"
grep -Fq -- '--title firstmate:title-task:delivery-title' "$TMP_ROOT/create-title.args" \
  || fail "workspace_create must pass the task-specific fused thread title to lanes create"
grep -Fq -- '--approval-mode' "$TMP_ROOT/create-title.args" \
  && fail "workspace_create must leave the fixed approval policy to the lane boundary"
pass "workspace_create labels the fused thread through the fixed-policy lane"

: > "$TMP_ROOT/open-thread.args"
THREAD_CREATE_OUT=$(
  fm_backend_playbot_tool_check() { return 0; }
  fm_backend_playbot_lane() {
    printf '%s\n' "$*" > "$TMP_ROOT/open-thread.args"
    printf 'chat-title\n'
  }
  fm_backend_playbot_thread_create workspace-title title-task delivery-title
) || fail "thread_create with the build-thread approval posture must succeed under a mocked lane"
[ "$THREAD_CREATE_OUT" = chat-title ] \
  || fail "thread_create must return the lane's thread id unchanged"
grep -Fq -- '--title firstmate:title-task:delivery-title' "$TMP_ROOT/open-thread.args" \
  || fail "thread_create must pass the task-specific thread title to lanes open-thread"
grep -Fq -- '--approval-mode' "$TMP_ROOT/open-thread.args" \
  && fail "thread_create must leave the fixed approval policy to the lane boundary"
pass "thread_create labels the build thread through the fixed-policy lane"

# --- send_initial effort mapping (medium floor; never low) ---------------------
# Without --effort, lanes mutationSend defaults every order to low. Captain
# rule: Playbot dispatch effort is never low - medium is the floor. 0.107.0
# advertises low|medium|high|xhigh|max|ultra; firstmate medium..ultra pass
# through, low is refused.

[ "$(fm_backend_playbot_map_send_effort medium)" = medium ] \
  || fail "map_send_effort must pass medium through"
[ "$(fm_backend_playbot_map_send_effort high)" = high ] \
  || fail "map_send_effort must pass high through"
[ "$(fm_backend_playbot_map_send_effort xhigh)" = xhigh ] \
  || fail "map_send_effort must pass xhigh through"
[ "$(fm_backend_playbot_map_send_effort max)" = max ] \
  || fail "map_send_effort must pass max through on 0.107 (max is accepted)"
[ "$(fm_backend_playbot_map_send_effort ultra)" = ultra ] \
  || fail "map_send_effort must pass ultra through"
[ "$(fm_backend_playbot_map_send_effort '')" = medium ] \
  || fail "map_send_effort must default an empty effort to medium"
if fm_backend_playbot_map_send_effort low >/dev/null 2>"$TMP_ROOT/effort-low.err"; then
  fail "map_send_effort must refuse low"
fi
grep -qi 'refuses effort .low.' "$TMP_ROOT/effort-low.err" \
  || fail "low refusal must name the floor, got: $(cat "$TMP_ROOT/effort-low.err")"

echo 'brief body' > "$TMP_ROOT/brief-effort.md"
: > "$TMP_ROOT/send-effort.args"
SEND_EFFORT_OUT=$(
  fm_backend_playbot_tool_check() { return 0; }
  fm_backend_playbot_lane() {
    printf '%s\n' "$*" > "$TMP_ROOT/send-effort.args"
    return 0
  }
  fm_backend_playbot_send_initial playbot:thread-complete "$TMP_ROOT/brief-effort.md" \
    delivery-effort digest-effort high
) || fail "send_initial with explicit effort must succeed under a mocked lane"
[ "$SEND_EFFORT_OUT" = accepted ] || fail "send_initial must print accepted on mocked success"
grep -Fq -- '--effort high' "$TMP_ROOT/send-effort.args" \
  || fail "send_initial must pass the mapped effort through to lanes send, got: $(cat "$TMP_ROOT/send-effort.args")"
: > "$TMP_ROOT/send-effort.args"
SEND_DEFAULT_OUT=$(
  fm_backend_playbot_tool_check() { return 0; }
  fm_backend_playbot_lane() {
    printf '%s\n' "$*" > "$TMP_ROOT/send-effort.args"
    return 0
  }
  fm_backend_playbot_send_initial playbot:thread-complete "$TMP_ROOT/brief-effort.md" \
    delivery-effort digest-effort
) || fail "send_initial without effort must succeed under a mocked lane"
[ "$SEND_DEFAULT_OUT" = accepted ] || fail "default-effort send_initial must print accepted"
grep -Fq -- '--effort medium' "$TMP_ROOT/send-effort.args" \
  || fail "send_initial must default --effort to medium when omitted, got: $(cat "$TMP_ROOT/send-effort.args")"
if (
  fm_backend_playbot_tool_check() { return 0; }
  fm_backend_playbot_lane() { return 0; }
  fm_backend_playbot_send_initial playbot:thread-complete "$TMP_ROOT/brief-effort.md" \
    delivery-effort digest-effort low
) >/dev/null 2>"$TMP_ROOT/send-low.err"; then
  fail "send_initial must refuse effort low before calling the lane"
fi
grep -qi 'refuses effort .low.' "$TMP_ROOT/send-low.err" \
  || fail "send_initial low refusal must name the floor, got: $(cat "$TMP_ROOT/send-low.err")"
pass "send_initial maps effort with a medium floor and refuses low"

# --- spawn dirt gate: Playbot injection allowed; any other dirt refused --------
# backend=playbot skips freshen_spawn_worktree_base (pooled fetch/reset) and
# calls fm_backend_playbot_worktree_dirt_allows_launch instead. Playbot injects
# addons/playbot/ plus a project.godot change into every Godot workspace, so a
# fresh mother-clucker-shaped tree is never porcelain-clean; disposable smoke
# projects without project.godot never hit that path.

# Seed a Godot-shaped tree with an existing tracked addons/ tree so Playbot's
# new addon shows as ?? addons/playbot/ (not the collapsed ?? addons/ parent
# that git reports when addons/ itself is brand new).
seed_godot_wt() {  # <dir>
  local dir=$1
  mkdir -p "$dir/addons/other"
  git -C "$dir" init --quiet -b main
  printf 'config_version=5\n' > "$dir/project.godot"
  printf 'tracked\n' > "$dir/README.md"
  printf 'other addon\n' > "$dir/addons/other/plugin.cfg"
  git -C "$dir" add project.godot README.md addons/other/plugin.cfg
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
}
inject_playbot_addon() {  # <dir>
  mkdir -p "$1/addons/playbot"
  printf 'playbot addon\n' > "$1/addons/playbot/plugin.cfg"
  printf 'config_version=5\n; playbot touched\n' > "$1/project.godot"
}

INJECT_WT="$TMP_ROOT/inject-wt"
seed_godot_wt "$INJECT_WT"
inject_playbot_addon "$INJECT_WT"
# Confirm porcelain shape matches a real Godot project after Playbot injects.
inject_status=$(git -C "$INJECT_WT" -c core.quotePath=false status --porcelain)
printf '%s\n' "$inject_status" | grep -q 'project.godot' \
  || fail "inject fixture must dirty project.godot, got: $inject_status"
printf '%s\n' "$inject_status" | grep -Eq 'addons/playbot' \
  || fail "inject fixture must dirty addons/playbot/, got: $inject_status"
fm_backend_playbot_worktree_dirt_allows_launch "$INJECT_WT" \
  || fail "injection-only dirt (addons/playbot/ + modified project.godot) must allow launch"
# Empty status also allows launch.
CLEAN_WT="$TMP_ROOT/clean-wt"
seed_godot_wt "$CLEAN_WT"
fm_backend_playbot_worktree_dirt_allows_launch "$CLEAN_WT" \
  || fail "a clean Playbot worktree must allow launch"
# Any non-injection dirty path must still refuse (and leave the tree untouched).
DIRTY_WT="$TMP_ROOT/dirty-wt"
seed_godot_wt "$DIRTY_WT"
inject_playbot_addon "$DIRTY_WT"
printf 'keep this local work\n' > "$DIRTY_WT/uncommitted.txt"
before_head=$(git -C "$DIRTY_WT" rev-parse HEAD)
if fm_backend_playbot_worktree_dirt_allows_launch "$DIRTY_WT" >/dev/null 2>"$TMP_ROOT/dirty.err"; then
  fail "a Playbot worktree dirty outside injection paths must refuse launch"
fi
grep -q 'is not clean' "$TMP_ROOT/dirty.err" \
  || fail "non-injection dirt refusal must say the worktree is not clean, got: $(cat "$TMP_ROOT/dirty.err")"
[ "$(git -C "$DIRTY_WT" rev-parse HEAD)" = "$before_head" ] \
  || fail "dirt refusal must not move HEAD on a Playbot worktree"
assert_grep 'keep this local work' "$DIRTY_WT/uncommitted.txt" \
  "dirt refusal must not discard unexpected uncommitted work"
# Pure status classifier: injection-only vs mixed.
fm_backend_playbot_status_is_injection_only "$(printf ' M project.godot\n?? addons/playbot/\n')" \
  || fail "status_is_injection_only must accept project.godot + addons/playbot/"
if fm_backend_playbot_status_is_injection_only "$(printf ' M project.godot\n?? uncommitted.txt\n')"; then
  fail "status_is_injection_only must refuse when any non-injection path is dirty"
fi
if fm_backend_playbot_status_is_injection_only "$(printf ' M README.md\n')"; then
  fail "status_is_injection_only must refuse a modified non-injection path"
fi
pass "Playbot spawn dirt gate allows injection-only dirt and refuses any other dirty path"

# --- spawn commit and worker-started recovery (plan 3.4 / V2SIM-4) ---------

make_playbot_spawn_lane() {  # <case-dir>
  local case_dir=$1 lane
  lane="$case_dir/fake-playbot-lanes.mjs"
  cat > "$lane" <<'JS'
#!/usr/bin/env node
import { appendFileSync } from 'node:fs';

const [command] = process.argv.slice(2);
appendFileSync(process.env.FM_PLAYBOT_TEST_LOG, `${command}\n`);
switch (command) {
  case 'ready':
  case 'archive':
  case 'delete':
  case 'cleanup-state':
    break;
  case 'route-write':
    appendFileSync(process.env.FM_PLAYBOT_TEST_ROUTE_PATH, 'attempted route\n');
    break;
  case 'binding-resolve':
    process.stdout.write(`${process.env.FM_PLAYBOT_TEST_BINDING ?? 'project-fixture\troot-fixture\t1'}\n`);
    break;
  case 'validate-endpoint':
    if (process.env.FM_PLAYBOT_TEST_ENDPOINT_RC === '1') process.exitCode = 1;
    break;
  case 'create':
    process.stdout.write(`workspace-fixture\t${process.env.FM_PLAYBOT_TEST_WORKTREE}\tthread-fixture\n`);
    break;
  case 'send':
    break;
  default:
    process.stderr.write(`unexpected fake Playbot command: ${command}\n`);
    process.exitCode = 1;
}
JS
  chmod +x "$lane"
  printf '%s\n' "$lane"
}

make_playbot_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project worktree fakebin lane log
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  log="$case_dir/playbot.log"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  git -C "$project" worktree add --quiet --detach "$worktree" HEAD
  tasks-axi add "$id" "Playbot spawn fixture" --kind ship \
    --file "$home/data/backlog.md" >/dev/null || fail "could not seed the Playbot spawn backlog row"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fakebin" codex)
  lane=$(make_playbot_spawn_lane "$case_dir")
  : > "$log"
  printf '%s\n' "$home|$project|$worktree|$fakebin|$lane|$log"
}

read_playbot_spawn_case() {
  IFS='|' read -r SPAWN_HOME SPAWN_PROJECT SPAWN_WORKTREE SPAWN_FAKEBIN SPAWN_LANE SPAWN_LOG <<EOF
$1
EOF
}

run_playbot_spawn() {  # <id> [mode] [yolo]
  local id=$1 mode=${2:-local-only} yolo=${3:-off}
  FM_PLAYBOT_LANES_OVERRIDE="$SPAWN_LANE" \
    FM_PLAYBOT_TEST_LOG="$SPAWN_LOG" \
    FM_PLAYBOT_TEST_WORKTREE="$SPAWN_WORKTREE" \
    FM_PLAYBOT_TEST_ROUTE_PATH="$SPAWN_HOME/state/$id.playbot-route.json" \
    fm_test_run_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_FAKEBIN" \
      "$id" "$SPAWN_PROJECT" --mode "$mode" --yolo "$yolo" \
      --backend playbot --harness codex --effort xhigh
}

fail_playbot_backlog_start() {  # <fakebin>
  local fakebin=$1 real
  real=$(command -v tasks-axi)
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: "backlog is unwritable"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
}

playbot_backlog_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null \
    | sed -n 's/^  state: *//p' | head -1
}

test_fresh_playbot_spawn_commits_record_and_backlog() {
  local id=playbot-fresh-v2 rec out status
  rec=$(make_playbot_spawn_case fresh "$id")
  read_playbot_spawn_case "$rec"

  out=$(run_playbot_spawn "$id")
  status=$?
  expect_code 0 "$status" "fresh Playbot spawn should succeed"$'\n'"$out"
  assert_present "$SPAWN_HOME/state/$id.meta" \
    "fresh Playbot spawn rolled back its published task record"
  [ "$(playbot_backlog_state "$SPAWN_HOME" "$id")" = in_flight ] \
    || fail "fresh Playbot spawn did not commit its backlog row to In flight"
  assert_present "$SPAWN_HOME/state/$id.check.sh" \
    "fresh Playbot spawn did not install its reconciliation check"
  assert_present "$SPAWN_HOME/state/$id.check-trust" \
    "fresh Playbot spawn did not register its reconciliation check"
  assert_grep 'mode=local-only' "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" \
    "fresh Playbot spawn did not bind its mode in the transaction"
  assert_grep 'yolo=off' "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" \
    "fresh Playbot spawn did not bind its merge authority in the transaction"
  pass "fresh Playbot spawn keeps its task record and commits the backlog transition"
}

test_worker_started_reentry_commits_without_redispatch() {
  local id=playbot-reentry-v2 rec out status
  rec=$(make_playbot_spawn_case reentry "$id")
  read_playbot_spawn_case "$rec"
  mkdir -p "$SPAWN_HOME/state/.playbot-dispatch"
  cat > "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" <<EOF
task_id=$id
brief_digest=digest-fixture
project_binding_gen=1
requested_base=HEAD
delivery_id=delivery-fixture
state=worker-started
workspace_id=workspace-fixture
thread_id=thread-fixture
playbot_project_id=project-fixture
playbot_project_root_id=root-fixture
worktree=$SPAWN_WORKTREE
EOF
  printf 'worker-owned change\n' > "$SPAWN_WORKTREE/worker-change.txt"

  out=$(run_playbot_spawn "$id")
  status=$?
  expect_code 0 "$status" "worker-started Playbot re-entry should succeed"$'\n'"$out"
  assert_present "$SPAWN_HOME/state/$id.meta" \
    "worker-started re-entry did not republish the task record"
  assert_grep 'playbot_workspace_id=workspace-fixture' "$SPAWN_HOME/state/$id.meta" \
    "worker-started re-entry did not preserve the transaction workspace"
  assert_grep 'playbot_thread_id=thread-fixture' "$SPAWN_HOME/state/$id.meta" \
    "worker-started re-entry did not preserve the transaction thread"
  assert_grep "worktree=$SPAWN_WORKTREE" "$SPAWN_HOME/state/$id.meta" \
    "worker-started re-entry did not preserve the transaction worktree"
  [ "$(playbot_backlog_state "$SPAWN_HOME" "$id")" = in_flight ] \
    || fail "worker-started re-entry did not commit its backlog row to In flight"
  assert_present "$SPAWN_HOME/state/$id.check.sh" \
    "worker-started re-entry did not install its reconciliation check"
  assert_present "$SPAWN_HOME/state/$id.check-trust" \
    "worker-started re-entry did not register its reconciliation check"
  [ "$(grep -c '^route-write$' "$SPAWN_LOG" || true)" -eq 1 ] \
    || fail "worker-started re-entry did not republish its route exactly once"
  [ "$(grep -Ec '^(create|open-thread|send)$' "$SPAWN_LOG" || true)" -eq 0 ] \
    || fail "worker-started re-entry created a second Playbot resource or resent the brief"
  pass "worker-started Playbot re-entry republishes and commits without redispatch"
}

test_fresh_playbot_backlog_failure_retires_worker() {
  local id=playbot-fresh-backlog-fails-v2 rec out status=0
  rec=$(make_playbot_spawn_case fresh-backlog-fails "$id")
  read_playbot_spawn_case "$rec"
  fail_playbot_backlog_start "$SPAWN_FAKEBIN"

  out=$(run_playbot_spawn "$id") || status=$?
  [ "$status" -ne 0 ] || fail "fresh Playbot spawn succeeded after its backlog commit failed"
  assert_contains "$out" "could not be moved to In flight" \
    "fresh Playbot spawn did not report its backlog commit failure"
  [ "$(playbot_backlog_state "$SPAWN_HOME" "$id")" = queued ] \
    || fail "failed fresh Playbot spawn changed its queued backlog row"
  [ "$(grep -c '^archive$' "$SPAWN_LOG" || true)" -eq 1 ] \
    || fail "failed fresh Playbot spawn did not retire its thread exactly once"
  [ "$(grep -c '^delete$' "$SPAWN_LOG" || true)" -eq 1 ] \
    || fail "failed fresh Playbot spawn did not retire its workspace exactly once"
  [ "$(grep -c '^cleanup-state$' "$SPAWN_LOG" || true)" -eq 1 ] \
    || fail "failed fresh Playbot spawn did not confirm cleanup exactly once"
  assert_absent "$SPAWN_HOME/state/$id.meta" \
    "failed fresh Playbot spawn retained its provisional task record"
  assert_absent "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" \
    "failed fresh Playbot spawn retained its cleaned transaction"
  assert_absent "$SPAWN_HOME/state/$id.playbot-route.json" \
    "failed fresh Playbot spawn retained its cleaned route"
  assert_absent "$SPAWN_HOME/state/$id.check.sh" \
    "failed fresh Playbot spawn retained its reconciliation check"
  assert_absent "$SPAWN_HOME/state/$id.check-trust" \
    "failed fresh Playbot spawn retained its reconciliation registration"
  pass "fresh Playbot backlog failure retires the uncommitted worker"
}

test_worker_started_reentry_backlog_failure_preserves_worker() {
  local id=playbot-reentry-backlog-fails-v2 rec out status=0
  rec=$(make_playbot_spawn_case reentry-backlog-fails "$id")
  read_playbot_spawn_case "$rec"
  mkdir -p "$SPAWN_HOME/state/.playbot-dispatch"
  cat > "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" <<EOF
task_id=$id
brief_digest=digest-fixture
project_binding_gen=1
requested_base=HEAD
delivery_id=delivery-fixture
state=worker-started
workspace_id=workspace-fixture
thread_id=thread-fixture
playbot_project_id=project-fixture
playbot_project_root_id=root-fixture
worktree=$SPAWN_WORKTREE
EOF
  printf 'worker-owned change\n' > "$SPAWN_WORKTREE/worker-change.txt"
  fail_playbot_backlog_start "$SPAWN_FAKEBIN"

  out=$(run_playbot_spawn "$id") || status=$?
  [ "$status" -ne 0 ] || fail "worker-started re-entry succeeded after its backlog commit failed"
  assert_contains "$out" "could not be moved to In flight" \
    "worker-started re-entry did not report its backlog commit failure"
  [ "$(playbot_backlog_state "$SPAWN_HOME" "$id")" = queued ] \
    || fail "failed worker-started re-entry changed its queued backlog row"
  [ "$(grep -Ec '^(archive|delete|cleanup-state)$' "$SPAWN_LOG" || true)" -eq 0 ] \
    || fail "failed worker-started re-entry retired the existing worker"
  assert_present "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" \
    "failed worker-started re-entry removed the recovery transaction"
  assert_grep 'state=worker-started' "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" \
    "failed worker-started re-entry changed the recoverable transaction state"
  assert_absent "$SPAWN_HOME/state/$id.meta" \
    "failed worker-started re-entry retained its provisional task record"
  assert_absent "$SPAWN_HOME/state/$id.playbot-route.json" \
    "failed worker-started re-entry retained its attempted route"
  assert_absent "$SPAWN_HOME/state/$id.check.sh" \
    "failed worker-started re-entry retained its reconciliation check"
  assert_absent "$SPAWN_HOME/state/$id.check-trust" \
    "failed worker-started re-entry retained its reconciliation registration"
  pass "worker-started backlog failure preserves the existing worker"
}

test_worker_started_reentry_refuses_changed_project_binding() {
  local id=playbot-reentry-binding-mismatch-v2 rec out status=0
  rec=$(make_playbot_spawn_case reentry-binding-mismatch "$id")
  read_playbot_spawn_case "$rec"
  mkdir -p "$SPAWN_HOME/state/.playbot-dispatch"
  cat > "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" <<EOF
task_id=$id
brief_digest=digest-fixture
project_binding_gen=1
requested_base=HEAD
delivery_id=delivery-fixture
state=worker-started
workspace_id=workspace-fixture
thread_id=thread-fixture
playbot_project_id=project-fixture
playbot_project_root_id=root-fixture
worktree=$SPAWN_WORKTREE
EOF

  out=$(FM_PLAYBOT_TEST_BINDING=$'project-other\troot-other\t2' run_playbot_spawn "$id") || status=$?
  [ "$status" -ne 0 ] || fail "worker-started re-entry adopted a mismatched project binding"
  assert_contains "$out" "project binding does not match" \
    "worker-started re-entry did not explain the project-binding mismatch"
  [ "$(playbot_backlog_state "$SPAWN_HOME" "$id")" = queued ] \
    || fail "binding-mismatched re-entry changed its queued backlog row"
  [ "$(grep -Ec '^(create|open-thread|send|route-write|archive|delete|cleanup-state)$' "$SPAWN_LOG" || true)" -eq 0 ] \
    || fail "binding-mismatched re-entry mutated the existing worker or recovery wiring"
  assert_present "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" \
    "binding-mismatched re-entry removed the recovery transaction"
  assert_absent "$SPAWN_HOME/state/$id.meta" \
    "binding-mismatched re-entry published a task record"
  pass "worker-started re-entry refuses a changed project binding"
}

test_worker_started_reentry_refuses_missing_endpoint() {
  local id=playbot-reentry-missing-endpoint-v2 rec out status=0
  rec=$(make_playbot_spawn_case reentry-missing-endpoint "$id")
  read_playbot_spawn_case "$rec"
  mkdir -p "$SPAWN_HOME/state/.playbot-dispatch"
  cat > "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" <<EOF
task_id=$id
brief_digest=digest-fixture
project_binding_gen=1
requested_base=HEAD
delivery_id=delivery-fixture
state=worker-started
workspace_id=workspace-fixture
thread_id=thread-fixture
playbot_project_id=project-fixture
playbot_project_root_id=root-fixture
worktree=$SPAWN_WORKTREE
EOF

  out=$(FM_PLAYBOT_TEST_ENDPOINT_RC=1 run_playbot_spawn "$id") || status=$?
  [ "$status" -ne 0 ] || fail "worker-started re-entry accepted a missing endpoint"
  assert_contains "$out" "recovery endpoint validation failed" \
    "worker-started re-entry did not explain the endpoint-validation failure"
  [ "$(playbot_backlog_state "$SPAWN_HOME" "$id")" = queued ] \
    || fail "missing-endpoint re-entry changed its queued backlog row"
  [ "$(grep -c '^validate-endpoint$' "$SPAWN_LOG" || true)" -eq 1 ] \
    || fail "missing-endpoint re-entry did not validate its recorded endpoint exactly once"
  [ "$(grep -Ec '^(create|open-thread|send|archive|delete)$' "$SPAWN_LOG" || true)" -eq 0 ] \
    || fail "missing-endpoint re-entry recreated or retired Playbot resources"
  assert_present "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" \
    "missing-endpoint re-entry removed the recovery transaction"
  assert_absent "$SPAWN_HOME/state/$id.meta" \
    "missing-endpoint re-entry retained its provisional task record"
  assert_absent "$SPAWN_HOME/state/$id.playbot-route.json" \
    "missing-endpoint re-entry retained its attempted route"
  assert_absent "$SPAWN_HOME/state/$id.check.sh" \
    "missing-endpoint re-entry registered a reconciliation check"
  assert_absent "$SPAWN_HOME/state/$id.check-trust" \
    "missing-endpoint re-entry registered reconciliation trust"
  pass "worker-started re-entry refuses a missing endpoint"
}

test_worker_started_reentry_refuses_posture_changes() {
  local id rec out status

  id=playbot-reentry-yolo-mismatch-v2
  rec=$(make_playbot_spawn_case reentry-yolo-mismatch "$id")
  read_playbot_spawn_case "$rec"
  mkdir -p "$SPAWN_HOME/state/.playbot-dispatch"
  cat > "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" <<EOF
task_id=$id
brief_digest=digest-fixture
project_binding_gen=1
requested_base=HEAD
mode=local-only
yolo=off
delivery_id=delivery-fixture
state=worker-started
workspace_id=workspace-fixture
thread_id=thread-fixture
playbot_project_id=project-fixture
playbot_project_root_id=root-fixture
worktree=$SPAWN_WORKTREE
EOF
  status=0
  out=$(run_playbot_spawn "$id" local-only on) || status=$?
  [ "$status" -ne 0 ] || fail "worker-started re-entry escalated its recorded yolo posture"
  assert_contains "$out" "delivery posture mode=local-only yolo=off does not match requested mode=local-only yolo=on" \
    "worker-started re-entry did not explain the yolo mismatch"
  assert_absent "$SPAWN_HOME/state/$id.meta" \
    "yolo-mismatched re-entry published a task record"
  [ "$(grep -Ec '^(create|open-thread|send|route-write|archive|delete|cleanup-state)$' "$SPAWN_LOG" || true)" -eq 0 ] \
    || fail "yolo-mismatched re-entry mutated the existing worker or recovery wiring"

  id=playbot-reentry-mode-mismatch-v2
  rec=$(make_playbot_spawn_case reentry-mode-mismatch "$id")
  read_playbot_spawn_case "$rec"
  mkdir -p "$SPAWN_HOME/state/.playbot-dispatch"
  cat > "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" <<EOF
task_id=$id
brief_digest=digest-fixture
project_binding_gen=1
requested_base=HEAD
mode=no-mistakes
yolo=off
delivery_id=delivery-fixture
state=worker-started
workspace_id=workspace-fixture
thread_id=thread-fixture
playbot_project_id=project-fixture
playbot_project_root_id=root-fixture
worktree=$SPAWN_WORKTREE
EOF
  status=0
  out=$(run_playbot_spawn "$id") || status=$?
  [ "$status" -ne 0 ] || fail "worker-started re-entry changed its recorded delivery mode"
  assert_contains "$out" "delivery posture mode=no-mistakes yolo=off does not match requested mode=local-only yolo=off" \
    "worker-started re-entry did not explain the mode mismatch"
  assert_absent "$SPAWN_HOME/state/$id.meta" \
    "mode-mismatched re-entry published a task record"
  [ "$(grep -Ec '^(create|open-thread|send|route-write|archive|delete|cleanup-state)$' "$SPAWN_LOG" || true)" -eq 0 ] \
    || fail "mode-mismatched re-entry mutated the existing worker or recovery wiring"

  id=playbot-reentry-legacy-yolo-v2
  rec=$(make_playbot_spawn_case reentry-legacy-yolo "$id")
  read_playbot_spawn_case "$rec"
  mkdir -p "$SPAWN_HOME/state/.playbot-dispatch"
  cat > "$SPAWN_HOME/state/.playbot-dispatch/$id.txn" <<EOF
task_id=$id
brief_digest=digest-fixture
project_binding_gen=1
requested_base=HEAD
delivery_id=delivery-fixture
state=worker-started
workspace_id=workspace-fixture
thread_id=thread-fixture
playbot_project_id=project-fixture
playbot_project_root_id=root-fixture
worktree=$SPAWN_WORKTREE
EOF
  status=0
  out=$(run_playbot_spawn "$id" local-only on) || status=$?
  [ "$status" -ne 0 ] || fail "legacy worker-started re-entry escalated yolo authority"
  assert_contains "$out" "legacy playbot txn $id can recover only with mode=local-only yolo=off" \
    "legacy worker-started re-entry did not explain its restricted recovery posture"
  assert_absent "$SPAWN_HOME/state/$id.meta" \
    "legacy yolo-on re-entry published a task record"
  [ "$(grep -Ec '^(create|open-thread|send|route-write|archive|delete|cleanup-state)$' "$SPAWN_LOG" || true)" -eq 0 ] \
    || fail "legacy yolo-on re-entry mutated the existing worker or recovery wiring"
  pass "worker-started re-entry refuses recorded and legacy posture changes"
}

test_fresh_playbot_spawn_commits_record_and_backlog
test_worker_started_reentry_commits_without_redispatch
test_fresh_playbot_backlog_failure_retires_worker
test_worker_started_reentry_backlog_failure_preserves_worker
test_worker_started_reentry_refuses_changed_project_binding
test_worker_started_reentry_refuses_missing_endpoint
test_worker_started_reentry_refuses_posture_changes

printf 'fm-playbot-backend: all tests passed\n'
