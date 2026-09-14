#!/usr/bin/env bash
# tests/fm-status-gc.test.sh - bin/fm-status-gc.sh retires exactly one leak: a
# finished task's status log that outlived its task record. That script's header
# is the single owner of the complete refusal contract; these cases pin that it
# erases nothing else, and that every refusal preserves the record it refused on.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

GC="$ROOT/bin/fm-status-gc.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-gc-tests)

run_gc() {  # <state> <id> [extra args...]
  local state=$1; shift
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" "$GC" "$@"
}

# Write the watcher's per-task notification markers through the owners that
# compute their paths, so the fixture cannot drift from the real names.
seed_watcher_markers() {  # <state> <id>
  FM_STATE_OVERRIDE="$1" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-push-transition-lib.sh"
    printf "done: finished\n" > "$(_hb_surfaced_path "$2")"
    printf "seen\n" > "$(fm_wake_signal_seen_path "$STATE" "$STATE/$2.status")"
    printf "%s\n%s\n" \
      "$(_hb_surfaced_path "$2")" \
      "$(fm_wake_signal_seen_path "$STATE" "$STATE/$2.status")"
  ' _ "$ROOT" "$2"
}

# Seed the three watcher marker families the janitor retires (heartbeat,
# status-seen, turn-ended-seen) through the owners that compute their paths.
seed_retirable_watcher_markers() {  # <state> <id> <tag>
  FM_STATE_OVERRIDE="$1" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-push-transition-lib.sh"
    printf "hb-%s\n" "$3" > "$(_hb_surfaced_path "$2")"
    printf "seen-status-%s\n" "$3" > "$(fm_wake_signal_seen_path "$STATE" "$STATE/$2.status")"
    printf "seen-turnended-%s\n" "$3" > "$(fm_wake_signal_seen_path "$STATE" "$STATE/$2.turn-ended")"
  ' _ "$ROOT" "$2" "$3"
}

# Seed all four watcher notification marker families through the owners that
# compute their paths, with distinctive per-marker content so a cross-task
# deletion or content change is observable byte-for-byte.
seed_all_watcher_markers() {  # <state> <id> <tag>
  seed_retirable_watcher_markers "$1" "$2" "$3"
  FM_STATE_OVERRIDE="$1" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-push-transition-lib.sh"
    printf "daemon-%s\n" "$3" > "$(status_daemon_seen_marker_path "$STATE" "$2")"
  ' _ "$ROOT" "$2" "$3"
}

# The adversarial-review regressions below answer the four blocking findings
# of the 2026-09-14 review of this change (report: data/fm-advreview-53-codex).

test_orphaned_finished_status_is_retired_with_its_sidecars() {
  local dir state markers marker out
  dir=$(make_case orphan-retire)
  state="$dir/state"
  printf 'working: started\ndone: landed\n' > "$state/orphan.status"
  printf 'done: neighbor landed\n' > "$state/neighbor.status"
  # A real drain establishes the presentation-cursor rows and the per-task
  # open-decisions cursors for both tasks.
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "priming drain failed"
  markers=$(seed_watcher_markers "$state" orphan) || fail "could not seed watcher markers"

  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" \
    || fail "retiring an orphaned finished status record failed: $(cat "$dir/gc.err")"
  grep -F 'orphan' "$dir/gc.out" >/dev/null || fail "the retirement was not reported: $(cat "$dir/gc.out")"
  [ ! -e "$state/orphan.status" ] || fail "the orphaned status log survived retirement"
  [ ! -e "$state/.orphan.open-decisions-cursor" ] || fail "the orphaned open-decisions cursor survived retirement"
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    [ ! -e "$marker" ] || fail "a watcher notification marker survived retirement: $marker"
  done <<EOF
$markers
EOF

  # The presentation row is retired too: a later status log under the same id
  # starts unread at byte zero instead of being skipped as already presented,
  # while the neighbouring task's handled history stays handled.
  printf 'note: first event after retirement\n' > "$state/orphan.status"
  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "drain failed after retirement"
  grep -F 'first event after retirement' "$out" >/dev/null \
    || fail "the retired presentation row still suppressed a new status line: $(cat "$out")"
  grep -F 'neighbor landed' "$out" >/dev/null \
    && fail "retiring one task replayed a neighbouring task's handled history: $(cat "$out")"
  [ -f "$state/neighbor.status" ] || fail "retiring one task removed a neighbouring task's status log"
  pass "an orphaned finished status record is retired with its cursor, presentation row, and markers"
}

# The gate that all three panel seats failed the first cut on: per-task records
# whose name ENDS with the id - `.lease-<id>` and its family - were invisible to a
# `<id>.*` glob, so the janitor retired a status log while a supervision lease
# still owned the task. Seeded through the lease path's own owner so the fixture
# cannot drift from the real name.
test_id_suffixed_records_refuse() {
  local dir state rc lease
  dir=$(make_case suffixed-records)
  state="$dir/state"
  printf 'done: landed\n' > "$state/orphan.status"
  lease=$(FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-lease-lib.sh"
    fm_lease_path "$2"
  ' _ "$ROOT" orphan) || fail "could not resolve the lease path"
  [ -n "$lease" ] || fail "the lease path resolved empty"
  : > "$lease"

  rc=0
  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a task holding a supervision lease was not refused (rc=$rc)"
  grep -F "${lease##*/}" "$dir/gc.err" >/dev/null \
    || fail "the surviving lease was not named: $(cat "$dir/gc.err")"
  [ -f "$state/orphan.status" ] || fail "the refusal still removed the status log"
  [ -f "$lease" ] || fail "the refusal removed the lease it refused on"
  pass "an id-suffixed per-task record such as a supervision lease refuses retirement"
}

# A Playbot dispatch records its workspace and thread in a NESTED transaction
# before either the per-task temp root or the meta exists, and spawn deliberately
# retains it when abort cleanup cannot prove the endpoint is gone. A scan that
# only visits top-level state entries retires the status log around a live
# workspace and thread; the panel demonstrated exactly that.
test_nested_playbot_transaction_refuses() {
  local dir state rc
  dir=$(make_case nested-playbot-txn)
  state="$dir/state"
  printf 'done: terminal orphan\n' > "$state/orphan.status"
  mkdir -p "$state/.playbot-dispatch"
  printf 'task_id=orphan\nstate=thread-created\nworkspace_id=live-workspace\nthread_id=live-thread\n' \
    > "$state/.playbot-dispatch/orphan.txn"

  rc=0
  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a retained Playbot dispatch transaction was not refused (rc=$rc)"
  grep -F '.playbot-dispatch/orphan.txn' "$dir/gc.err" >/dev/null \
    || fail "the retained transaction was not named: $(cat "$dir/gc.err")"
  [ -f "$state/orphan.status" ] || fail "the refusal still removed the status log"
  [ -f "$state/.playbot-dispatch/orphan.txn" ] \
    || fail "the refusal removed the transaction it refused on"
  pass "a retained nested Playbot dispatch transaction refuses retirement"
}

# The nested scan must stay per-task: another task's transaction in the same
# directory is not this task's record.
test_another_tasks_nested_record_does_not_block() {
  local dir state
  dir=$(make_case nested-other-task)
  state="$dir/state"
  printf 'done: landed\n' > "$state/orphan.status"
  mkdir -p "$state/.playbot-dispatch"
  printf 'task_id=other-task\nstate=thread-created\n' > "$state/.playbot-dispatch/other-task.txn"

  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" \
    || fail "another task's nested transaction blocked retirement: $(cat "$dir/gc.err")"
  [ ! -e "$state/orphan.status" ] || fail "the orphan's status log survived retirement"
  [ -f "$state/.playbot-dispatch/other-task.txn" ] \
    || fail "retirement removed another task's nested transaction"
  pass "another task's nested record neither blocks retirement nor is removed by it"
}

# Task ids may legally be words that also appear in home-wide state names, and
# this janitor holds the task-set lock while it scans. Without an exemption the
# unrecognized-record catch-all reports the janitor's own lock as a surviving
# record and parks the leak forever.
test_home_wide_locks_do_not_block_word_ids() {
  local dir state id
  dir=$(make_case home-wide-lock-ids)
  state="$dir/state"
  # A lived-in home carries many more home-wide artifacts than the janitor's own
  # lock; every one of them used to read as a record of an ordinary-word task id.
  : > "$state/.claude-autoarm.lock"
  : > "$state/.cursor-park-owner.lock"
  : > "$state/.watch-triage.log"
  : > "$state/.focus.json"
  : > "$state/.heartbeat-streak"
  printf '7\n' > "$state/.wake-queue.seq"
  for id in lock task set watch queue focus streak; do
    printf 'done: landed\n' > "$state/$id.status"
    run_gc "$state" "$id" > "$dir/gc-$id.out" 2> "$dir/gc-$id.err" \
      || fail "id '$id' was blocked by a home-wide state name: $(cat "$dir/gc-$id.err")"
    [ ! -e "$state/$id.status" ] || fail "id '$id' was reported retired but its status log survived"
  done
  pass "task ids that collide with home-wide state vocabulary are still retirable"
}

# Several nested records are keyed by a correlation id and bind to the task only
# INSIDE the file. A pending-reply expectation names the very status log this
# would delete, and teardown already refuses on exactly that evidence, so the
# janitor must not be weaker than teardown on the same state.
test_content_bound_nested_record_refuses() {
  local dir state rc
  dir=$(make_case content-bound-record)
  state="$dir/state"
  printf 'done: landed\n' > "$state/orphan.status"
  mkdir -p "$state/pending-replies"
  printf 'schema=fm-pending-reply.v1\ntask_id=orphan\nparent_status=%s\n' \
    "$state/orphan.status" > "$state/pending-replies/abcdef0123456789"

  rc=0
  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a pending-reply record naming this task was not refused (rc=$rc)"
  grep -F 'pending-replies/abcdef0123456789' "$dir/gc.err" >/dev/null \
    || fail "the content-bound record was not named: $(cat "$dir/gc.err")"
  [ -f "$state/orphan.status" ] || fail "the refusal still removed the status log"
  pass "a nested record that binds to this task only in its contents refuses retirement"
}

# Other nested records ARE task-keyed but live in directories no family names.
# Resolving subdirectories by name as well as contents covers them without
# needing an entry per directory.
test_task_keyed_nested_records_refuse() {
  local dir state rc
  dir=$(make_case task-keyed-nested)
  state="$dir/state"
  printf 'done: landed\n' > "$state/orphan.status"
  mkdir -p "$state/remote-replies" "$state/handoff"
  printf '42\n' > "$state/remote-replies/orphan.caught-up"
  printf 'undelivered payload\n' > "$state/handoff/orphan.outbox.md"

  rc=0
  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "task-keyed nested records were not refused (rc=$rc)"
  grep -F 'remote-replies/orphan.caught-up' "$dir/gc.err" >/dev/null \
    || fail "the remote-reply watermark was not named: $(cat "$dir/gc.err")"
  grep -F 'handoff/orphan.outbox.md' "$dir/gc.err" >/dev/null \
    || fail "the undelivered handoff was not named: $(cat "$dir/gc.err")"
  [ -f "$state/remote-replies/orphan.caught-up" ] || fail "the refusal removed the watermark"
  [ -f "$state/handoff/orphan.outbox.md" ] || fail "the refusal removed the handoff payload"
  pass "task-keyed records in unnamed subdirectories refuse retirement"
}

# The unrecognized-record test has to treat `/` as a delimiter like `.`, `-`, and
# `_`. Without it a nested name carrying the task id straight after a slash fell
# through both the family table and the catch-all - failing OPEN, which is the
# direction this janitor exists to prevent.
test_unrecognized_nested_name_refuses() {
  local dir state rc
  dir=$(make_case unrecognized-nested)
  state="$dir/state"
  printf 'done: terminal orphan\n' > "$state/orphan.status"
  mkdir -p "$state/.playbot-dispatch"
  printf 'workspace_id=live-workspace\n' > "$state/.playbot-dispatch/orphan.workspace"

  rc=0
  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an unrecognized nested name carrying the task id was not refused (rc=$rc)"
  grep -F '.playbot-dispatch/orphan.workspace' "$dir/gc.err" >/dev/null \
    || fail "the unrecognized nested record was not named: $(cat "$dir/gc.err")"
  [ -f "$state/orphan.status" ] || fail "the refusal still removed the status log"
  pass "an unrecognized nested name is refused rather than retired around"
}

# A symlinked subdirectory cannot be inspected safely, and skipping it hid the
# very record the nested scan was added to find while the writers that follow the
# link kept working.
test_symlinked_subdirectory_refuses() {
  local dir state rc outside
  dir=$(make_case symlinked-subdir)
  state="$dir/state"
  outside="$dir/outside"
  printf 'done: terminal orphan\n' > "$state/orphan.status"
  mkdir -p "$outside"
  printf 'state=thread-created\nworkspace_id=live-workspace\n' > "$outside/orphan.txn"
  ln -s "$outside" "$state/.playbot-dispatch"

  rc=0
  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a symlinked state subdirectory was skipped instead of refused (rc=$rc)"
  grep -F 'symlinked directory' "$dir/gc.err" >/dev/null \
    || fail "the refusal did not name the symlinked directory: $(cat "$dir/gc.err")"
  [ -f "$state/orphan.status" ] || fail "the refusal still removed the status log"
  [ -f "$outside/orphan.txn" ] || fail "the refusal reached through the symlink"
  pass "a symlinked state subdirectory refuses rather than being skipped"
}

# Some home-wide records are shaped exactly like a finished task status log.
# Retiring one would delete a home-wide record, not an orphan.
test_home_wide_status_shape_refuses() {
  local dir state rc
  dir=$(make_case home-wide-status)
  state="$dir/state"
  printf 'done [key=abc]: inactive terminal child=some-task fingerprint=fp\n' \
    > "$state/parent-replies.status"

  rc=0
  run_gc "$state" parent-replies > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a home-wide status-shaped record was retired (rc=$rc)"
  [ -f "$state/parent-replies.status" ] || fail "the home-wide record was deleted"
  pass "a home-wide record shaped like a task status log refuses retirement"
}

# Task binding has to be resolved BEFORE the home-wide exemption. Testing the
# home-wide shape first exempted every per-task lock before its owner was
# computed, and this is the case that proves why it matters: the holder of
# `.remote-reply-ingest-<id>.lock` appends to `state/<id>.status` and does NOT
# take the task-set lock, so the janitor's own lock gate cannot see it. Held
# through the run, exactly as the real writer holds it.
test_held_per_task_lock_refuses() {
  local dir state rc holder_pid
  dir=$(make_case held-per-task-lock)
  state="$dir/state"
  printf 'done: landed\n' > "$state/orphan.status"

  FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$STATE/.remote-reply-ingest-orphan.lock" || exit 1
    printf "held\n" > "$2"
    sleep 30
  ' _ "$ROOT" "$dir/held" &
  holder_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$dir/held" ] && break
    sleep 0.2
  done
  [ -s "$dir/held" ] || { kill "$holder_pid" 2>/dev/null || true; fail "held-per-task-lock: the holder never took the lock"; }

  rc=0
  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ "$rc" -eq 1 ] || fail "a held per-task ingest lock did not refuse retirement (rc=$rc)"
  grep -F '.remote-reply-ingest-orphan.lock' "$dir/gc.err" >/dev/null \
    || fail "the held lock was not named: $(cat "$dir/gc.err")"
  [ -f "$state/orphan.status" ] \
    || fail "the status log was deleted while its writer held the ingest lock"
  pass "a held per-task lock whose writer appends to the status log refuses retirement"
}

# The same ordering must not over-refuse: another task's per-task locks resolve
# to that task and are neither a blocker nor touched.
test_other_tasks_per_task_locks_do_not_block() {
  local dir state
  dir=$(make_case other-task-locks)
  state="$dir/state"
  printf 'done: landed\n' > "$state/orphan.status"
  : > "$state/.control-other.lock"
  : > "$state/.remote-reply-ingest-other.lock"
  : > "$state/.spawn-other.lock"

  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" \
    || fail "another task's per-task locks blocked retirement: $(cat "$dir/gc.err")"
  [ ! -e "$state/orphan.status" ] || fail "the orphan's status log survived retirement"
  [ -f "$state/.control-other.lock" ] || fail "retirement removed another task's control lock"
  [ -f "$state/.remote-reply-ingest-other.lock" ] || fail "retirement removed another task's ingest lock"
  pass "another task's per-task locks neither block retirement nor are removed by it"
}

# A record family this janitor does not know must fail closed rather than be
# retired around, so a family added upstream cannot silently become residue.
test_unrecognized_record_naming_the_task_refuses() {
  local dir state rc
  dir=$(make_case unrecognized-record)
  state="$dir/state"
  printf 'done: landed\n' > "$state/orphan.status"
  : > "$state/.future-family-orphan"

  rc=0
  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an unrecognized record naming the task was not refused (rc=$rc)"
  grep -F '.future-family-orphan' "$dir/gc.err" >/dev/null \
    || fail "the unrecognized record was not named: $(cat "$dir/gc.err")"
  [ -f "$state/orphan.status" ] || fail "the refusal still removed the status log"
  pass "a record family this janitor does not recognize refuses instead of being retired around"
}

# Enumerating families by their exact names (rather than globbing `<id>.*`) also
# has to avoid the opposite error: a DIFFERENT task whose id merely starts with
# this one's must not block, and must survive untouched.
test_sibling_task_with_longer_id_does_not_block() {
  local dir state
  dir=$(make_case sibling-id)
  state="$dir/state"
  printf 'done: landed\n' > "$state/foo.status"
  printf 'window=firstmate:fm-foo.bar\nkind=ship\n' > "$state/foo.bar.meta"
  printf 'working: still going\n' > "$state/foo.bar.status"

  run_gc "$state" foo > "$dir/gc.out" 2> "$dir/gc.err" \
    || fail "a live sibling task blocked an unrelated orphan: $(cat "$dir/gc.err")"
  [ ! -e "$state/foo.status" ] || fail "the orphan's status log survived retirement"
  [ -f "$state/foo.bar.meta" ] || fail "retirement removed a sibling task's record"
  [ -f "$state/foo.bar.status" ] || fail "retirement removed a sibling task's status log"
  pass "a sibling task whose id extends this one's neither blocks nor is retired"
}

# Spawn creates the per-task temp root before the worker starts and teardown
# removes it last, so its presence is positive evidence that a worker ran here
# and cleanup never finished - the closest available stand-in for the recipe's
# "no live backend window", which no meta-less task can resolve an endpoint for.
test_surviving_task_temp_root_refuses() {
  local dir state rc id
  dir=$(make_case task-temp-root)
  state="$dir/state"
  id="fm-status-gc-temp-probe-$$"
  printf 'done: landed\n' > "$state/$id.status"
  mkdir -p "/tmp/fm-$id"

  rc=0
  run_gc "$state" "$id" > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  rmdir "/tmp/fm-$id" 2>/dev/null || true
  [ "$rc" -eq 1 ] || fail "a surviving per-task temp root was not refused (rc=$rc)"
  grep -F "/tmp/fm-$id" "$dir/gc.err" >/dev/null \
    || fail "the surviving temp root was not named: $(cat "$dir/gc.err")"
  [ -f "$state/$id.status" ] || fail "the refusal still removed the status log"
  pass "a surviving per-task temp root refuses retirement"
}

# The gates are only meaningful while nothing can publish a record for this id, so
# a janitor that cannot take this home's task-set lock must refuse rather than
# race the spawn that holds it.
test_gc_refuses_while_the_task_set_lock_is_held() {
  local dir state rc holder_pid
  dir=$(make_case gc-task-set-lock)
  state="$dir/state"
  printf 'done: landed\n' > "$state/orphan.status"

  FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_task_set_lock_path "$STATE") || exit 1
    fm_lock_try_acquire "$lock" || exit 1
    printf "held\n" > "$2"
    sleep 30
  ' _ "$ROOT" "$dir/held" &
  holder_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$dir/held" ] && break
    sleep 0.2
  done
  [ -s "$dir/held" ] || { kill "$holder_pid" 2>/dev/null || true; fail "gc-task-set-lock: the holder never took the lock"; }

  rc=0
  run_gc "$state" orphan > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ "$rc" -eq 1 ] || fail "gc-task-set-lock: retirement proceeded while the task set was locked (rc=$rc)"
  grep -F 'task set is locked' "$dir/gc.err" >/dev/null \
    || fail "gc-task-set-lock: the refusal did not name the task-set lock"
  [ -f "$state/orphan.status" ] || fail "gc-task-set-lock: the refusal still removed the status log"
  pass "a janitor that cannot take the task-set lock refuses instead of racing a spawn"
}

test_live_task_record_refuses() {
  local dir state rc
  dir=$(make_case live-task)
  state="$dir/state"
  printf 'done: landed\n' > "$state/live.status"
  printf 'window=firstmate:fm-live\nkind=ship\n' > "$state/live.meta"
  rc=0
  run_gc "$state" live > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a task that still has its task record was not refused (rc=$rc)"
  grep -F REFUSED "$dir/gc.err" >/dev/null || fail "no REFUSED line for a live task record"
  [ -f "$state/live.status" ] || fail "the refusal still removed the status log"
  pass "a status log whose task record still exists is refused, not retired"
}

test_unfinished_and_undecided_records_refuse() {
  local dir state rc
  dir=$(make_case unfinished)
  state="$dir/state"
  printf 'working: still going\n' > "$state/wip.status"
  printf 'needs-decision: which base? [key=base]\ndone: landed\n' > "$state/held.status"

  rc=0
  run_gc "$state" wip > "$dir/wip.out" 2> "$dir/wip.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an unfinished status log was not refused (rc=$rc)"
  grep -F REFUSED "$dir/wip.err" >/dev/null || fail "no REFUSED line for an unfinished status log"
  [ -f "$state/wip.status" ] || fail "the refusal still removed an unfinished status log"

  rc=0
  run_gc "$state" held > "$dir/held.out" 2> "$dir/held.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a status log with an unanswered decision was not refused (rc=$rc)"
  grep -F 'base' "$dir/held.err" >/dev/null || fail "the unanswered decision was not named: $(cat "$dir/held.err")"
  [ -f "$state/held.status" ] || fail "the refusal still removed a status log holding an open decision"
  pass "unfinished work and unanswered decisions are refused and preserved"
}

test_other_surviving_records_refuse() {
  local dir state rc
  dir=$(make_case partial-teardown)
  state="$dir/state"
  printf 'done: landed\n' > "$state/partial.status"
  mkdir -p "$state/partial.inbox"
  rc=0
  run_gc "$state" partial > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a partially cleaned up task was not refused (rc=$rc)"
  grep -F 'partial.inbox' "$dir/gc.err" >/dev/null \
    || fail "the surviving record was not named: $(cat "$dir/gc.err")"
  [ -f "$state/partial.status" ] || fail "the refusal still removed the status log"
  [ -d "$state/partial.inbox" ] || fail "the refusal still removed the surviving record"
  pass "a task with any other surviving record is reported as unfinished cleanup, not retired"
}

# --finish-cleanup is the writer-owned forward path for exactly that refusal:
# each surviving family retires through its own writer (the kimi token through
# the control-plane deregistration path, never a hand-delete), and the status
# log then retires through the ordinary path.
test_finish_cleanup_retires_partial_records_through_their_writers() {
  local dir state token_auth out rc markers
  dir=$(make_case finish-cleanup-writers)
  state="$dir/state"
  printf 'working: trying\ndone: trial ok\n' > "$state/partial.status"
  : > "$state/partial.turn-ended"
  printf 'fm.reprotok123\n' > "$state/partial.kimi-turnend-token"
  token_auth="$dir/fakehome/.kimi-code/fm-turn-end.d/fm.reprotok123"
  mkdir -p "$(dirname "$token_auth")"
  # The spawn writer stores this task's exact turn-ended marker path in the
  # auth record; the retirement validates that content before deregistering.
  printf '%s\n' "$state/partial.turn-ended" > "$token_auth"
  mkdir -p "$state/partial.inbox"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "priming drain failed"
  markers=$(seed_watcher_markers "$state" partial) || fail "could not seed watcher markers"

  rc=0
  PATH="$dir/fakebin:$PATH" HOME="$dir/fakehome" run_gc "$state" partial --finish-cleanup \
    > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "finish-cleanup refused a retirable partial record: $(cat "$dir/gc.err")"
  grep -F 'retired orphaned status record' "$dir/gc.out" >/dev/null \
    || fail "the retirement was not reported: $(cat "$dir/gc.out")"
  [ ! -e "$state/partial.status" ] || fail "the status log survived finish-cleanup"
  [ ! -e "$state/partial.turn-ended" ] || fail "the turn-ended marker survived"
  [ ! -e "$state/partial.kimi-turnend-token" ] || fail "the kimi token file survived"
  [ ! -e "$token_auth" ] || fail "the kimi turn-end hook auth was not deregistered through its control-plane path"
  [ ! -d "$state/partial.inbox" ] || fail "the steering inbox survived"
  [ ! -e "$state/.partial.open-decisions-cursor" ] || fail "the open-decisions cursor survived"
  pass "finish-cleanup retires a partial cleanup through each record's own writer, kimi hook auth included"
}

test_finish_cleanup_preflights_late_pr_refusal() {
  local dir state token_auth rc
  dir=$(make_case finish-cleanup-pr-preflight)
  state="$dir/state"
  printf 'done: trial ok\n' > "$state/partial.status"
  : > "$state/partial.turn-ended"
  printf 'fm.reprotok123\n' > "$state/partial.kimi-turnend-token"
  token_auth="$dir/fakehome/.kimi-code/fm-turn-end.d/fm.reprotok123"
  mkdir -p "$(dirname "$token_auth")"
  printf '%s\n' "$state/partial.turn-ended" > "$token_auth"
  printf 'foreign check\n' > "$dir/foreign-check"
  ln -s "$dir/foreign-check" "$state/partial.check.sh"

  rc=0
  PATH="$dir/fakebin:$PATH" HOME="$dir/fakehome" run_gc "$state" partial --finish-cleanup \
    > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup accepted an unsafe late PR artifact (rc=$rc)"
  [ -f "$state/partial.status" ] || fail "late PR refusal removed the status log"
  [ -f "$state/partial.turn-ended" ] || fail "late PR refusal removed another residue marker"
  [ -f "$state/partial.kimi-turnend-token" ] || fail "late PR refusal removed the turn-end token"
  [ -f "$token_auth" ] || fail "late PR refusal deregistered the turn-end hook"
  [ -L "$state/partial.check.sh" ] || fail "late PR refusal removed the unsafe artifact"
  pass "finish-cleanup preflights late writer refusals before any mutation"
}

test_finish_cleanup_refuses_symlinked_turnend_token_without_mutation() {
  local dir state token_auth rc
  dir=$(make_case finish-cleanup-token-symlink)
  state="$dir/state"
  printf 'done: trial ok\n' > "$state/task-a.status"
  : > "$state/task-a.turn-ended"
  printf 'fm.task-b-token\n' > "$state/task-b.kimi-turnend-token"
  ln -s "$state/task-b.kimi-turnend-token" "$state/task-a.kimi-turnend-token"
  token_auth="$dir/fakehome/.kimi-code/fm-turn-end.d/fm.task-b-token"
  mkdir -p "$(dirname "$token_auth")"
  printf 'task B hook\n' > "$token_auth"

  rc=0
  HOME="$dir/fakehome" run_gc "$state" task-a --finish-cleanup \
    > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup accepted a symlinked turn-end token (rc=$rc)"
  [ -f "$state/task-a.status" ] || fail "token refusal removed task A's status log"
  [ -f "$state/task-a.turn-ended" ] || fail "token refusal removed task A's residue"
  [ -L "$state/task-a.kimi-turnend-token" ] || fail "token refusal removed task A's symlink"
  [ -f "$state/task-b.kimi-turnend-token" ] || fail "token refusal removed task B's token"
  [ -f "$token_auth" ] || fail "token refusal deregistered task B's hook"
  pass "finish-cleanup refuses a symlinked token without cross-task mutation"
}

test_finish_cleanup_preflights_turnend_auth_target() {
  local dir home state token token_auth rc
  dir=$(make_case finish-cleanup-auth-target)
  home="$dir/home"
  state="$home/state"
  token=fm.reprotok123
  token_auth="$dir/fakehome/.kimi-code/fm-turn-end.d/$token"
  mkdir -p "$state" "$token_auth" "$dir/fakebin"
  printf 'done: trial ok\n' > "$state/partial.status"
  : > "$state/partial.turn-ended"
  printf '%s\n' "$token" > "$state/partial.kimi-turnend-token"
  {
    printf 'version=2\ntask_id=partial\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\nhome=%s\n' "$home"
    printf 'session=default\nworkspace_id=wA\ntab_id=wA:t1\npane_id=wA:p1\n'
    printf 'parent_workspace_id=w0\nparent_label=firstmate\nworkspace_label=└ partial · p:AbCdEfGhIjKlMnOpQrStUv\ntask_label=fm-partial\n'
  } > "$state/partial.herdr-presentation"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "case \"\${1:-} \${2:-}\" in" \
    '  "workspace list") printf "%s\\n" '\''{"result":{"workspaces":[]}}'\'' ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  FM_HOME="$home" HOME="$dir/fakehome" PATH="$dir/fakebin:$PATH" \
    run_gc "$state" partial --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup accepted a directory turn-end auth target (rc=$rc)"
  [ -f "$state/partial.status" ] || fail "auth-target refusal removed the status log"
  [ -f "$state/partial.turn-ended" ] || fail "auth-target refusal removed task residue"
  [ -f "$state/partial.kimi-turnend-token" ] || fail "auth-target refusal removed the token record"
  [ -f "$state/partial.herdr-presentation" ] || fail "auth-target refusal retired Herdr state first"
  [ -d "$token_auth" ] || fail "auth-target refusal changed the external target"
  pass "finish-cleanup preflights the external turn-end auth target"
}

test_finish_cleanup_refuses_hardlinked_turnend_auth_target() {
  local dir home state token token_auth token_auth_link rc
  dir=$(make_case finish-cleanup-hardlinked-auth-target)
  home="$dir/home"
  state="$home/state"
  token=fm.hardlinktoken
  token_auth="$dir/fakehome/.kimi-code/fm-turn-end.d/$token"
  token_auth_link="$dir/auth-second-link"
  mkdir -p "$state" "$(dirname "$token_auth")"
  printf 'done: trial ok\n' > "$state/partial.status"
  : > "$state/partial.turn-ended"
  printf '%s\n' "$token" > "$state/partial.kimi-turnend-token"
  printf 'auth\n' > "$token_auth"
  ln "$token_auth" "$token_auth_link"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" HOME="$dir/fakehome" \
    run_gc "$state" partial --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup accepted a hard-linked turn-end auth target (rc=$rc)"
  [ -f "$state/partial.status" ] || fail "hard-link refusal removed the status log"
  [ -f "$state/partial.turn-ended" ] || fail "hard-link refusal removed task residue"
  [ -f "$state/partial.kimi-turnend-token" ] || fail "hard-link refusal removed the token record"
  [ -f "$token_auth" ] && [ -f "$token_auth_link" ] \
    || fail "hard-link refusal changed the auth target"
  pass "finish-cleanup refuses hard-linked turn-end auth targets atomically"
}

test_finish_cleanup_preflights_unsafe_residue() {
  local dir home state rc
  dir=$(make_case finish-cleanup-residue-preflight)
  home="$dir/home"
  state="$home/state"
  mkdir -p "$state/partial.turn-ended" "$dir/fakebin"
  printf 'done: trial ok\n' > "$state/partial.status"
  printf 'preserve\n' > "$state/partial.progress"
  {
    printf 'version=2\ntask_id=partial\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\nhome=%s\n' "$home"
    printf 'session=default\nworkspace_id=wA\ntab_id=wA:t1\npane_id=wA:p1\n'
    printf 'parent_workspace_id=w0\nparent_label=firstmate\nworkspace_label=└ partial · p:AbCdEfGhIjKlMnOpQrStUv\ntask_label=fm-partial\n'
  } > "$state/partial.herdr-presentation"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "case \"\${1:-} \${2:-}\" in" \
    '  "workspace list") printf "%s\\n" '\''{"result":{"workspaces":[]}}'\'' ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  FM_HOME="$home" PATH="$dir/fakebin:$PATH" \
    run_gc "$state" partial --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup accepted an unsafe residue directory (rc=$rc)"
  [ -f "$state/partial.status" ] || fail "residue refusal removed the status log"
  [ -d "$state/partial.turn-ended" ] || fail "residue refusal changed the unsafe record"
  [ -f "$state/partial.progress" ] || fail "residue refusal removed another record"
  [ -f "$state/partial.herdr-presentation" ] || fail "residue refusal retired Herdr state first"
  pass "finish-cleanup preflights every residue before any mutation"
}

test_finish_cleanup_preflights_unsafe_busy_state() {
  local dir home state rc
  dir=$(make_case finish-cleanup-busy-preflight)
  home="$dir/home"
  state="$home/state"
  mkdir -p "$state/partial.busy-state" "$dir/fakebin"
  printf 'done: trial ok\n' > "$state/partial.status"
  : > "$state/partial.turn-ended"
  {
    printf 'version=2\ntask_id=partial\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\nhome=%s\n' "$home"
    printf 'session=default\nworkspace_id=wA\ntab_id=wA:t1\npane_id=wA:p1\n'
    printf 'parent_workspace_id=w0\nparent_label=firstmate\nworkspace_label=└ partial · p:AbCdEfGhIjKlMnOpQrStUv\ntask_label=fm-partial\n'
  } > "$state/partial.herdr-presentation"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "case \"\${1:-} \${2:-}\" in" \
    '  "workspace list") printf "%s\\n" '\''{"result":{"workspaces":[]}}'\'' ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  FM_HOME="$home" PATH="$dir/fakebin:$PATH" \
    run_gc "$state" partial --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup accepted an unsafe busy-state directory (rc=$rc)"
  [ -f "$state/partial.status" ] || fail "busy-state refusal removed the status log"
  [ -f "$state/partial.turn-ended" ] || fail "busy-state refusal removed another record"
  [ -d "$state/partial.busy-state" ] || fail "busy-state refusal changed the unsafe record"
  [ -f "$state/partial.herdr-presentation" ] || fail "busy-state refusal retired Herdr state first"
  pass "finish-cleanup preflights both busy-state files before any mutation"
}

test_finish_cleanup_preflights_status_presentation_retirement() {
  local dir home state token rc
  dir=$(make_case finish-cleanup-presentation-preflight)
  home="$dir/home"
  state="$home/state"
  token=AbCdEfGhIjKlMnOpQrStUv
  mkdir -p "$state" "$dir/fakebin"
  printf 'done: trial ok\n' > "$state/partial.status"
  : > "$state/partial.turn-ended"
  printf '!\n' > "$state/partial.kimi-turnend-token"
  printf 'malformed\n' > "$state/.status-presentation-cursor"
  {
    printf 'version=2\ntask_id=partial\nprojection_id=%s\nhome=%s\n' "$token" "$home"
    printf 'session=default\nworkspace_id=wA\ntab_id=wA:t1\npane_id=wA:p1\n'
    printf 'parent_workspace_id=w0\nparent_label=firstmate\nworkspace_label=└ partial · p:%s\ntask_label=fm-partial\n' "$token"
  } > "$state/partial.herdr-presentation"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "case \"\${1:-} \${2:-}\" in" \
    '  "workspace list") printf "%s\\n" '\''{"result":{"workspaces":[]}}'\'' ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  FM_HOME="$home" PATH="$dir/fakebin:$PATH" \
    run_gc "$state" partial --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup accepted a malformed presentation cursor (rc=$rc)"
  [ -f "$state/partial.status" ] || fail "presentation refusal removed the status log"
  [ -f "$state/partial.turn-ended" ] || fail "presentation refusal removed task residue"
  [ -f "$state/partial.kimi-turnend-token" ] || fail "presentation refusal removed the token record"
  [ -f "$state/partial.herdr-presentation" ] || fail "presentation refusal retired Herdr state first"
  [ -f "$state/.status-presentation-cursor" ] || fail "presentation refusal removed the malformed cursor"
  pass "finish-cleanup preflights status presentation retirement before mutation"
}

test_finish_cleanup_retires_an_intact_busy_incarnation() {
  local dir state rc
  dir=$(make_case finish-cleanup-busy-incarnation)
  state="$dir/state"
  printf 'done: trial ok\n' > "$state/partial.status"
  : > "$state/partial.turn-ended"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" partial >/dev/null \
    || fail "could not arm the busy incarnation fixture"

  rc=0
  run_gc "$state" partial --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "finish-cleanup refused an intact busy incarnation: $(cat "$dir/gc.err")"
  [ ! -e "$state/partial.busy-gen" ] || fail "the busy generation survived finish-cleanup"
  [ ! -e "$state/partial.busy-state" ] || fail "the busy record survived finish-cleanup"
  [ ! -e "$state/partial.turn-ended" ] || fail "the other residue marker survived finish-cleanup"
  [ ! -e "$state/partial.status" ] || fail "the status log survived busy retirement"
  pass "finish-cleanup retires an intact busy incarnation through its writer"
}

# A writer's conservative preservation refuses the whole finish: the herdr
# journal's own orphan path keeps it while its projection cannot be proven
# gone, and nothing else may be retired around that refusal.
test_finish_cleanup_refuses_when_a_writer_preserves_its_record() {
  local dir state rc
  dir=$(make_case finish-cleanup-herdr-preserved)
  state="$dir/state"
  printf 'done: trial ok\n' > "$state/partial.status"
  : > "$state/partial.turn-ended"
  printf 'version=2\ntask_id=partial\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\nhome=%s\nsession=default\nworkspace_id=wRe\ntab_id=wRe:t1\npane_id=wRe:p1\nworkspace_label=repro\ntask_label=fm-partial\n' \
    "$dir" > "$state/partial.herdr-presentation"
  # A herdr that cannot answer keeps the writer's orphan path conservative on
  # any host, with or without a live herdr installation.
  mkdir -p "$dir/fakebin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  PATH="$dir/fakebin:$PATH" run_gc "$state" partial --finish-cleanup \
    > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "a preserved herdr journal did not refuse the whole finish (rc=$rc)"
  grep -F 'preserved by its own writer' "$dir/gc.err" >/dev/null \
    || fail "the writer-preservation refusal did not name the journal: $(cat "$dir/gc.err")"
  [ -f "$state/partial.herdr-presentation" ] || fail "the refusal removed the preserved journal"
  [ -f "$state/partial.turn-ended" ] || fail "the refusal retired other records around the preserved journal"
  [ -f "$state/partial.status" ] || fail "the refusal removed the status log"
  pass "finish-cleanup refuses atomically when a writer preserves its record"
}

test_finish_cleanup_retires_only_its_own_gone_herdr_journal() {
  local dir home state close_log rc token_a token_b
  dir=$(make_case finish-cleanup-herdr-scoped)
  home="$dir/home"
  state="$home/state"
  close_log="$dir/pane-closes.log"
  token_a=AbCdEfGhIjKlMnOpQrStUv
  token_b=ZyXwVuTsRqPoNmLkJiHgFe
  mkdir -p "$state" "$dir/fakebin"
  printf 'done: task A finished\n' > "$state/task-a.status"
  : > "$state/task-b.turn-ended"
  {
    printf 'version=2\ntask_id=task-a\nprojection_id=%s\nhome=%s\n' "$token_a" "$home"
    printf 'session=default\nworkspace_id=wA\ntab_id=wA:t1\npane_id=wA:p1\n'
    printf 'parent_workspace_id=w0\nparent_label=firstmate\nworkspace_label=└ task-a · p:%s\ntask_label=fm-task-a\n' "$token_a"
  } > "$state/task-a.herdr-presentation"
  {
    printf 'version=2\ntask_id=task-b\nprojection_id=%s\nhome=%s\n' "$token_b" "$home"
    printf 'session=default\nworkspace_id=wB\ntab_id=wB:t1\npane_id=wB:p1\n'
    printf 'parent_workspace_id=w0\nparent_label=firstmate\nworkspace_label=└ task-b · p:%s\ntask_label=fm-task-b\n' "$token_b"
  } > "$state/task-b.herdr-presentation"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "case \"\${1:-} \${2:-}\" in" \
    '  "workspace list") printf "%s\\n" '\''{"result":{"workspaces":[]}}'\'' ;;' \
    "  \"pane close\") printf \"%s\\\\n\" \"\$*\" >> \"\${HERDR_CLOSE_LOG:?}\" ;;" \
    '  *) exit 1 ;;' \
    'esac' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  FM_HOME="$home" HERDR_CLOSE_LOG="$close_log" PATH="$dir/fakebin:$PATH" \
    run_gc "$state" task-a --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "finish-cleanup refused task A's gone Herdr journal: $(cat "$dir/gc.err")"
  [ ! -e "$state/task-a.herdr-presentation" ] || fail "task A's gone Herdr journal survived finish-cleanup"
  [ ! -e "$state/task-a.status" ] || fail "task A's status survived finish-cleanup"
  [ -f "$state/task-b.herdr-presentation" ] || fail "finishing task A removed task B's eligible journal"
  [ -f "$state/task-b.turn-ended" ] || fail "finishing task A removed another record belonging to task B"
  [ ! -s "$close_log" ] || fail "finishing task A closed a pane belonging to another task"
  pass "finish-cleanup retires only its requested task's gone Herdr journal"
}

# Families with no writer-owned retirement (locks, adapter route records,
# anything unrecognized) still refuse the finish, and nothing is retired.
test_finish_cleanup_refuses_records_no_writer_owns_and_retires_nothing() {
  local dir state rc
  dir=$(make_case finish-cleanup-no-writer)
  state="$dir/state"
  printf 'done: landed\n' > "$state/partial.status"
  : > "$state/partial.turn-ended"
  : > "$state/.control-partial.lock"
  printf 'route\n' > "$state/partial.playbot-route.json"

  rc=0
  run_gc "$state" partial --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "records no writer owns did not refuse the finish (rc=$rc)"
  grep -F 'no writer-owned retirement' "$dir/gc.err" >/dev/null \
    || fail "the refusal did not name the missing writers: $(cat "$dir/gc.err")"
  [ -f "$state/partial.turn-ended" ] || fail "the refusal retired the turn-ended marker"
  [ -f "$state/partial.status" ] || fail "the refusal removed the status log"
  [ -f "$state/.control-partial.lock" ] || fail "the refusal removed the lock"
  pass "finish-cleanup refuses, retiring nothing, when any surviving record has no writer-owned retirement"
}

# The finish path runs the janitor's own terminal gates before retiring
# anything: a partial record of unfinished work keeps every record.
test_finish_cleanup_refuses_unfinished_work_and_retires_nothing() {
  local dir state rc
  dir=$(make_case finish-cleanup-unfinished)
  state="$dir/state"
  printf 'working: still going\n' > "$state/partial.status"
  : > "$state/partial.turn-ended"

  rc=0
  run_gc "$state" partial --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an unfinished partial record was finished by the flag (rc=$rc)"
  grep -F 'not a finished one' "$dir/gc.err" >/dev/null \
    || fail "the unfinished refusal did not print: $(cat "$dir/gc.err")"
  [ -f "$state/partial.status" ] || fail "the refusal removed the unfinished status log"
  [ -f "$state/partial.turn-ended" ] || fail "the refusal retired records of unfinished work"
  pass "finish-cleanup never retires records of unfinished work"
}

# Review finding 1: --finish-cleanup used to treat absence of /tmp/fm-<id> as
# proof the endpoint was gone and retired the record of a task whose live
# window still existed. The positive probe must refuse while any backend
# inventory shows a live fm-<id> endpoint, and the same record must retire
# normally once that endpoint is gone.
test_finish_cleanup_refuses_a_live_tmux_endpoint_and_recovers_after_it_dies() {
  local dir state rc
  dir=$(make_case finish-cleanup-live-endpoint)
  state="$dir/state"
  mkdir -p "$state"
  printf 'done: task finished\n' > "$state/liveorphan.status"
  : > "$state/liveorphan.turn-ended"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  FM_FAKE_TMUX_WINDOWS='firstmate:fm-liveorphan' PATH="$dir/fakebin:$PATH" \
    run_gc "$state" liveorphan --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup retired a record whose endpoint is still alive (rc=$rc)"
  grep -F 'live backend endpoint' "$dir/gc.err" >/dev/null \
    || fail "the live-endpoint refusal did not print: $(cat "$dir/gc.err")"
  grep -F 'fm-liveorphan' "$dir/gc.err" >/dev/null \
    || fail "the live-endpoint refusal did not name the window: $(cat "$dir/gc.err")"
  [ -f "$state/liveorphan.status" ] || fail "live-endpoint refusal removed the status log"
  [ -f "$state/liveorphan.turn-ended" ] || fail "live-endpoint refusal removed task residue"

  rc=0
  PATH="$dir/fakebin:$PATH" \
    run_gc "$state" liveorphan --finish-cleanup > "$dir/gc2.out" 2> "$dir/gc2.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "finish-cleanup refused the same record after its endpoint died: $(cat "$dir/gc2.err")"
  [ ! -e "$state/liveorphan.status" ] || fail "the status log survived finish-cleanup after endpoint death"
  pass "finish-cleanup refuses a live labeled endpoint and retires the same record once it is gone"
}

# The same refusal against a REAL live pane on an isolated tmux server (the
# exact shape the adversarial review reproduced): a window named for the task
# with a live foreground process, no metadata, no temp root. Absence of
# /tmp/fm-<id> must not read as endpoint death.
test_finish_cleanup_refuses_a_real_live_tmux_window() {
  local real_tmux dir state sock_dir rc
  real_tmux=$(command -v tmux || true)
  if [ -z "$real_tmux" ]; then
    pass "real live-window refusal: tmux not installed; live-socket case skipped"
    return 0
  fi
  dir=$(make_case finish-cleanup-real-live-window)
  state="$dir/state"
  mkdir -p "$state"
  printf 'done: task finished\n' > "$state/liveorphan.status"
  : > "$state/liveorphan.turn-ended"
  # The socket dir lives under short /tmp paths: macOS unix socket paths cap
  # out near 104 characters and $TMPDIR-based case paths already approach it.
  sock_dir=$(mktemp -d /tmp/fmsgc-sock.XXXXXX) || fail "could not create the tmux socket dir"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
export TMUX_TMPDIR="$sock_dir"
exec "$real_tmux" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$sock_dir" \
    "$real_tmux" new-session -d -s fmlive -n fm-liveorphan -x 200 -y 50 \
    'exec sleep 600' || fail "could not start the isolated live window"

  rc=0
  PATH="$dir/fakebin:$PATH" \
    run_gc "$state" liveorphan --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup retired a record with a real live window (rc=$rc)"
  grep -F 'live backend endpoint' "$dir/gc.err" >/dev/null \
    || fail "the real live-window refusal did not print: $(cat "$dir/gc.err")"
  [ -f "$state/liveorphan.status" ] || fail "real live-window refusal removed the status log"
  [ -f "$state/liveorphan.turn-ended" ] || fail "real live-window refusal removed task residue"

  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$sock_dir" \
    "$real_tmux" kill-session -t fmlive 2>/dev/null || true
  rc=0
  PATH="$dir/fakebin:$PATH" \
    run_gc "$state" liveorphan --finish-cleanup > "$dir/gc2.out" 2> "$dir/gc2.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "finish-cleanup refused the record after the real window died: $(cat "$dir/gc2.err")"
  [ ! -e "$state/liveorphan.status" ] || fail "the status log survived after the real window died"
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$sock_dir" \
    "$real_tmux" kill-server 2>/dev/null || true
  rm -rf "$sock_dir"
  pass "finish-cleanup refuses a real live tmux window and retires the record once it is gone"
}

# Review finding 2: two ordinary single-link token files carrying the same
# token text used to let cleanup of one task deregister the global hook whose
# auth record named the OTHER task. The registration's content must name the
# requested task's own turn-ended marker before the deregistration runs.
test_finish_cleanup_refuses_a_turnend_auth_record_naming_a_live_sibling() {
  local dir state token token_auth rc
  dir=$(make_case finish-cleanup-shared-token)
  state="$dir/state"
  token=fm.sharedtoken
  token_auth="$dir/fakehome/.kimi-code/fm-turn-end.d/$token"
  mkdir -p "$state" "$(dirname "$token_auth")"
  printf 'done: retired task complete\n' > "$state/retired.status"
  : > "$state/retired.turn-ended"
  printf '%s\n' "$token" > "$state/retired.kimi-turnend-token"
  printf 'backend=tmux\nwindow=firstmate:fm-live\n' > "$state/live.meta"
  printf 'working: live\n' > "$state/live.status"
  printf '%s\n' "$token" > "$state/live.kimi-turnend-token"
  printf '%s\n' "$state/live.turn-ended" > "$token_auth"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  PATH="$dir/fakebin:$PATH" HOME="$dir/fakehome" \
    run_gc "$state" retired --finish-cleanup > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup deregistered a registration naming a live sibling (rc=$rc)"
  grep -F 'different task' "$dir/gc.err" >/dev/null \
    || fail "the shared-token refusal did not print: $(cat "$dir/gc.err")"
  [ -f "$token_auth" ] || fail "the shared-token refusal deregistered the live sibling's hook"
  [ -f "$state/retired.kimi-turnend-token" ] || fail "the shared-token refusal removed the requested token"
  [ -f "$state/live.kimi-turnend-token" ] || fail "the shared-token refusal removed the sibling's token"
  { [ -f "$state/live.meta" ] && [ -f "$state/live.status" ]; } \
    || fail "the shared-token refusal touched the sibling's anchors"
  [ -f "$state/retired.status" ] || fail "the shared-token refusal removed the status log"

  printf '%s\n' "$state/retired.turn-ended" > "$token_auth"
  rc=0
  PATH="$dir/fakebin:$PATH" HOME="$dir/fakehome" \
    run_gc "$state" retired --finish-cleanup > "$dir/gc2.out" 2> "$dir/gc2.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "finish-cleanup refused the same record once the registration named its own task: $(cat "$dir/gc2.err")"
  [ ! -e "$token_auth" ] || fail "the requested task's own registration was not deregistered"
  [ ! -e "$state/retired.kimi-turnend-token" ] || fail "the requested token survived its own cleanup"
  [ -f "$state/live.kimi-turnend-token" ] || fail "the sibling's token was removed by the requested task's cleanup"
  pass "turn-end cleanup validates the registration's named task and refuses a live sibling's, then retires its own"
}

# Review finding 3: legal ids a.b and a_b normalize to the same watcher marker
# names, so retiring one task's markers used to delete the other live task's
# notification state. The retirement writer must refuse while a colliding
# sibling's anchors are live.
test_marker_ambiguous_ids_refuse_while_a_colliding_sibling_is_live() {
  local dir state rc marker
  dir=$(make_case marker-ambiguity)
  state="$dir/state"
  mkdir -p "$state"
  printf 'done: dotted task complete\n' > "$state/a.b.status"
  printf 'backend=tmux\nwindow=firstmate:fm-a_b\n' > "$state/a_b.meta"
  printf 'working: sibling alive\n' > "$state/a_b.status"
  seed_all_watcher_markers "$state" a_b sibling >/dev/null \
    || fail "could not seed sibling markers"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  PATH="$dir/fakebin:$PATH" \
    run_gc "$state" a.b > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "gc retired a.b while its marker sibling a_b was live (rc=$rc)"
  grep -F 'a_b' "$dir/gc.err" >/dev/null \
    || fail "the ambiguity refusal did not name the sibling: $(cat "$dir/gc.err")"
  [ -f "$state/a_b.meta" ] || fail "ambiguity refusal removed the sibling meta"
  [ -f "$state/a_b.status" ] || fail "ambiguity refusal removed the sibling status"
  for marker in .seen-a_b_status .seen-a_b_turn-ended .hb-surfaced-a_b .subsuper-seen-status-a_b; do
    [ -f "$state/$marker" ] || fail "ambiguity refusal removed the sibling marker $marker"
  done
  [ "$(cat "$state/.hb-surfaced-a_b")" = "hb-sibling" ] \
    || fail "ambiguity refusal altered a sibling marker's content"
  [ -f "$state/a.b.status" ] || fail "ambiguity refusal removed the target's status log"

  rc=0
  PATH="$dir/fakebin:$PATH" \
    run_gc "$state" a_b > "$dir/gc2.out" 2> "$dir/gc2.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "gc retired a_b while its marker sibling a.b was live (rc=$rc)"
  for marker in .seen-a_b_status .seen-a_b_turn-ended .hb-surfaced-a_b .subsuper-seen-status-a_b; do
    [ -f "$state/$marker" ] || fail "the reverse-direction refusal removed the sibling marker $marker"
  done

  : > "$state/a.b.turn-ended"
  printf '!\n' > "$state/a.b.kimi-turnend-token"
  rc=0
  PATH="$dir/fakebin:$PATH" \
    run_gc "$state" a.b --finish-cleanup > "$dir/gc3.out" 2> "$dir/gc3.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "finish-cleanup retired a.b while a_b was live (rc=$rc)"
  [ -f "$state/a_b.status" ] || fail "finish-cleanup ambiguity refusal removed the sibling status"
  [ -f "$state/a.b.status" ] || fail "finish-cleanup ambiguity refusal removed the target status"
  [ -f "$state/a.b.turn-ended" ] || fail "finish-cleanup ambiguity refusal removed target residue before retirement"
  [ -f "$state/a.b.kimi-turnend-token" ] || fail "finish-cleanup ambiguity refusal removed the target token before retirement"

  rm -f "$state/a_b.meta" "$state/a_b.status" "$state/a.b.turn-ended" "$state/a.b.kimi-turnend-token"
  rc=0
  PATH="$dir/fakebin:$PATH" \
    run_gc "$state" a.b > "$dir/gc4.out" 2> "$dir/gc4.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "gc refused a.b after its sibling disappeared: $(cat "$dir/gc4.err")"
  [ ! -e "$state/a.b.status" ] || fail "the target status log survived after the sibling disappeared"
  for marker in .seen-a_b_status .seen-a_b_turn-ended .hb-surfaced-a_b .subsuper-seen-status-a_b; do
    [ ! -e "$state/$marker" ] || fail "the stale sibling markers survived after the sibling disappeared: $marker"
  done
  pass "marker-ambiguous ids refuse while a colliding sibling is live, in both directions and both paths"
}

test_marker_collision_check_is_linear_in_task_id_length() {
  local dir state task sibling rc
  dir=$(make_case marker-ambiguity-linear)
  state="$dir/state"
  task=a______________________________b
  sibling=a..............................b
  printf 'done: underscored task complete\n' > "$state/$task.status"
  printf 'working: dotted sibling alive\n' > "$state/$sibling.status"

  rc=0
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" \
    perl -e 'alarm 3; exec @ARGV' "$GC" "$task" \
    > "$dir/gc.out" 2> "$dir/gc.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "long marker collision did not refuse promptly (rc=$rc)"
  grep -F "$sibling" "$dir/gc.err" >/dev/null \
    || fail "long marker collision did not name its sibling: $(cat "$dir/gc.err")"
  [ -f "$state/$task.status" ] || fail "long collision refusal removed the target status"
  [ -f "$state/$sibling.status" ] || fail "long collision refusal removed the sibling status"
  pass "marker collision checks scan live anchors without exponential id expansion"
}

# Review finding 4: the old ordering removed the status anchor and then ran a
# separate rm for the turn-ended seen marker, so a crash between them stranded
# a marker behind a missing anchor that no invocation could resume. The anchor
# now goes LAST; a run fault-injected into that final rm must leave the anchor
# behind and converge under the second identical invocation.
test_gc_killed_during_marker_retirement_converges_on_the_next_run() {
  local dir state rc marker crash
  dir=$(make_case crash-convergence)
  state="$dir/state"
  mkdir -p "$state"
  printf 'done: crash test done\n' > "$state/crash.status"
  # Only the three retirable marker families: the daemon marker names the task
  # as an unrecognized record and the janitor would (correctly) refuse it.
  seed_retirable_watcher_markers "$state" crash crash >/dev/null \
    || fail "could not seed crash markers"
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
# Fault injection: when the final writer rm still has live markers to remove
# alongside the status anchor, remove the markers and die before the anchor -
# exactly the interrupt the status-last ordering must survive.
non_status=() status_args=() existing=0
for arg in "$@"; do
  case "$arg" in
    *.status) status_args+=("$arg") ;;
    *)
      non_status+=("$arg")
      [ -e "$arg" ] && existing=1
      ;;
  esac
done
if [ "${FM_FAKE_RM_CRASH:-}" = 1 ] && [ "$existing" -eq 1 ] && [ "${#status_args[@]}" -gt 0 ]; then
  /bin/rm -f "${non_status[@]}"
  kill -9 "$PPID" 2>/dev/null
  exit 0
fi
exec /bin/rm "$@"
SH
  chmod +x "$dir/fakebin/rm"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"

  rc=0
  FM_FAKE_RM_CRASH=1 PATH="$dir/fakebin:$PATH" \
    run_gc "$state" crash > "$dir/kill.out" 2> "$dir/kill.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "the fault-injected first run unexpectedly completed (rc=$rc)"
  [ -f "$state/crash.status" ] || fail "the killed run removed the status anchor, recreating the dead end"
  for marker in .seen-crash_status .seen-crash_turn-ended .hb-surfaced-crash; do
    [ ! -e "$state/$marker" ] || fail "the killed run left a marker behind alongside the anchor: $marker"
  done

  rc=0
  FM_FAKE_RM_CRASH=1 PATH="$dir/fakebin:$PATH" \
    run_gc "$state" crash > "$dir/second.out" 2> "$dir/second.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "the second run did not converge after the killed run: $(cat "$dir/second.err")"
  grep -F 'retired orphaned status record' "$dir/second.out" >/dev/null \
    || fail "the converged run did not report retirement: $(cat "$dir/second.out")"
  [ ! -e "$state/crash.status" ] || fail "the converged run left the status anchor behind"

  rc=0
  PATH="$dir/fakebin:$PATH" \
    run_gc "$state" crash > "$dir/third.out" 2> "$dir/third.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "the post-completion rerun refused instead of no-oping (rc=$rc): $(cat "$dir/third.err")"
  pass "a run killed between marker and anchor retirement converges under the second identical invocation"
}

test_invalid_and_absent_ids_refuse() {
  local dir state rc
  dir=$(make_case invalid-id)
  state="$dir/state"
  rc=0
  run_gc "$state" "../escape" > "$dir/escape.out" 2> "$dir/escape.err" || rc=$?
  [ "$rc" -eq 2 ] || fail "a path-unsafe id was not rejected as a usage error (rc=$rc)"
  # An absent anchor over a completely clean record is the idempotent rerun of
  # an already-completed retirement: a successful no-op, not a refusal.
  rc=0
  run_gc "$state" absent > "$dir/absent.out" 2> "$dir/absent.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "an absent status log over no records was not a clean no-op (rc=$rc): $(cat "$dir/absent.err")"
  # An absent anchor behind ANY surviving record is a partial state no
  # invocation can resume: refused, with the residue named.
  printf 'orphaned token\n' > "$state/absent.kimi-turnend-token"
  rc=0
  run_gc "$state" absent > "$dir/residue.out" 2> "$dir/residue.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an absent status log behind surviving records was not refused (rc=$rc)"
  grep -F 'absent.kimi-turnend-token' "$dir/residue.err" >/dev/null \
    || fail "the absent-anchor refusal did not name the surviving record: $(cat "$dir/residue.err")"
  [ -f "$state/absent.kimi-turnend-token" ] || fail "the absent-anchor refusal removed the residue"
  pass "path-unsafe ids refuse, absent anchors no-op only over clean records, and absent anchors behind residue name it"
}

test_orphaned_finished_status_is_retired_with_its_sidecars
test_id_suffixed_records_refuse
test_held_per_task_lock_refuses
test_other_tasks_per_task_locks_do_not_block
test_content_bound_nested_record_refuses
test_task_keyed_nested_records_refuse
test_unrecognized_nested_name_refuses
test_symlinked_subdirectory_refuses
test_home_wide_status_shape_refuses
test_nested_playbot_transaction_refuses
test_another_tasks_nested_record_does_not_block
test_home_wide_locks_do_not_block_word_ids
test_unrecognized_record_naming_the_task_refuses
test_sibling_task_with_longer_id_does_not_block
test_surviving_task_temp_root_refuses
test_gc_refuses_while_the_task_set_lock_is_held
test_live_task_record_refuses
test_unfinished_and_undecided_records_refuse
test_other_surviving_records_refuse
test_invalid_and_absent_ids_refuse
test_finish_cleanup_retires_partial_records_through_their_writers
test_finish_cleanup_preflights_late_pr_refusal
test_finish_cleanup_refuses_symlinked_turnend_token_without_mutation
test_finish_cleanup_preflights_turnend_auth_target
test_finish_cleanup_refuses_hardlinked_turnend_auth_target
test_finish_cleanup_preflights_unsafe_residue
test_finish_cleanup_preflights_unsafe_busy_state
test_finish_cleanup_preflights_status_presentation_retirement
test_finish_cleanup_retires_an_intact_busy_incarnation
test_finish_cleanup_refuses_when_a_writer_preserves_its_record
test_finish_cleanup_retires_only_its_own_gone_herdr_journal
test_finish_cleanup_refuses_records_no_writer_owns_and_retires_nothing
test_finish_cleanup_refuses_unfinished_work_and_retires_nothing
test_finish_cleanup_refuses_a_live_tmux_endpoint_and_recovers_after_it_dies
test_finish_cleanup_refuses_a_real_live_tmux_window
test_finish_cleanup_refuses_a_turnend_auth_record_naming_a_live_sibling
test_marker_ambiguous_ids_refuse_while_a_colliding_sibling_is_live
test_marker_collision_check_is_linear_in_task_id_length
test_gc_killed_during_marker_retirement_converges_on_the_next_run
