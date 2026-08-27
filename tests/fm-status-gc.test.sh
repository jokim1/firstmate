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

run_gc() {  # <state> <id>
  FM_STATE_OVERRIDE="$1" FM_ROOT_OVERRIDE="$ROOT" "$GC" "$2"
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

test_invalid_and_absent_ids_refuse() {
  local dir state rc
  dir=$(make_case invalid-id)
  state="$dir/state"
  rc=0
  run_gc "$state" "../escape" > "$dir/escape.out" 2> "$dir/escape.err" || rc=$?
  [ "$rc" -eq 2 ] || fail "a path-unsafe id was not rejected as a usage error (rc=$rc)"
  rc=0
  run_gc "$state" absent > "$dir/absent.out" 2> "$dir/absent.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "an absent status log was not refused (rc=$rc)"
  pass "path-unsafe ids and absent status logs never reach retirement"
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
