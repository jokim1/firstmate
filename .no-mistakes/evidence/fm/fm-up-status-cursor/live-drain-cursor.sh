#!/usr/bin/env bash
# Live-drive bin/fm-wake-drain.sh against disposable lab homes.
# Proves historical turn-ended annotations advance the presentation cursor
# so unread needs-decision/done wake-EVENT rows do not replay, while quiet
# turn-ends whose seen marker matches still skip without advancing routine bytes.
set -u
set -o pipefail

ROOT="/Users/josephkim/.no-mistakes/worktrees/6731d4e316ab/01M3FQD1AR8GP8AJTFFC5CVV91"
EVIDENCE="/Users/josephkim/.no-mistakes/evidence/01M3FQD1AR8GP8AJTFFC5CVV91"
BASE=bb69be62e1f8df465d674a35f7e2ce707b900501

mkdir -p "$EVIDENCE"
SUMMARY="$EVIDENCE/live-drain-cursor-summary.txt"
: > "$SUMMARY"

log() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }

fail() {
  log "FAIL: $*"
  exit 1
}

# Unset fleet-path overrides so paths resolve inside the lab home.
drain_env() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE "$@"
}

make_lab() {
  local lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || fail "mktemp lab failed"
  drain_env "$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null \
    || fail "fm-lab-home.sh create failed for $lab"
  printf '%s' "$lab"
}

append_wake() {
  local home=$1 kind=$2 key=$3 payload=$4
  drain_env FM_HOME="$home" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$ROOT" "$kind" "$key" "$payload" \
    || fail "fm_wake_append $kind $key failed"
}

mark_seen() {
  local home=$1 status=$2
  drain_env FM_HOME="$home" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_status_mark_current "$STATE" "$2"
  ' _ "$ROOT" "$status" \
    || fail "fm_wake_status_mark_current failed for $status"
}

run_drain() {
  local home=$1 drain_bin=$2 out=$3 err=$4
  drain_env FM_HOME="$home" "$drain_bin" > "$out" 2> "$err"
  local rc=$?
  # Guard warnings are non-fatal; drain itself should succeed.
  [ "$rc" -eq 0 ] || fail "drain exit $rc: $(cat "$err")"
}

ack_from_err() {
  local home=$1 drain_bin=$2 err=$3
  local cmd through gen
  cmd=$(grep '^WAKE_ACK_REQUIRED:' "$err" | tail -1) || true
  [ -n "$cmd" ] || return 0
  through=$(printf '%s\n' "$cmd" | sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p')
  gen=$(printf '%s\n' "$cmd" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p')
  [ -n "$through" ] && [ -n "$gen" ] || fail "could not parse ack from: $cmd"
  drain_env FM_HOME="$home" "$drain_bin" --ack-through "$through" --recovery-generation "$gen" \
    >/dev/null 2>/dev/null \
    || fail "ack --ack-through $through --recovery-generation $gen failed"
}

cursor_offset() {
  local state=$1 task=$2
  local manifest="$state/.status-presentation-cursor"
  [ -f "$manifest" ] || { printf '0'; return 0; }
  awk -F '\t' -v t="$task" '$1 == t { print $3; found=1 } END { if (!found) print 0 }' "$manifest"
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

setup_hist_status() {
  local state=$1
  local status="$state/task-hist.status"
  printf 'note: bootstrap cursor line\n' > "$status"
}

append_hist_payload() {
  local status=$1
  {
    printf 'needs-decision [key=captain-hold-hist-a-1]: hold A\n'
    printf 'needs-decision [key=captain-hold-hist-b-1]: hold B\n'
    printf 'needs-decision [key=captain-hold-hist-c-1]: hold C\n'
    printf 'done [key=child-outcome-hist-a]: scout done\n'
    printf 'done [corr=histdone1]: scout DONE narrative\n'
  } >> "$status"
}

# --- old-bin overlay for regression proof -----------------------------------
OLD_BIN=
cleanup() {
  [ -z "${LAB_NEW:-}" ] || rm -rf "$LAB_NEW"
  [ -z "${LAB_OLD:-}" ] || rm -rf "$LAB_OLD"
  [ -z "${LAB_QUIET:-}" ] || rm -rf "$LAB_QUIET"
  [ -z "${LAB_MIXED:-}" ] || rm -rf "$LAB_MIXED"
  [ -z "${OLD_BIN:-}" ] || rm -rf "$OLD_BIN"
}
trap cleanup EXIT

OLD_BIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-old-bin.XXXXXX") || fail "mktemp old-bin failed"
cp -R "$ROOT/bin/." "$OLD_BIN/" || fail "copy bin for old overlay failed"
git -C "$ROOT" show "$BASE:bin/fm-wake-drain.sh" > "$OLD_BIN/fm-wake-drain.sh" \
  || fail "could not materialize base fm-wake-drain.sh"
git -C "$ROOT" show "$BASE:bin/fm-wake-lib.sh" > "$OLD_BIN/fm-wake-lib.sh" \
  || fail "could not materialize base fm-wake-lib.sh"
git -C "$ROOT" show "$BASE:bin/fm-classify-lib.sh" > "$OLD_BIN/fm-classify-lib.sh" \
  || fail "could not materialize base fm-classify-lib.sh"
chmod +x "$OLD_BIN/fm-wake-drain.sh"

NEW_DRAIN="$ROOT/bin/fm-wake-drain.sh"
OLD_DRAIN="$OLD_BIN/fm-wake-drain.sh"

# ============================================================================
# Scenario: historical turn-ended annotation advances cursor (NEW drain)
# ============================================================================
log "=== NEW drain: historical turn-ended cursor advance ==="
LAB_NEW=$(make_lab)
STATE_NEW="$LAB_NEW/state"
setup_hist_status "$STATE_NEW"

run_drain "$LAB_NEW" "$NEW_DRAIN" "$EVIDENCE/new-prime.out" "$EVIDENCE/new-prime.err"
ack_from_err "$LAB_NEW" "$NEW_DRAIN" "$EVIDENCE/new-prime.err"

prime_size=$(file_size "$STATE_NEW/task-hist.status")
prime_off=$(cursor_offset "$STATE_NEW" task-hist)
log "after prime: cursor=$prime_off size=$prime_size"
[ "$prime_off" = "$prime_size" ] || fail "prime did not advance cursor to EOF ($prime_off vs $prime_size)"

append_hist_payload "$STATE_NEW/task-hist.status"

i=1
while [ "$i" -le 3 ]; do
  printf 'working [corr=histnew%d]: newer event %d\n' "$i" "$i" >> "$STATE_NEW/task-hist.status"
  rm -f "$STATE_NEW/.seen-task-hist_status"
  append_wake "$LAB_NEW" signal task-hist.turn-ended "signal: task-hist.turn-ended"
  run_drain "$LAB_NEW" "$NEW_DRAIN" "$EVIDENCE/new-drain-$i.out" "$EVIDENCE/new-drain-$i.err"
  out="$EVIDENCE/new-drain-$i.out"
  grep -F "wake annotation: latest wake-EVENT observed at drain, not current state; historical / not necessarily the triggering event: task-hist.status: working [corr=histnew${i}]: newer event ${i}" "$out" >/dev/null \
    || fail "NEW drain $i missed newer event annotation"
  if [ "$i" -eq 1 ]; then
    grep -F 'unread wake-EVENT since last drain, not current state; historical / not necessarily the triggering event: task-hist.status: needs-decision [key=captain-hold-hist-a-1]: hold A' "$out" >/dev/null \
      || fail "NEW first drain dropped sticky hold A"
    grep -F 'child-outcome-hist-a' "$out" >/dev/null \
      || fail "NEW first drain dropped sticky scout done"
  else
    if grep -F 'wake annotation:' "$out" | grep -F 'hold A' >/dev/null; then
      fail "NEW drain $i replayed sticky hold A"
    fi
    if grep -F 'wake annotation:' "$out" | grep -F 'child-outcome-hist-a' >/dev/null; then
      fail "NEW drain $i replayed sticky scout done"
    fi
  fi
  size=$(file_size "$STATE_NEW/task-hist.status")
  off=$(cursor_offset "$STATE_NEW" task-hist)
  log "NEW drain $i: cursor=$off size=$size"
  [ "$off" = "$size" ] || fail "NEW drain $i cursor stayed at $off instead of $size"
  ack_from_err "$LAB_NEW" "$NEW_DRAIN" "$EVIDENCE/new-drain-$i.err"
  i=$((i + 1))
done
log "PASS new-historical-cursor-advance"

# ============================================================================
# Regression: OLD drain replays the same unread wake-EVENT rows
# ============================================================================
log "=== OLD drain: expected replay of historical annotations ==="
LAB_OLD=$(make_lab)
STATE_OLD="$LAB_OLD/state"
setup_hist_status "$STATE_OLD"

run_drain "$LAB_OLD" "$OLD_DRAIN" "$EVIDENCE/old-prime.out" "$EVIDENCE/old-prime.err"
ack_from_err "$LAB_OLD" "$OLD_DRAIN" "$EVIDENCE/old-prime.err"

append_hist_payload "$STATE_OLD/task-hist.status"

replayed=0
i=1
while [ "$i" -le 3 ]; do
  printf 'working [corr=histnew%d]: newer event %d\n' "$i" "$i" >> "$STATE_OLD/task-hist.status"
  rm -f "$STATE_OLD/.seen-task-hist_status"
  append_wake "$LAB_OLD" signal task-hist.turn-ended "signal: task-hist.turn-ended"
  run_drain "$LAB_OLD" "$OLD_DRAIN" "$EVIDENCE/old-drain-$i.out" "$EVIDENCE/old-drain-$i.err"
  out="$EVIDENCE/old-drain-$i.out"
  size=$(file_size "$STATE_OLD/task-hist.status")
  off=$(cursor_offset "$STATE_OLD" task-hist)
  log "OLD drain $i: cursor=$off size=$size"
  if [ "$i" -gt 1 ]; then
    if grep -F 'wake annotation:' "$out" | grep -F 'hold A' >/dev/null; then
      replayed=1
      log "OLD drain $i replayed hold A (expected pre-fix behavior)"
    fi
  fi
  ack_from_err "$LAB_OLD" "$OLD_DRAIN" "$EVIDENCE/old-drain-$i.err"
  i=$((i + 1))
done
[ "$replayed" -eq 1 ] || fail "OLD drain did not replay hold A; regression baseline missing"
log "PASS old-drain-replays-historical-rows (pre-fix baseline)"

# ============================================================================
# Quiet turn-end whose seen marker matches skips annotation and does not
# advance through routine working/done bytes; a later direct signal can still
# annotate those bytes.
# ============================================================================
log "=== NEW drain: quiet turn-end skip preserves routine bytes ==="
LAB_QUIET=$(make_lab)
STATE_QUIET="$LAB_QUIET/state"
printf 'note: bootstrap quiet\n' > "$STATE_QUIET/task-quiet.status"
run_drain "$LAB_QUIET" "$NEW_DRAIN" "$EVIDENCE/quiet-prime.out" "$EVIDENCE/quiet-prime.err"
ack_from_err "$LAB_QUIET" "$NEW_DRAIN" "$EVIDENCE/quiet-prime.err"
quiet_prime_off=$(cursor_offset "$STATE_QUIET" task-quiet)
quiet_prime_size=$(file_size "$STATE_QUIET/task-quiet.status")
[ "$quiet_prime_off" = "$quiet_prime_size" ] || fail "quiet prime cursor $quiet_prime_off != $quiet_prime_size"

printf 'working [corr=q1]: on it\n' >> "$STATE_QUIET/task-quiet.status"
printf 'done [corr=q2]: shipped clean\n' >> "$STATE_QUIET/task-quiet.status"
mark_seen "$LAB_QUIET" "$STATE_QUIET/task-quiet.status"
append_wake "$LAB_QUIET" signal task-quiet.turn-ended "signal: task-quiet.turn-ended"
run_drain "$LAB_QUIET" "$NEW_DRAIN" "$EVIDENCE/quiet-drain.out" "$EVIDENCE/quiet-drain.err"

if grep -F 'wake annotation:' "$EVIDENCE/quiet-drain.out" >/dev/null; then
  fail "quiet turn-end printed annotations despite matching seen marker: $(cat "$EVIDENCE/quiet-drain.out")"
fi
quiet_off=$(cursor_offset "$STATE_QUIET" task-quiet)
quiet_size=$(file_size "$STATE_QUIET/task-quiet.status")
log "quiet after turn-end: cursor=$quiet_off size=$quiet_size prime=$quiet_prime_off"
[ "$quiet_off" = "$quiet_prime_off" ] || fail "quiet turn-end advanced cursor from $quiet_prime_off to $quiet_off"
[ "$quiet_off" != "$quiet_size" ] || fail "quiet turn-end advanced cursor to EOF, swallowing routine bytes"
ack_from_err "$LAB_QUIET" "$NEW_DRAIN" "$EVIDENCE/quiet-drain.err"

# Later direct .status signal must still be able to annotate the unacknowledged
# routine working/done bytes.
append_wake "$LAB_QUIET" signal task-quiet.status "signal: task-quiet.status"
run_drain "$LAB_QUIET" "$NEW_DRAIN" "$EVIDENCE/quiet-signal.out" "$EVIDENCE/quiet-signal.err"
grep -F 'wake annotation:' "$EVIDENCE/quiet-signal.out" | grep -F 'working [corr=q1]: on it' >/dev/null \
  || fail "later direct signal could not annotate preserved working line: $(cat "$EVIDENCE/quiet-signal.out")"
grep -F 'wake annotation:' "$EVIDENCE/quiet-signal.out" | grep -F 'done [corr=q2]: shipped clean' >/dev/null \
  || fail "later direct signal could not annotate preserved done line: $(cat "$EVIDENCE/quiet-signal.out")"
quiet_signal_off=$(cursor_offset "$STATE_QUIET" task-quiet)
quiet_signal_size=$(file_size "$STATE_QUIET/task-quiet.status")
log "quiet after later signal: cursor=$quiet_signal_off size=$quiet_signal_size"
[ "$quiet_signal_off" = "$quiet_signal_size" ] || fail "direct signal did not advance cursor through annotated span"
ack_from_err "$LAB_QUIET" "$NEW_DRAIN" "$EVIDENCE/quiet-signal.err"
log "PASS quiet-turn-end-skip-preserves-routine-bytes"

# ============================================================================
# Mixed tasks: only the task whose historical annotations actually printed
# advances; a quiet sibling stays put.
# ============================================================================
log "=== NEW drain: mixed printed vs skipped tasks ==="
LAB_MIXED=$(make_lab)
STATE_MIXED="$LAB_MIXED/state"
printf 'note: bootstrap printed\n' > "$STATE_MIXED/task-printed.status"
printf 'note: bootstrap skipped\n' > "$STATE_MIXED/task-skipped.status"
run_drain "$LAB_MIXED" "$NEW_DRAIN" "$EVIDENCE/mixed-prime.out" "$EVIDENCE/mixed-prime.err"
ack_from_err "$LAB_MIXED" "$NEW_DRAIN" "$EVIDENCE/mixed-prime.err"
printed_prime=$(cursor_offset "$STATE_MIXED" task-printed)
skipped_prime=$(cursor_offset "$STATE_MIXED" task-skipped)

{
  printf 'needs-decision [key=captain-hold-mix-1]: hold mixed\n'
  printf 'working [corr=mixnew1]: newer mixed event\n'
} >> "$STATE_MIXED/task-printed.status"
printf 'working [corr=skip1]: quiet sibling work\n' >> "$STATE_MIXED/task-skipped.status"
mark_seen "$LAB_MIXED" "$STATE_MIXED/task-skipped.status"
rm -f "$STATE_MIXED/.seen-task-printed_status"
append_wake "$LAB_MIXED" signal task-printed.turn-ended "signal: task-printed.turn-ended"
append_wake "$LAB_MIXED" signal task-skipped.turn-ended "signal: task-skipped.turn-ended"
run_drain "$LAB_MIXED" "$NEW_DRAIN" "$EVIDENCE/mixed-drain.out" "$EVIDENCE/mixed-drain.err"

grep -F 'wake annotation:' "$EVIDENCE/mixed-drain.out" | grep -F 'hold mixed' >/dev/null \
  || fail "mixed drain missed printed-task historical annotation"
if grep -F 'wake annotation:' "$EVIDENCE/mixed-drain.out" | grep -F 'quiet sibling work' >/dev/null; then
  fail "mixed drain annotated the skipped quiet sibling"
fi
printed_off=$(cursor_offset "$STATE_MIXED" task-printed)
printed_size=$(file_size "$STATE_MIXED/task-printed.status")
skipped_off=$(cursor_offset "$STATE_MIXED" task-skipped)
skipped_size=$(file_size "$STATE_MIXED/task-skipped.status")
log "mixed printed: cursor=$printed_off size=$printed_size"
log "mixed skipped: cursor=$skipped_off size=$skipped_size prime=$skipped_prime"
[ "$printed_off" = "$printed_size" ] || fail "printed task cursor not at EOF"
[ "$skipped_off" = "$skipped_prime" ] || fail "skipped quiet sibling cursor moved from $skipped_prime to $skipped_off"
[ "$skipped_off" != "$skipped_size" ] || fail "skipped quiet sibling cursor jumped to EOF"
ack_from_err "$LAB_MIXED" "$NEW_DRAIN" "$EVIDENCE/mixed-drain.err"
log "PASS mixed-printed-vs-skipped-cursor"

log "ALL LIVE SCENARIOS PASSED"
