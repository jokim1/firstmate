#!/usr/bin/env bash
# tests/fm-playbot-backend.test.sh - hermetic contract tests for the Playbot
# backend adapter bin/backends/playbot.sh (plan v3 section 1.2's adapter
# table and 4.1's send semantics). The adapter is sourced directly because the
# shared-core registration seam belongs to the parallel core-seam lane; every
# function is exercised through the same names that seam will dispatch to.
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
grep -q 'PHASE1-EVIDENCE-REQUIRED' "$TMP_ROOT/rtc.err" || fail "runtime check refusal must carry the phase marker"
pass "runtime check refuses spawn intake with PHASE1-EVIDENCE-REQUIRED"

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
for call in "fm_backend_playbot_kill playbot:thread-complete" \
            "fm_backend_playbot_remove_worktree workspace-task" \
            "fm_backend_playbot_interrupt playbot:thread-complete" \
            "fm_backend_playbot_create some-task /tmp/whatever" \
            "fm_backend_playbot_send_initial some-task /tmp/whatever.md"; do
  if $call >/dev/null 2>"$TMP_ROOT/lc.err"; then
    fail "'$call' must refuse before Phase 1 evidence"
  fi
  grep -q 'PHASE1-EVIDENCE-REQUIRED' "$TMP_ROOT/lc.err" || fail "'$call' must refuse with the phase marker"
done
pass "kill/remove/interrupt/create/send-initial all refuse with PHASE1-EVIDENCE-REQUIRED before mutation"

# --- endpoint validation through the adapter ------------------------------------

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
DIGEST=$(node "$ROOT/bin/fm-playbot-lanes.mjs" meta-digest --meta "$STATE/be-ep.meta")
cat > "$STATE/be-ep.playbot-route.json" <<EOF
{
  "schema": "firstmate.playbot.route.v1",
  "home": "$HOME_DIR",
  "taskId": "be-ep",
  "spawnGen": 1,
  "routeGen": 1,
  "metaDigest": "$DIGEST",
  "threadId": "thread-complete",
  "workspaceId": "workspace-task",
  "projectId": "project-alpha",
  "projectRootId": "root-alpha",
  "playbotSessionId": null,
  "worktree": "$WORKTREE_TASK"
}
EOF
chmod 0600 "$STATE/be-ep.playbot-route.json"
fm_backend_playbot_validate_endpoint "$STATE/be-ep.meta" || fail "adapter endpoint validation must accept the bound endpoint"
sed -i '' 's/window=playbot:thread-complete/window=session:window/' "$STATE/be-ep.meta"
if fm_backend_playbot_validate_endpoint "$STATE/be-ep.meta" >/dev/null 2>&1; then
  fail "adapter endpoint validation must reject a non-playbot window shape"
fi
pass "endpoint validation enforces the exact playbot:<thread-id> window and bound route"

printf 'fm-playbot-backend: all tests passed\n'
