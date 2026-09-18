#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
# Stale closes run the real watcher against a real isolated tmux process and must leave their exact terminal reason durable in the home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 30 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_refill_passes_through_and_exits_zero() {
  local home fixture out err status
  home=$(make_home refill)
  fixture="$home/fixture"
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir -p "$fixture/bin"
  cp "$CHECKPOINT" "$ROOT/bin/fm-timeout-lib.sh" "$fixture/bin/"
  cat > "$fixture/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
printf 'refill: re-evaluate ready work against free capacity\n'
SH
  chmod +x "$fixture/bin/fm-watch-checkpoint.sh" "$fixture/bin/fm-watch.sh"
  status=0
  FM_HOME="$home" "$fixture/bin/fm-watch-checkpoint.sh" --seconds 2 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "refill checkpoint exit"
  assert_contains "$(cat "$out")" "refill: re-evaluate ready work against free capacity" \
    "refill wake was not passed through"
  pass "checkpoint passes through refill-only wakes"
}

test_term_resistant_watcher_is_force_killed_at_deadline() {
  local home fixture out err pid_file watcher_pid status
  home=$(make_home term-resistant)
  fixture="$home/fixture"
  out="$home/out.txt"
  err="$home/err.txt"
  pid_file="$home/watcher.pid"
  mkdir -p "$fixture/bin"
  cp "$CHECKPOINT" "$ROOT/bin/fm-timeout-lib.sh" "$fixture/bin/"
  cat > "$fixture/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
exec perl -e '
  $SIG{TERM} = "IGNORE";
  open my $fh, ">", $ENV{FM_TERM_RESISTANT_PID_FILE} or die $!;
  print {$fh} "$$\n";
  close $fh;
  alarm 5;
  $SIG{ALRM} = sub { kill "KILL", $$ };
  sleep 600;
'
SH
  chmod +x "$fixture/bin/fm-watch-checkpoint.sh" "$fixture/bin/fm-watch.sh"
  status=0
  FM_HOME="$home" FM_TERM_RESISTANT_PID_FILE="$pid_file" \
    "$fixture/bin/fm-watch-checkpoint.sh" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "TERM-resistant checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" \
    "TERM-resistant checkpoint did not report its quiet deadline"
  watcher_pid=$(cat "$pid_file")
  ! kill -0 "$watcher_pid" 2>/dev/null \
    || fail "TERM-resistant watcher survived the checkpoint's hard deadline"
  pass "checkpoint force-kills a TERM-resistant watcher at its deadline"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 30 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_stale_checkpoint_exit_records_reason_in_home() {
  local home fakebin real_tmux socket_name idle_pane out err checkpoint_rc target watcher_pid
  home=$(make_home stale-exit-record)
  fakebin="$home/fakebin"
  out="$home/stale.out"
  err="$home/stale.err"
  target=secondmate:worker
  mkdir -p "$fakebin"
  real_tmux=$(command -v tmux) || fail "real tmux is required for the stale checkpoint regression"
  socket_name="fm-watch-checkpoint-$$-$RANDOM"
  idle_pane="$home/idle-pane.sh"

  printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$real_tmux" "$socket_name" > "$fakebin/tmux"
  printf '#!/usr/bin/env bash\nprintf "idle worker\\n"\nread -r -t 60 _ || true\n' > "$idle_pane"
  chmod +x "$fakebin/tmux" "$idle_pane"

  (
    cleanup_stale_tmux() {
      "$real_tmux" -L "$socket_name" kill-server 2>/dev/null || true
    }
    trap cleanup_stale_tmux EXIT

    "$real_tmux" -L "$socket_name" new-session -d -s secondmate -n worker "$idle_pane" \
      || fail "could not start the isolated real tmux process"
    printf 'window=%s\nkind=ship\nharness=codex\nbackend=tmux\n' "$target" > "$home/state/child.meta"

    checkpoint_rc=0
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$CHECKPOINT" --seconds 12 > "$out" 2> "$err" || checkpoint_rc=$?

    expect_code 0 "$checkpoint_rc" "stale checkpoint exit"
    assert_contains "$(cat "$out")" "stale: $target" "stale checkpoint did not expose its reason"
    grep -F "stale: $target" "$home/state/.watch-deliveries.log" >/dev/null \
      || fail "stale checkpoint did not leave its terminal reason in the delivery log"
    grep "$(printf '\tstale\t')" "$home/state/.wake-queue" | grep -F "$target" >/dev/null \
      || fail "stale checkpoint did not leave its actionable reason in the durable queue"
    grep -Eq '^pending:downtime:[A-Za-z0-9._-]+$' "$home/state/.watcher-down" \
      || fail "stale checkpoint did not publish its downtime generation"
    assert_absent "$home/state/.watch.lock/pid" "stale checkpoint left a watcher lock behind"
    watcher_pid=$(awk -F '\t' -v reason="stale: $target" '$3 == reason { pid=$1 } END { print pid }' \
      "$home/state/.watch-deliveries.log")
    case "$watcher_pid" in
      ''|*[!0-9]*) fail "stale delivery record did not carry the real watcher pid" ;;
    esac
    pass "stale checkpoint exits visibly and records its reason durably"
  ) || exit $?
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_refill_passes_through_and_exits_zero
test_term_resistant_watcher_is_force_killed_at_deadline
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_stale_checkpoint_exit_records_reason_in_home
