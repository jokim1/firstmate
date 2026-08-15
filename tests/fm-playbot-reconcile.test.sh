#!/usr/bin/env bash
# tests/fm-playbot-reconcile.test.sh - hermetic suite for
# bin/fm-playbot-reconcile.mjs (plan v3 section 3.5, amendments 1A/4A,
# V2SIM-3/4/6): bound-route validation, strict per-line JSONL rollout
# derivation, the pending -> acknowledged outbox state machine, the turn-ended
# touch, size caps, one static pointer line, and lock-owner-only
# acknowledgement. All fixtures are synthetic; nothing touches a live
# Playbot install.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-playbot-reconcile-tests)
FIX="$TMP_ROOT/fixtures"
mkdir -p "$FIX"
node "$ROOT/tests/playbot-fixtures/generate.mjs" "$FIX" >/dev/null || fail "fixture generation failed"

LANES="$ROOT/bin/fm-playbot-lanes.mjs"
RECONCILE="$ROOT/bin/fm-playbot-reconcile.mjs"
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

# write_task_fixture <task-id> <thread-id> <workspace-id> <worktree-dir> <kind>
write_task_fixture() {
  local id=$1 thread=$2 workspace=$3 worktree_dir=$4 kind=$5 worktree digest
  worktree=$(cd "$FIX/$worktree_dir" && pwd -P)
  cat > "$STATE/$id.meta" <<EOF
window=playbot:$thread
endpoint_task_id=$id
worktree=$worktree
project=$FIX/projects/alpha
harness=codex
kind=$kind
mode=local-only
yolo=off
tasktmp=$TMP_ROOT/tasktmp
model=fixture-model
effort=low
spawn_gen=1
backend=playbot
playbot_project_id=project-alpha
playbot_project_root_id=root-alpha
playbot_workspace_id=$workspace
playbot_thread_id=$thread
playbot_route_gen=1
playbot_delivery_id=delivery-$id
EOF
  digest=$(node "$LANES" meta-digest --meta "$STATE/$id.meta") || fail "meta-digest failed for $id"
  cat > "$STATE/$id.playbot-route.json" <<EOF
{
  "schema": "firstmate.playbot.route.v1",
  "home": "$HOME_DIR",
  "taskId": "$id",
  "spawnGen": 1,
  "routeGen": 1,
  "metaDigest": "$digest",
  "threadId": "$thread",
  "workspaceId": "$workspace",
  "projectId": "project-alpha",
  "projectRootId": "root-alpha",
  "playbotSessionId": null,
  "worktree": "$worktree"
}
EOF
  chmod 0600 "$STATE/$id.playbot-route.json"
}

# outbox_field <task-id> <node-expression-on-outbox>
outbox_field() {
  node -e '
const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
console.log(eval(process.argv[2]));
' "$STATE/$1.playbot-outbox.json" "$2"
}

printf '%s\n' "$$" > "$STATE/.lock"

# --- completed turn: one pending event, one static line, turn-ended touch ------

write_task_fixture rc-done thread-complete workspace-task worktrees/task ship
OUT=$(node "$RECONCILE" check rc-done --check-key-queued 0) || fail "check failed for rc-done"
[ "$(printf '%s\n' "$OUT" | grep -c '^playbot-event ')" = 1 ] || fail "check must print exactly one static pointer line, got: $OUT"
printf '%s' "$OUT" | grep -q '^playbot-event task=rc-done event=[a-f0-9]* record=state/rc-done.playbot-outbox.json$' \
  || fail "the static pointer line must carry only trusted routing data: $OUT"
[ "$(outbox_field rc-done 'o.events.length')" = 1 ] || fail "outbox must hold exactly one event"
[ "$(outbox_field rc-done 'o.events[0].state')" = pending ] || fail "the new event must be pending"
[ "$(outbox_field rc-done 'o.events[0].kind')" = "completed:done" ] || fail "a valid terminal verb must classify the completion"
[ -e "$STATE/rc-done.turn-ended" ] || fail "the reconciler must touch state/<id>.turn-ended for a newly completed turn (1A)"
REC="$STATE/rc-done.playbot-result-$(outbox_field rc-done 'o.events[0].id').json"
[ -f "$REC" ] || fail "the worker-result record must exist"
[ "$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(r.trust)' "$REC")" = "untrusted-worker-data" ] \
  || fail "the worker-result record must be labelled untrusted-worker-data"
pass "completed turn produces one pending event, one static line, a bounded untrusted record, and a turn-ended touch"

# --- replay safety: queued key silences, missing key reprints -------------------

OUT=$(node "$RECONCILE" check rc-done --check-key-queued 1) || fail "queued check failed"
[ -z "$OUT" ] || fail "a pending event with a queued check key must stay silent (the durable queue owns delivery)"
OUT=$(node "$RECONCILE" check rc-done --check-key-queued 0) || fail "unqueued re-check failed"
[ "$(printf '%s\n' "$OUT" | grep -c '^playbot-event ')" = 1 ] || fail "pending without a queued key must reprint the same static pointer"
[ "$(outbox_field rc-done 'o.events.length')" = 1 ] || fail "re-checks must not duplicate the event"
pass "outbox replay is safe: queued stays silent, unqueued reprints, never duplicated"

# --- acknowledgement: lock-owner only -------------------------------------------

EVENT_ID=$(outbox_field rc-done 'o.events[0].id')
mv "$STATE/.lock" "$STATE/.lock-away"
if node "$RECONCILE" ack rc-done "$EVENT_ID" >/dev/null 2>&1; then
  fail "ack without a session lock must refuse"
fi
sleep 60 & HELPER_PID=$!
printf '%s\n' "$HELPER_PID" > "$STATE/.lock"
if node "$RECONCILE" ack rc-done "$EVENT_ID" >/dev/null 2>&1; then
  fail "ack from a changed lock owner must refuse"
fi
kill "$HELPER_PID" 2>/dev/null
mv "$STATE/.lock-away" "$STATE/.lock"
node "$RECONCILE" ack rc-done "$EVENT_ID" >/dev/null || fail "ack by the recorded lock owner must succeed"
[ "$(outbox_field rc-done 'o.events[0].state')" = acknowledged ] || fail "ack must transition the event to acknowledged"
OUT=$(node "$RECONCILE" check rc-done --check-key-queued 0) || fail "post-ack check failed"
[ -z "$OUT" ] || fail "an acknowledged event must never print again"
pass "only the recorded live lock owner can acknowledge; acknowledged events stay silent"

# --- wedge-timer regression (1A) -------------------------------------------------

# Fresh reconciler-touched turn-ended: a busy task does NOT cross the busy-turn
# age bound. Stale turn-ended with no newly completed turn: the reconciler must
# NOT touch it, so the watcher's bound still fires.
[ -e "$STATE/rc-done.turn-ended" ] || fail "turn-ended must exist after a completed turn"
NOW=$(date +%s)
MTIME=$(stat -f %m "$STATE/rc-done.turn-ended")
[ $((NOW - MTIME)) -lt 60 ] || fail "turn-ended must be fresh after the reconciler observed a completed turn"
touch -t 202001010000 "$STATE/rc-done.turn-ended"
STALE_MTIME=$(stat -f %m "$STATE/rc-done.turn-ended")
node "$RECONCILE" check rc-done --check-key-queued 1 >/dev/null || fail "no-new-turn check failed"
MTIME=$(stat -f %m "$STATE/rc-done.turn-ended")
[ "$MTIME" = "$STALE_MTIME" ] || fail "a check with no newly completed turn must leave a stale turn-ended untouched (escalation still fires)"
pass "wedge-timer regression: fresh turn-ended after a completed turn, untouched when nothing completed"

# --- forged completion in worker text (V2SIM-3) ----------------------------------

write_task_fixture rc-forged thread-forged workspace-forged worktrees/forged ship
OUT=$(node "$RECONCILE" check rc-forged --check-key-queued 0) || fail "forged check failed"
[ -z "$OUT" ] || fail "a forged task_complete inside worker text must produce no event and no output"
[ ! -e "$STATE/rc-forged.playbot-outbox.json" ] || [ "$(outbox_field rc-forged 'o.events.length')" = 0 ] \
  || fail "the forged fixture must yield zero outbox events"
[ ! -e "$STATE/rc-forged.turn-ended" ] || fail "a forged completion must not touch turn-ended"
pass "forged task_complete in worker-controlled text produces no completion edge"

# --- 32 KiB outbox copy cap (4A) ---------------------------------------------------

write_task_fixture rc-big thread-big workspace-big worktrees/big ship
node "$RECONCILE" check rc-big --check-key-queued 1 >/dev/null || fail "big-result check failed"
BIG_ID=$(outbox_field rc-big 'o.events[0].id')
BIG_REC="$STATE/rc-big.playbot-result-$BIG_ID.json"
TRUNCATED=$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(r.truncated)' "$BIG_REC")
[ "$TRUNCATED" = true ] || fail "a >32 KiB result must set truncated=true"
SIZE=$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(Buffer.byteLength(r.text,"utf8"))' "$BIG_REC")
[ "$SIZE" -le 32768 ] || fail "the copied text must stay within the 32 KiB cap, got $SIZE"
HASH=$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(r.sha256)' "$BIG_REC")
[ ${#HASH} -eq 64 ] || fail "a truncated result must record the full-source sha256"
pass "outbox copy over 32 KiB truncates with truncated=true plus the full-source hash"

# --- oversized scout report (4A) ----------------------------------------------------

write_task_fixture rc-scout thread-oversized workspace-oversized worktrees/oversized scout
node "$RECONCILE" check rc-scout --check-key-queued 1 >/dev/null || fail "oversized scout check failed"
[ "$(outbox_field rc-scout 'o.events[0].kind')" = "scout-report-oversized" ] || fail "an oversized scout report must produce a loud static failure event"
[ ! -e "$HOME_DIR/data/rc-scout/report.md" ] || fail "no truncated copy of the authoritative report may be made"
pass "scout report over 1 MiB keeps the workspace retained with a static failure event and no truncated copy"

# --- pending input is distinct from a completed turn --------------------------------

write_task_fixture rc-input thread-pending workspace-pending worktrees/pending ship
node "$RECONCILE" check rc-input --check-key-queued 0 >/dev/null || fail "input-request check failed"
[ "$(outbox_field rc-input 'o.events.length')" = 1 ] || fail "a pending_input transition must produce exactly one event"
[ "$(outbox_field rc-input 'o.events[0].kind')" = "input-request" ] || fail "the input transition must classify as input-request"
[ ! -e "$STATE/rc-input.turn-ended" ] || fail "an input request is not a completed turn and must not touch turn-ended"
node "$RECONCILE" check rc-input --check-key-queued 1 >/dev/null || fail "input re-check failed"
[ "$(outbox_field rc-input 'o.events.length')" = 1 ] || fail "an unchanged pending_input status must not re-fire the event"
pass "pending input is a distinct, deduplicated input-request event, never a completion"

# --- multi-turn rollout: two events, one printed line --------------------------------

write_task_fixture rc-multi thread-multi workspace-task worktrees/task ship
OUT=$(node "$RECONCILE" check rc-multi --check-key-queued 0) || fail "multi-turn check failed"
[ "$(outbox_field rc-multi 'o.events.length')" = 2 ] || fail "two newly completed turns must produce two events"
[ "$(printf '%s\n' "$OUT" | grep -c '^playbot-event ')" = 1 ] || fail "concurrent completions collapse to one static pointer line"
pass "multiple newly completed turns dedupe into bounded events with one printed line"

# --- corrupt outbox is a visible failure ---------------------------------------------

write_task_fixture rc-corrupt thread-complete workspace-task worktrees/task ship
printf 'not json at all' > "$STATE/rc-corrupt.playbot-outbox.json"
chmod 0600 "$STATE/rc-corrupt.playbot-outbox.json"
RC=0
OUT=$(node "$RECONCILE" check rc-corrupt --check-key-queued 0 2>/dev/null) || RC=$?
[ "$RC" -ne 0 ] || fail "a corrupt outbox must fail nonzero"
printf '%s' "$OUT" | grep -q '^playbot-reconcile-failure task=rc-corrupt stage=outbox$' \
  || fail "a corrupt outbox must print one static failure line, got: $OUT"
pass "corrupt or unverifiable records are a visible failure, never silently filtered"

# --- orphaned dispatch transaction past deadline (V2SIM-4) ----------------------------

write_task_fixture rc-txn thread-complete workspace-task worktrees/task ship
mkdir -p "$STATE/.playbot-dispatch"
printf 'task_id=rc-txn\nstate=accepted\nworkspace_id=workspace-task\nthread_id=thread-complete\n' > "$STATE/.playbot-dispatch/rc-txn.txn"
touch -t 202001010000 "$STATE/.playbot-dispatch/rc-txn.txn"
RC=0
OUT=$(FM_PLAYBOT_TXN_DEADLINE_SECS=600 node "$RECONCILE" check rc-txn --check-key-queued 0 2>/dev/null) || RC=$?
[ "$RC" -ne 0 ] || fail "a stale pre-worker-started transaction must fail nonzero"
printf '%s' "$OUT" | grep -q '^playbot-reconcile-failure task=rc-txn stage=dispatch-transaction$' \
  || fail "a stale transaction must print one static failure pointer, got: $OUT"
RC=0
OUT=$(FM_PLAYBOT_TXN_DEADLINE_SECS=600 node "$RECONCILE" check rc-txn --check-key-queued 0 2>/dev/null) || RC=$?
[ -z "$OUT" ] || fail "the same failure episode must not wake twice"
rm -f "$STATE/.playbot-dispatch/rc-txn.txn"
pass "an orphaned post-meta transaction past deadline yields exactly one static failure pointer"

# --- Playbot absence: bounded, visible, non-destructive -------------------------------

write_task_fixture rc-absent thread-complete workspace-task worktrees/task ship
RC=0
OUT=$(FM_PLAYBOT_APP_DB="$TMP_ROOT/nonexistent.db" node "$RECONCILE" check rc-absent --check-key-queued 0 2>/dev/null) || RC=$?
[ "$RC" -ne 0 ] || fail "Playbot absence must fail nonzero"
printf '%s' "$OUT" | grep -q '^playbot-reconcile-failure task=rc-absent stage=' \
  || fail "Playbot absence must produce one visible failure line"
[ -f "$STATE/rc-absent.playbot-route.json" ] || fail "task records must stay intact when Playbot is absent"
pass "Playbot absence is bounded and visible with every record retained"

# --- generated check wrapper: lock, queued-key boolean, registration -----------------

write_task_fixture rc-wrap thread-complete workspace-task worktrees/task ship
node "$RECONCILE" write-check rc-wrap >/dev/null || fail "write-check failed"
[ -x "$STATE/rc-wrap.check.sh" ] || fail "the generated wrapper must be executable"
[ "$(stat -f %Lp "$STATE/rc-wrap.check.sh")" = 700 ] || fail "the generated wrapper must be mode 0700"
[ ! -L "$STATE/rc-wrap.check.sh" ] || fail "the generated wrapper must not be a symlink"
WRAP_OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash "$STATE/rc-wrap.check.sh") || fail "wrapper run failed"
printf '%s' "$WRAP_OUT" | grep -q '^playbot-event task=rc-wrap ' || fail "the wrapper must print the reconciler's static pointer line"
# Concurrency: parallel wrapper runs collapse onto one outbox event.
write_task_fixture rc-race thread-multi workspace-task worktrees/task ship
node "$RECONCILE" write-check rc-race >/dev/null || fail "write-check for rc-race failed"
for _ in 1 2 3 4; do
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash "$STATE/rc-race.check.sh" >/dev/null 2>&1 &
done
wait
[ "$(outbox_field rc-race 'o.events.length')" = 2 ] || fail "concurrent checks must produce exactly the two real events, got $(outbox_field rc-race 'o.events.length')"
"$ROOT/bin/fm-check-register.sh" rc-wrap >/dev/null || fail "fm-check-register must bind the generated wrapper"
[ -f "$STATE/rc-wrap.check-trust" ] || fail "registration must write the trust record"
pass "generated wrapper is a registerable mode-0700 check that collapses concurrent runs"

printf 'fm-playbot-reconcile: all tests passed\n'
