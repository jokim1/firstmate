#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
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
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
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
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# Real-process counterexample from the adversarial review: FM_POLL=garbage used to
# make the watcher sleep garbage (busy-loop, beacon thrash) while the guard used
# 900s. Both must share the normalized 15s cadence.
install_sleep_logger() {
  local fakebin=$1 log=$2 real
  # Prefer the absolute platform sleep so a prior PATH shim cannot recurse.
  if [ -x /bin/sleep ]; then
    real=/bin/sleep
  else
    real=$(command -v sleep) || fail "host sleep not found for logger shim"
  fi
  mkdir -p "$fakebin"
  cat > "$fakebin/sleep" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
exec '$real' "\$@"
SH
  chmod +x "$fakebin/sleep"
}

count_exact_sleep_args() {
  local log=$1 want=$2
  # Force string compare: awk's == is numeric when both sides look like numbers,
  # so want=010 would match a log line of 10 (base-10) without the "" concat.
  awk -v want="$want" '($0 "") == (want "") { c++ } END { print c + 0 }' "$log"
}

test_checkpoint_normalizes_garbage_poll_sleep_and_grace() {
  local home out err status fakebin sleep_log poll_calls grace
  home=$(make_home poll-garbage)
  out="$home/out.txt"
  err="$home/err.txt"
  fakebin="$home/fakebin"
  sleep_log="$home/sleep.log"
  : > "$sleep_log"
  install_sleep_logger "$fakebin" "$sleep_log"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_POLL=garbage FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    env -u FM_GUARD_GRACE \
    "$CHECKPOINT" --seconds 15 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "garbage-poll quiet checkpoint exit"
  # Never sleep the raw malformed token; sleep the shared default 15.
  [ "$(count_exact_sleep_args "$sleep_log" garbage)" -eq 0 ] \
    || fail "watcher slept raw FM_POLL=garbage"$'\n'"$(cat "$sleep_log")"
  poll_calls=$(count_exact_sleep_args "$sleep_log" 15)
  [ "$poll_calls" -ge 1 ] \
    || fail "watcher never slept the normalized 15s cadence"$'\n'"$(cat "$sleep_log")"
  unset FM_GUARD_GRACE 2>/dev/null || true
  grace=$(FM_POLL=garbage bash -c '. "$1"; fm_guard_grace_seconds' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$grace" = 900 ] || fail "guard grace for FM_POLL=garbage expected 900, got $grace"
  pass "checkpoint normalizes garbage FM_POLL for both sleep and grace"
}

test_checkpoint_normalizes_zero_and_negative_poll() {
  local home out err status fakebin sleep_log bad
  for bad in 0 -1; do
    home=$(make_home "poll-$bad")
    out="$home/out.txt"
    err="$home/err.txt"
    fakebin="$home/fakebin"
    sleep_log="$home/sleep.log"
    : > "$sleep_log"
    install_sleep_logger "$fakebin" "$sleep_log"
    status=0
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_POLL="$bad" FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      env -u FM_GUARD_GRACE \
      "$CHECKPOINT" --seconds 15 >"$out" 2>"$err" || status=$?
    expect_code 124 "$status" "FM_POLL=$bad quiet checkpoint exit"
    [ "$(count_exact_sleep_args "$sleep_log" "$bad")" -eq 0 ] \
      || fail "watcher slept raw FM_POLL=$bad"$'\n'"$(cat "$sleep_log")"
    [ "$(count_exact_sleep_args "$sleep_log" 15)" -ge 1 ] \
      || fail "watcher never slept normalized 15 under FM_POLL=$bad"$'\n'"$(cat "$sleep_log")"
  done
  pass "checkpoint normalizes zero and negative FM_POLL before sleep"
}

test_checkpoint_honors_fractional_poll_and_matching_grace() {
  local home out err status fakebin sleep_log grace
  home=$(make_home poll-fractional)
  out="$home/out.txt"
  err="$home/err.txt"
  fakebin="$home/fakebin"
  sleep_log="$home/sleep.log"
  : > "$sleep_log"
  install_sleep_logger "$fakebin" "$sleep_log"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    env -u FM_GUARD_GRACE \
    "$CHECKPOINT" --seconds 15 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "fractional-poll quiet checkpoint exit"
  [ "$(count_exact_sleep_args "$sleep_log" 0.2)" -ge 1 ] \
    || fail "watcher did not sleep fractional FM_POLL=0.2"$'\n'"$(cat "$sleep_log")"
  # Must not fall back to the default 15 when the fraction is valid.
  [ "$(count_exact_sleep_args "$sleep_log" 15)" -eq 0 ] \
    || fail "watcher fell back to 15 despite valid FM_POLL=0.2"$'\n'"$(cat "$sleep_log")"
  unset FM_GUARD_GRACE 2>/dev/null || true
  grace=$(FM_POLL=0.2 bash -c '. "$1"; fm_guard_grace_seconds' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$grace" = 12 ] || fail "guard grace for FM_POLL=0.2 expected 12, got $grace"
  pass "checkpoint honors fractional FM_POLL with matching grace"
}

# Zero-padded integers: sleep and grace must share the same base-10 seconds.
# Counterexample at 0ad9bc5: FM_POLL=010 slept 10s with grace 480 (octal);
# FM_POLL=0008 hard-errored empty grace while sleeping 8s (permanent false alarm).
test_checkpoint_canonicalizes_zero_padded_poll() {
  local home out err status fakebin sleep_log grace poll_token want_poll want_grace
  for poll_token in 010 0008; do
    case "$poll_token" in
      010) want_poll=10; want_grace=600 ;;
      0008) want_poll=8; want_grace=480 ;;
    esac
    home=$(make_home "poll-pad-$poll_token")
    mkdir -p "$home/root"
    out="$home/out.txt"
    err="$home/err.txt"
    fakebin="$home/fakebin"
    sleep_log="$home/sleep.log"
    : > "$sleep_log"
    install_sleep_logger "$fakebin" "$sleep_log"
    status=0
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_POLL="$poll_token" FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      env -u FM_GUARD_GRACE \
      "$CHECKPOINT" --seconds 15 >"$out" 2>"$err" || status=$?
    expect_code 124 "$status" "zero-padded FM_POLL=$poll_token quiet checkpoint exit"
    # Must never sleep the raw zero-padded token or fall into octal confusion.
    [ "$(count_exact_sleep_args "$sleep_log" "$poll_token")" -eq 0 ] \
      || fail "watcher slept raw zero-padded FM_POLL=$poll_token"$'\n'"$(cat "$sleep_log")"
    [ "$(count_exact_sleep_args "$sleep_log" "$want_poll")" -ge 1 ] \
      || fail "watcher never slept canonical $want_poll under FM_POLL=$poll_token"$'\n'"$(cat "$sleep_log")"
    unset FM_GUARD_GRACE 2>/dev/null || true
    grace=$(FM_POLL="$poll_token" bash -c '. "$1"; fm_guard_grace_seconds' _ "$ROOT/bin/fm-wake-lib.sh")
    [ "$grace" = "$want_grace" ] \
      || fail "grace for FM_POLL=$poll_token expected $want_grace, got '$grace'"
    # Fresh beacon must not false-alarm (0008 empty-grace counterexample).
    touch "$home/state/.last-watcher-beat"
    fm_write_meta "$home/state/task.meta" "window=firstmate:fm-task" "kind=ship"
    out=$(
      FM_ROOT_OVERRIDE="$home/root" \
        FM_HOME="$home" \
        FM_STATE_OVERRIDE="$home/state" \
        FM_CONFIG_OVERRIDE="$home/config" \
        FM_SUPERVISION_MODEL=autoarm \
        FM_POLL="$poll_token" \
        env -u FM_GUARD_GRACE \
        "$ROOT/bin/fm-guard.sh" 2>&1 || true
    )
    case "$out" in
      *'WATCHER DOWN'*)
        fail "fresh beacon under FM_POLL=$poll_token must not false-alarm, got: $out"
        ;;
      *'value too great for base'*)
        fail "FM_POLL=$poll_token must not produce octal arithmetic errors, got: $out"
        ;;
    esac
  done
  pass "checkpoint canonicalizes zero-padded FM_POLL for sleep and grace"
}

# Sub-resolution and oversize FM_POLL must not reach sleep 0 / saturating sleep.
# Round-6 counterexamples: 0.0000001 rounded to "0" (busy-loop); huge integer
# saturated to INT64_MAX (macOS sleep usage error + grace overflow to 1).
test_checkpoint_rejects_subresolution_and_oversize_poll() {
  local home out err status fakebin sleep_log grace
  # 1) Sub-resolution fraction -> default 15, never sleep 0.
  home=$(make_home poll-subres)
  fakebin="$home/fakebin"
  sleep_log="$home/sleep.log"
  : > "$sleep_log"
  install_sleep_logger "$fakebin" "$sleep_log"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_POLL=0.0000001 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    env -u FM_GUARD_GRACE \
    "$CHECKPOINT" --seconds 15 >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "sub-resolution FM_POLL quiet checkpoint exit"
  [ "$(count_exact_sleep_args "$sleep_log" 0)" -eq 0 ] \
    || fail "watcher slept 0 under FM_POLL=0.0000001"$'\n'"$(cat "$sleep_log")"
  [ "$(count_exact_sleep_args "$sleep_log" 0.0000001)" -eq 0 ] \
    || fail "watcher slept raw sub-resolution token"$'\n'"$(cat "$sleep_log")"
  [ "$(count_exact_sleep_args "$sleep_log" 15)" -ge 1 ] \
    || fail "watcher never slept default 15 under sub-resolution FM_POLL"$'\n'"$(cat "$sleep_log")"
  unset FM_GUARD_GRACE 2>/dev/null || true
  grace=$(FM_POLL=0.0000001 bash -c '. "$1"; fm_guard_grace_seconds' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$grace" = 900 ] || fail "sub-resolution FM_POLL grace expected 900, got $grace"

  # 2) Huge integer -> default 15, never INT64_MAX / unusable sleep args.
  home=$(make_home poll-huge)
  fakebin="$home/fakebin"
  sleep_log="$home/sleep.log"
  : > "$sleep_log"
  install_sleep_logger "$fakebin" "$sleep_log"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_POLL=99999999999999999999 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    env -u FM_GUARD_GRACE \
    "$CHECKPOINT" --seconds 15 >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "huge FM_POLL quiet checkpoint exit"
  [ "$(count_exact_sleep_args "$sleep_log" 15)" -ge 1 ] \
    || fail "watcher never slept default 15 under huge FM_POLL"$'\n'"$(cat "$sleep_log")"
  if grep -E '9223372036854775807|99999999999999999999' "$sleep_log" >/dev/null 2>&1; then
    fail "watcher slept a saturating/huge poll token"$'\n'"$(cat "$sleep_log")"
  fi
  grace=$(FM_POLL=99999999999999999999 bash -c '. "$1"; fm_guard_grace_seconds' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$grace" = 900 ] || fail "huge FM_POLL grace expected 900 (not overflow 1), got $grace"
  pass "checkpoint rejects sub-resolution and oversize FM_POLL"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_refill_passes_through_and_exits_zero
test_term_resistant_watcher_is_force_killed_at_deadline
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_checkpoint_normalizes_garbage_poll_sleep_and_grace
test_checkpoint_normalizes_zero_and_negative_poll
test_checkpoint_honors_fractional_poll_and_matching_grace
test_checkpoint_canonicalizes_zero_padded_poll
test_checkpoint_rejects_subresolution_and_oversize_poll
