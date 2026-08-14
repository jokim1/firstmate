#!/usr/bin/env bash
# fm-send follow-up queue: park steers while busy, deliver while live, drop on
# terminal done/failed so harness busy-queue ghosts cannot re-trigger finished
# work. Dispatch is lease + pre-transport gate + ack (release on failure).
#
# Contract covered here:
#   - queued follow-up + terminal done -> no delivery
#   - queued follow-up + task still live -> delivers
#   - done: between lease and transport -> no delivery (queue invalidated)
#   - done: after transport_begin (final precheck) before send -> no delivery
#   - transport failure -> parked item retained (release, not destructive take)
#   - two live dispatchers cannot both lease/deliver the same head
#   - foreign live lease waits (no FIFO overtake of old head by a fresh steer)
#   - resolved: appended after done: must not re-arm ghost delivery
#   - teardown invalidates a parked queue
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-followup-queue)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    # Empty composer so idle submits confirm as empty.
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'sess:fm-worker\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# Transport that always fails send-keys so submit never confirms.
make_failing_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys-fail arg=%s\n' "${1:-}" >> "$FM_TMUX_LOG"
    exit 1 ;;
  display-message)
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'sess:fm-worker\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# --- library unit: terminal gate + lease/ack/release -------------------------

test_lease_drops_queue_when_terminal_done() {
  local home qdir
  home=$(setup_home term-done)
  # shellcheck source=bin/fm-send-followup-lib.sh
  . "$ROOT/bin/fm-send-followup-lib.sh"

  printf 'working: mid-turn\n' > "$home/state/crew-a.status"
  fm_send_followup_enqueue "$home/state" crew-a "archive the scratch notes" \
    || fail "enqueue while live should succeed"
  [ "$(fm_send_followup_count "$home/state" crew-a)" = 1 ] \
    || fail "queue should hold one parked steer"

  printf 'done: ready in branch fm/x\n' >> "$home/state/crew-a.status"
  if msg=$(fm_send_followup_lease "$home/state" crew-a 2>/dev/null); then
    fail "lease must refuse delivery after terminal done (got: $msg)"
  fi
  [ "$(fm_send_followup_count "$home/state" crew-a)" = 0 ] \
    || fail "terminal lease must invalidate the whole queue"
  qdir=$(fm_send_followup_dir "$home/state" crew-a)
  [ ! -d "$qdir" ] || fail "invalidated queue directory must be gone"
  pass "follow-up lease: queued + terminal done -> no delivery, queue invalidated"
}

test_lease_ack_delivers_when_task_still_live() {
  local home msg
  home=$(setup_home term-live)
  # shellcheck source=bin/fm-send-followup-lib.sh
  . "$ROOT/bin/fm-send-followup-lib.sh"

  printf 'working: still going\n' > "$home/state/crew-b.status"
  fm_send_followup_enqueue "$home/state" crew-b "apply the correction now" \
    || fail "enqueue while live should succeed"

  msg=$(fm_send_followup_lease "$home/state" crew-b) \
    || fail "lease must succeed while the task is still live"
  [ "$msg" = "apply the correction now" ] \
    || fail "lease must return the parked text (got: $msg)"
  [ "$(fm_send_followup_count "$home/state" crew-b)" = 1 ] \
    || fail "lease must keep the message file until ack"
  fm_send_followup_lease_may_deliver "$home/state" crew-b \
    || fail "live lease must remain deliverable"
  fm_send_followup_ack "$home/state" crew-b \
    || fail "ack after confirmed transport must succeed"
  [ "$(fm_send_followup_count "$home/state" crew-b)" = 0 ] \
    || fail "ack must remove the leased head"
  pass "follow-up lease+ack: queued + task still live -> delivers"
}

test_release_retains_item_after_failed_transport() {
  local home msg
  home=$(setup_home release-keep)
  # shellcheck source=bin/fm-send-followup-lib.sh
  . "$ROOT/bin/fm-send-followup-lib.sh"

  printf 'working: still going\n' > "$home/state/crew-c.status"
  fm_send_followup_enqueue "$home/state" crew-c "keep me on transport failure" \
    || fail "enqueue"
  msg=$(fm_send_followup_lease "$home/state" crew-c) \
    || fail "lease"
  [ "$msg" = "keep me on transport failure" ] || fail "unexpected lease body"
  # Simulate transport failure: release without ack.
  fm_send_followup_release "$home/state" crew-c \
    || fail "release after transport failure must succeed"
  [ "$(fm_send_followup_count "$home/state" crew-c)" = 1 ] \
    || fail "release must retain the parked item"
  msg=$(fm_send_followup_lease "$home/state" crew-c) \
    || fail "item must be re-leasable after release"
  [ "$msg" = "keep me on transport failure" ] \
    || fail "re-lease must return the same parked text"
  pass "follow-up release: transport failure retains item"
}

test_done_between_lease_and_deliver_blocks() {
  local home msg
  home=$(setup_home done-mid)
  # shellcheck source=bin/fm-send-followup-lib.sh
  . "$ROOT/bin/fm-send-followup-lib.sh"

  printf 'working: mid-turn\n' > "$home/state/crew-d.status"
  fm_send_followup_enqueue "$home/state" crew-d "ghost after done" \
    || fail "enqueue"
  msg=$(fm_send_followup_lease "$home/state" crew-d) \
    || fail "lease while live"
  # Terminal lands after lease, before transport - the race the old take() lost.
  printf 'done: ready in branch fm/d\n' >> "$home/state/crew-d.status"
  if fm_send_followup_transport_begin "$home/state" crew-d; then
    fail "transport_begin must refuse after done: lands between lease and begin"
  fi
  [ "$(fm_send_followup_count "$home/state" crew-d)" = 0 ] \
    || fail "terminal gate must invalidate the leased queue"
  pass "follow-up transport_begin: done during lease window -> no delivery"
}

test_exclusive_lease_refuses_second_live_owner() {
  local home msg barrier child i
  home=$(setup_home excl-lease)
  # shellcheck source=bin/fm-send-followup-lib.sh
  . "$ROOT/bin/fm-send-followup-lib.sh"

  printf 'working: mid-turn\n' > "$home/state/crew-e.status"
  fm_send_followup_enqueue "$home/state" crew-e "only one dispatcher" \
    || fail "enqueue"
  barrier="$home/leased.flag"
  rm -f "$barrier"
  # Hold an exclusive lease in a separate process (own $$). A ( ) subshell keeps
  # the parent's $$, so exclusive identity would not distinguish it.
  bash -c '
    set -u
    # shellcheck source=bin/fm-send-followup-lib.sh
    . "$1/bin/fm-send-followup-lib.sh"
    state=$2
    barrier=$3
    msg=$(fm_send_followup_lease "$state" crew-e) || exit 1
    [ "$msg" = "only one dispatcher" ] || exit 1
    : > "$barrier"
    while [ -f "$barrier" ]; do sleep 0.05; done
  ' bash "$ROOT" "$home/state" "$barrier" &
  child=$!
  i=0
  while [ ! -f "$barrier" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -f "$barrier" ] || { kill "$child" 2>/dev/null || true; fail "child never leased"; }

  lease_rc=0
  msg=$(fm_send_followup_lease "$home/state" crew-e 2>/dev/null) || lease_rc=$?
  if [ "$lease_rc" -eq 0 ]; then
    rm -f "$barrier"
    wait "$child" 2>/dev/null || true
    fail "second live dispatcher must not lease the same head (got: $msg)"
  fi
  [ "$lease_rc" = 3 ] \
    || fail "foreign live lease must return exit 3 (wait/retry), got $lease_rc"
  [ "$(fm_send_followup_count "$home/state" crew-e)" = 1 ] \
    || fail "exclusive refusal must leave the parked head intact"

  # Dead-owner reclaim: drop the barrier so the child exits, then wait for it.
  rm -f "$barrier"
  wait "$child" 2>/dev/null || true
  msg=$(fm_send_followup_lease "$home/state" crew-e) \
    || fail "dead-owner lease must be reclaimable"
  [ "$msg" = "only one dispatcher" ] || fail "reclaim must return the same head"
  pass "follow-up lease: exclusive live owner; dead-owner reclaim"
}

test_transport_confirm_after_begin_blocks_terminal() {
  local home msg
  home=$(setup_home seam-unit)
  # shellcheck source=bin/fm-send-followup-lib.sh
  . "$ROOT/bin/fm-send-followup-lib.sh"

  printf 'working: mid-turn\n' > "$home/state/crew-f.status"
  fm_send_followup_enqueue "$home/state" crew-f "ghost at transport seam" \
    || fail "enqueue"
  msg=$(fm_send_followup_lease "$home/state" crew-f) || fail "lease"
  fm_send_followup_transport_begin "$home/state" crew-f \
    || fail "begin must succeed while live"
  # Inject terminal AFTER final precheck (begin), BEFORE confirm/send.
  printf 'done: terminal transition raced transport\n' >> "$home/state/crew-f.status"
  if fm_send_followup_transport_confirm "$home/state" crew-f; then
    fail "confirm must refuse when done: lands after begin"
  fi
  [ "$(fm_send_followup_count "$home/state" crew-f)" = 0 ] \
    || fail "confirm terminal path must invalidate the queue"
  pass "follow-up transport seam: done after begin -> confirm aborts"
}

# --- fm-send integration ----------------------------------------------------

test_fm_send_busy_parks_without_delivery() {
  local dir fb home err log rc
  dir="$TMP_ROOT/busy-park"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home busy-park)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/worker.meta" "window=sess:fm-worker" "kind=ship" "harness=opencode"
  printf 'working: mid-turn\n' > "$home/state/worker.status"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=1 \
    "$SEND" worker "ghost archive instruction" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "busy park should exit 0"
  assert_contains "$(cat "$err")" "queued follow-up for worker" "busy park should report queueing"
  [ ! -s "$log" ] || fail "busy park must not harness-deliver"$'\n'"$(cat "$log")"
  [ "$(fm_send_followup_count "$home/state" worker)" = 1 ] \
    || fail "busy park must leave one queued message"
  pass "fm-send: busy task parks follow-up without delivery"
}

test_fm_send_queued_plus_terminal_done_does_not_deliver() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/done-nodeliver"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home done-nodeliver)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/worker.meta" "window=sess:fm-worker" "kind=ship" "harness=opencode"
  printf 'working: mid-turn\n' > "$home/state/worker.status"

  # Park while busy.
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=1 \
    "$SEND" worker "superseded archive instruction" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "park while busy"
  [ "$(fm_send_followup_count "$home/state" worker)" = 1 ] || fail "expected one parked steer"

  # Task goes terminal. Next idle send must drop the park and only deliver the
  # fresh message (secondmates/ship cleanup may still need a post-done nudge).
  printf 'done: ready in branch fm/worker\n' >> "$home/state/worker.status"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=0 \
    "$SEND" worker "post-done cleanup only" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "idle send after terminal done"
  got=$(cat "$log")
  assert_contains "$got" "arg=post-done cleanup only" "fresh post-done message should deliver"
  assert_no_grep "superseded archive instruction" "$log" \
    "parked follow-up must not deliver after terminal done"
  [ "$(fm_send_followup_count "$home/state" worker)" = 0 ] \
    || fail "terminal path must leave the queue empty"
  pass "fm-send: queued follow-up + terminal done -> no delivery"
}

test_fm_send_queued_plus_live_delivers() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/live-deliver"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home live-deliver)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/worker.meta" "window=sess:fm-worker" "kind=ship" "harness=opencode"
  printf 'working: mid-turn\n' > "$home/state/worker.status"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=1 \
    "$SEND" worker "mid-turn correction" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "park while busy"
  [ ! -s "$log" ] || fail "park must not deliver yet"$'\n'"$(cat "$log")"

  # Still live (working). Idle send drains the parked correction then the new line.
  printf 'working: continuing\n' >> "$home/state/worker.status"
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=0 \
    "$SEND" worker "next steer" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "idle drain+send while live"
  got=$(cat "$log")
  assert_contains "$got" "arg=mid-turn correction" "parked follow-up must deliver while live"
  assert_contains "$got" "arg=next steer" "new idle steer must also deliver"
  [ "$(fm_send_followup_count "$home/state" worker)" = 0 ] \
    || fail "live drain must empty the queue"
  pass "fm-send: queued follow-up + task still live -> delivers"
}

test_fm_send_done_during_transport_window_no_delivery() {
  local dir fb home err log rc hook
  dir="$TMP_ROOT/done-during"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home done-during)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/worker.meta" "window=sess:fm-worker" "kind=ship" "harness=opencode"
  printf 'working: mid-turn\n' > "$home/state/worker.status"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=1 \
    "$SEND" worker "ghost during transport window" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "park while busy"
  [ "$(fm_send_followup_count "$home/state" worker)" = 1 ] || fail "precondition: queued"

  # Inject terminal done after lease and before transport_begin.
  hook="printf 'done: ready in branch fm/during\n' >> \"$home/state/worker.status\""
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=0 \
    FM_SEND_FOLLOWUP_AFTER_LEASE_HOOK="$hook" \
    "$SEND" worker "fresh after terminal" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "idle send with mid-lease done"
  assert_no_grep "ghost during transport window" "$log" \
    "parked follow-up must not deliver when done: lands after lease"
  # Fresh post-terminal steer may still deliver (post-done cleanup); the ghost must not.
  assert_contains "$(cat "$log")" "arg=fresh after terminal" \
    "caller message after terminal invalidation should still deliver"
  [ "$(fm_send_followup_count "$home/state" worker)" = 0 ] \
    || fail "done-during-lease path must leave the queue empty"
  pass "fm-send: done during lease/transport window -> no ghost delivery"
}

# Transport seam: done: lands AFTER begin setup and BEFORE the last-instant
# confirm (PRE_SEND / immediately before backend). Ghost must not deliver.
test_fm_send_transport_seam_done_after_begin() {
  local dir fb home err log rc hook
  dir="$TMP_ROOT/transport-seam"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home transport-seam)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/worker.meta" "window=sess:fm-worker" "kind=ship" "harness=opencode"
  printf 'working: live before park\n' > "$home/state/worker.status"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=1 \
    "$SEND" worker "ghost during transport" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "park while busy"
  [ "$(fm_send_followup_count "$home/state" worker)" = 1 ] || fail "precondition: queued"

  # Inject at the last-instant gate (PRE_SEND runs immediately before confirm+send).
  hook="printf 'done: terminal transition raced transport\n' >> \"$home/state/worker.status\""
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=0 \
    FM_SEND_FOLLOWUP_PRE_SEND_HOOK="$hook" \
    "$SEND" worker "fresh after race" >/dev/null 2>"$err"; rc=$?
  # Late gate aborts the queued deliver; caller message may still run or the
  # whole send may exit non-zero if the gate failure path exits the drain.
  assert_no_grep "ghost during transport" "$log" \
    "parked follow-up must not deliver when done: lands at last-instant gate"
  [ "$(fm_send_followup_count "$home/state" worker)" = 0 ] \
    || fail "transport-seam path must leave the queue empty after terminal invalidate"
  pass "fm-send: transport seam done at last-instant gate -> no ghost delivery"
}

# Two concurrent fm-send processes: exclusive lease + wait preserves FIFO
# (old parked head before a later dispatcher's fresh steer).
test_fm_send_two_dispatchers_fifo_no_overtake() {
  local dir fb home err_a err_b log rc_a rc_b barrier_dir go_file head_line new_line
  dir="$TMP_ROOT/two-disp"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home two-disp)
  err_a="$dir/a.err"; err_b="$dir/b.err"
  # One shared transport log so global delivery order is observable.
  log="$dir/shared.tmux.log"; : > "$log"
  barrier_dir="$dir/barrier"
  mkdir -p "$barrier_dir"
  go_file="$barrier_dir/go"
  rm -f "$go_file"
  fm_write_meta "$home/state/worker.meta" "window=sess:fm-worker" "kind=ship" "harness=opencode"
  printf 'working: mid-turn\n' > "$home/state/worker.status"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=1 \
    "$SEND" worker "old parked head" >/dev/null 2>"$err_a"; rc=$?
  expect_code 0 "$rc" "park while busy"
  [ "$(fm_send_followup_count "$home/state" worker)" = 1 ] || fail "precondition: queued"
  printf 'working: continuing\n' >> "$home/state/worker.status"

  # A leases the head and holds; B must wait (exit 3 loop) instead of sending
  # "new steer" first.
  hook="touch \"$barrier_dir/leased-\$\"; n=0; while [ ! -f \"$go_file\" ] && [ \"\$n\" -lt 200 ]; do sleep 0.05; n=\$((n+1)); done"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=0 \
    FM_SEND_FOLLOWUP_AFTER_LEASE_HOOK="$hook" \
    FM_SEND_FOLLOWUP_LEASE_WAIT_SLEEP=0.05 \
    FM_SEND_FOLLOWUP_LEASE_WAIT_MAX=10 \
    "$SEND" worker "concurrent fresh A" >/dev/null 2>"$err_a" &
  pid_a=$!

  n=0
  while [ "$(find "$barrier_dir" -name 'leased-*' 2>/dev/null | wc -l | tr -d ' ')" -lt 1 ] && [ "$n" -lt 100 ]; do
    sleep 0.05
    n=$((n + 1))
  done
  [ "$(find "$barrier_dir" -name 'leased-*' 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] \
    || { kill "$pid_a" 2>/dev/null || true; fail "dispatcher A never leased the head"; }

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=0 \
    FM_SEND_FOLLOWUP_LEASE_WAIT_SLEEP=0.05 \
    FM_SEND_FOLLOWUP_LEASE_WAIT_MAX=10 \
    "$SEND" worker "new steer after foreign lease" >/dev/null 2>"$err_b" &
  pid_b=$!

  # B is waiting on foreign lease; old head must not yet be overtaken by B.
  sleep 0.3
  assert_no_grep "new steer after foreign lease" "$log" \
    "fresh steer must wait while a foreign live lease holds the parked head"

  : > "$go_file"
  wait "$pid_a"; rc_a=$?
  wait "$pid_b"; rc_b=$?

  expect_code 0 "$rc_a" "dispatcher A exit"
  expect_code 0 "$rc_b" "dispatcher B exit"
  assert_contains "$(cat "$log")" "arg=old parked head" "parked head must deliver"
  assert_contains "$(cat "$log")" "arg=new steer after foreign lease" "waiting dispatcher fresh must deliver after wait"
  head_line=$(grep -nF 'arg=old parked head' "$log" | head -1 | cut -d: -f1)
  new_line=$(grep -nF 'arg=new steer after foreign lease' "$log" | head -1 | cut -d: -f1)
  [ -n "$head_line" ] && [ -n "$new_line" ] \
    || fail "missing ordering lines"$'\n'"$(cat "$log")"
  [ "$head_line" -lt "$new_line" ] \
    || fail "FIFO overtake: new steer (line $new_line) before old head (line $head_line)"$'\n'"$(cat "$log")"
  [ "$(grep -cF 'arg=old parked head' "$log")" = 1 ] \
    || fail "parked head must deliver exactly once"
  [ "$(fm_send_followup_count "$home/state" worker)" = 0 ] \
    || fail "queue must be empty after exclusive drain+wait"
  pass "fm-send: foreign-lease wait preserves FIFO (old head before new steer)"
}

test_fm_send_transport_failure_retains_item() {
  local dir fb home err log rc
  dir="$TMP_ROOT/xport-fail"; mkdir -p "$dir"
  fb=$(make_failing_stubs "$dir"); home=$(setup_home xport-fail)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/worker.meta" "window=sess:fm-worker" "kind=ship" "harness=opencode"
  printf 'working: mid-turn\n' > "$home/state/worker.status"

  # Park with a successful (busy) path that never transports.
  PATH="$(make_stubs "$dir/parkbin"):$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=1 \
    "$SEND" worker "retain on transport failure" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "park while busy"
  [ "$(fm_send_followup_count "$home/state" worker)" = 1 ] || fail "precondition: queued"

  # Idle drain with failing transport: must exit nonzero and keep the park.
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=0 \
    "$SEND" worker "should not clear the park" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "failed transport must exit nonzero (got 0)"
  [ "$(fm_send_followup_count "$home/state" worker)" = 1 ] \
    || fail "transport failure must retain the parked follow-up"
  pass "fm-send: transport failure retains parked follow-up"
}

test_teardown_invalidates_followup_queue() {
  local home
  home=$(setup_home teardown-q)
  # shellcheck source=bin/fm-send-followup-lib.sh
  . "$ROOT/bin/fm-send-followup-lib.sh"

  printf 'working: x\n' > "$home/state/gone.status"
  fm_send_followup_enqueue "$home/state" gone "should not survive teardown" \
    || fail "enqueue"
  [ "$(fm_send_followup_count "$home/state" gone)" = 1 ] || fail "precondition: queued"

  fm_send_followup_invalidate "$home/state" gone || fail "invalidate"
  [ "$(fm_send_followup_count "$home/state" gone)" = 0 ] \
    || fail "teardown invalidation must clear the queue"
  pass "follow-up invalidate: teardown-equivalent clear drops parked steers"
}

# Review counterexample: resolved: after done: used to re-arm every terminal
# gate because is_terminal only read the last line. Mirror the reproduced steps.
test_is_terminal_skips_trailing_resolved_after_done() {
  local home
  home=$(setup_home term-resolved)
  # shellcheck source=bin/fm-send-followup-lib.sh
  . "$ROOT/bin/fm-send-followup-lib.sh"

  {
    printf 'needs-decision [key=k1]: pick A or B\n'
    printf 'working: mid-turn\n'
    printf 'done: ready in branch fm/worker\n'
    printf 'resolved [key=k1]: answered: use A\n'
  } > "$home/state/crew-r.status"

  fm_send_followup_is_terminal "$home/state" crew-r \
    || fail "trailing resolved after done must still count as terminal"
  # Relaunch: a later working: is a new incarnation and must be live.
  printf 'working: relaunched\n' >> "$home/state/crew-r.status"
  if fm_send_followup_is_terminal "$home/state" crew-r; then
    fail "working: after done: must count as live (new incarnation)"
  fi
  pass "follow-up is_terminal: skips trailing resolved after done; working re-arms live"
}

test_fm_send_resolved_after_done_does_not_rearm_ghost() {
  local dir fb home err log rc
  dir="$TMP_ROOT/resolved-rearm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home resolved-rearm)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/worker.meta" "window=sess:fm-worker" "kind=ship" "harness=opencode"

  # Step 1: open decision + mid-turn work.
  {
    printf 'needs-decision [key=k1]: pick A or B\n'
    printf 'working: mid-turn\n'
  } > "$home/state/worker.status"

  # Step 2: park a steer while busy.
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=1 \
    "$SEND" worker "ghost after resolve" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "park while busy"
  [ "$(fm_send_followup_count "$home/state" worker)" = 1 ] \
    || fail "precondition: one parked steer"
  [ ! -s "$log" ] || fail "park must not deliver yet"$'\n'"$(cat "$log")"

  # Step 3: worker ends terminal; decision key k1 still open.
  printf 'done: ready in branch fm/worker\n' >> "$home/state/worker.status"

  # Step 4: answerer-closes after done appends resolved after the done line.
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=0 \
    "$SEND" worker --resolve-key k1 "use A" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "resolve-key after done should still close the decision"
  assert_contains "$(cat "$home/state/worker.status")" \
    "resolved [key=k1]: answered: use A" \
    "status must end with resolved after done"
  # --resolve-key bypasses the park path; it may deliver the answer, never the ghost.
  assert_no_grep "ghost after resolve" "$log" \
    "resolve-key answer must not drain the parked ghost"
  [ "$(fm_send_followup_count "$home/state" worker)" = 1 ] \
    || fail "resolve-key must leave the park intact until a terminal drain"

  # Step 5: next idle steer must NOT ghost-deliver the park (the reproduced hole).
  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_SEND_SETTLE=0 FM_SEND_FORCE_BUSY=0 \
    "$SEND" worker "next steer" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "idle send after resolved-after-done"
  assert_no_grep "ghost after resolve" "$log" \
    "parked follow-up must not re-arm after resolved: trails done:"
  assert_contains "$(cat "$log")" "arg=next steer" \
    "fresh post-terminal steer should still deliver"
  [ "$(fm_send_followup_count "$home/state" worker)" = 0 ] \
    || fail "terminal drain must invalidate the parked queue"
  pass "fm-send: resolved after done does not re-arm ghost delivery"
}

# shellcheck source=bin/fm-send-followup-lib.sh
. "$ROOT/bin/fm-send-followup-lib.sh"

test_lease_drops_queue_when_terminal_done
test_lease_ack_delivers_when_task_still_live
test_release_retains_item_after_failed_transport
test_done_between_lease_and_deliver_blocks
test_exclusive_lease_refuses_second_live_owner
test_transport_confirm_after_begin_blocks_terminal
test_is_terminal_skips_trailing_resolved_after_done
test_fm_send_busy_parks_without_delivery
test_fm_send_queued_plus_terminal_done_does_not_deliver
test_fm_send_queued_plus_live_delivers
test_fm_send_done_during_transport_window_no_delivery
test_fm_send_transport_seam_done_after_begin
test_fm_send_two_dispatchers_fifo_no_overtake
test_fm_send_transport_failure_retains_item
test_fm_send_resolved_after_done_does_not_rearm_ghost
test_teardown_invalidates_followup_queue

echo "all fm-send-followup-queue tests passed"
