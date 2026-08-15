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
cp "$STATE/be-ep.meta" "$STATE/be-bad.meta"
if fm_backend_playbot_route_write "$STATE" be-bad 1 1 project-alpha root-alpha \
  workspace-task thread-WRONG delivery-be-ep "$WORKTREE_TASK" >/dev/null 2>&1; then
  fail "route_write must refuse a dispatch identity that disagrees with the published meta"
fi
[ ! -e "$STATE/be-bad.playbot-route.json" ] || fail "a refused route_write must not leave a record behind"
fm_backend_playbot_validate_endpoint "$STATE/be-ep.meta" || fail "adapter endpoint validation must accept the bound endpoint"
sed -i '' 's/window=playbot:thread-complete/window=session:window/' "$STATE/be-ep.meta"
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
  "$WORKTREE_TASK" workspace-task thread-complete 2>"$TMP_ROOT/td.err") && TD_RC=0 || TD_RC=$?
[ "$TD_RC" -ne 0 ] || fail "teardown must refuse a live endpoint when archive/stop cannot complete"
case "$TD_OUT" in refuse:*) : ;; *) fail "teardown refusal must print a refuse:<reason> proof token, got $TD_OUT" ;; esac
TD_RET=$(fm_backend_playbot_teardown "$STATE/be-ep.meta" be-ep playbot:thread-archived \
  "$WORKTREE_TASK" workspace-task thread-archived) \
  || fail "an already-gone endpoint must report retained or retired, not refuse"
case "$TD_RET" in retained:*|retired) : ;; *) fail "already-gone teardown must print retained:<reason> or retired, got $TD_RET" ;; esac
TD_MM=$(fm_backend_playbot_teardown "$STATE/be-ep.meta" be-ep playbot:thread-complete \
  "$WORKTREE_TASK" workspace-task thread-OTHER 2>/dev/null) && TD_RC=0 || TD_RC=$?
[ "$TD_RC" -ne 0 ] && [ "$TD_MM" = 'refuse:target-thread-mismatch' ] \
  || fail "teardown must refuse a target/thread identity mismatch"
pass "teardown refuses live/mismatched endpoints and reports retained/retired for a confirmed-gone thread"

printf 'fm-playbot-backend: all tests passed\n'
