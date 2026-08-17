#!/usr/bin/env bash
# Regression: endpoint-less tmux husk teardown (name-independent absence proof).
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-husk)
REAL_TMUX=$(command -v tmux || true)
REAL_LSOF=$(command -v lsof || true)
REAL_PGREP=$(command -v pgrep || true)
UID_N=$(id -u)

make_husk_case() {  # <name>
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/worktree" "$case_dir/project" "$fakebin"
  # Land-friendly empty project/worktree git pair (content equal to default).
  git init -q "$case_dir/origin.git" --bare
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/husk "$case_dir/worktree" main
  # empty pgrep/lsof for allow-path tests (no live servers)
  cat > "$fakebin/pgrep" <<'SH'
#!/usr/bin/env bash
# Legitimate no-match shape for macOS pgrep.
exit 1
SH
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
# Empty unix-domain inventory for husk absence proof; other queries empty-success
# so cwd process reap does not treat the fake as a hard failure.
for arg in "$@"; do
  if [ "$arg" = -U ]; then
    exit 1
  fi
done
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin"/*
  touch "$case_dir/home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_husk_meta() {  # <case> <id> [extra meta lines...]
  local dir=$1 id=$2
  shift 2
  {
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$dir/worktree"
    printf 'project=%s\n' "$dir/project"
    printf 'kind=ship\n'
    printf 'mode=direct-PR\n'
    printf 'backend=tmux\n'
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } > "$dir/home/state/$id.meta"
}

run_husk() {  # <case> <id> [--force]
  local dir=$1 id=$2
  shift 2
  # Prefer empty enum fakes, but keep real tmux for command -v.
  env -u TMUX -u TMUX_PANE \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    PATH="$dir/fakebin:/opt/homebrew/bin:/usr/bin:/bin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

test_legacy_missing_endpoint_still_refuses() {
  local dir id=no-binding
  dir=$(make_husk_case legacy-missing)
  # No endpoint_task_id → not a husk; missing window still refuses.
  printf 'worktree=%s\nproject=%s\nkind=scout\n' \
    "$dir/worktree" "$dir/project" > "$dir/home/state/$id.meta"
  set +e
  run_husk "$dir" "$id" --force >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "legacy missing window unexpectedly allowed"
  grep -q 'missing, empty, or ambiguous window endpoint' "$dir/err" \
    || fail "expected window endpoint refusal: $(cat "$dir/err")"
  [ -f "$dir/home/state/$id.meta" ] || fail "meta deleted on legacy refuse"
  pass "legacy missing-window without endpoint_task_id still refuses"
}

test_husk_with_empty_enum_and_land_allows() {
  local dir id=husk-land
  dir=$(make_husk_case allow-land)
  # HEAD is main and matches origin/main empty tree → land proof A.
  write_husk_meta "$dir" "$id"
  set +e
  run_husk "$dir" "$id" >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "landed husk with empty enum refused: $(cat "$dir/err")"
  [ ! -f "$dir/home/state/$id.meta" ] || fail "husk meta not removed on allow"
  pass "ship husk allows when enum empty and land proven"
}

test_husk_force_does_not_skip_land() {
  local dir id=husk-force-land
  dir=$(make_husk_case force-land)
  # Commit unique content not on origin → unlanded.
  printf 'unlanded\n' > "$dir/worktree/only-here"
  git -C "$dir/worktree" add only-here
  git -C "$dir/worktree" -c user.email=t@t -c user.name=t commit -q -m unlanded
  write_husk_meta "$dir" "$id"
  set +e
  run_husk "$dir" "$id" --force >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "force husk destroyed unlanded work"
  grep -qiE 'REFUSED|not landed|unpushed|positive land' "$dir/err" \
    || fail "expected land refusal under force: $(cat "$dir/err")"
  [ -f "$dir/home/state/$id.meta" ] || fail "meta deleted despite land refuse"
  pass "ship husk --force still requires positive land proof"
}

test_husk_live_server_refuses_even_with_land() {
  local dir id=husk-live sock pid
  [ -n "$REAL_TMUX" ] || { skip "tmux not installed"; return 0; }
  dir=$(make_husk_case live-server)
  write_husk_meta "$dir" "$id"
  sock="$dir/live.sock"
  # Use REAL pgrep/lsof/tmux so the live fixture is visible (not empty fakes).
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$sock" new-session -d -s husklive -n "fm-$id"
  pid=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$sock" display-message -p '#{pid}')
  set +e
  env -u TMUX -u TMUX_PANE \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH" \
    "$TEARDOWN" "$id" --force >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$sock" kill-server 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "husk allowed while live tmux server present"
  grep -q 'live tmux server' "$dir/err" \
    || fail "expected live-server refusal: $(cat "$dir/err")"
  [ -f "$dir/home/state/$id.meta" ] || fail "meta deleted while live server"
  pass "husk refuses while any live tmux server answers"
}

test_husk_x6_renamed_binary_refuses() {
  local dir id=husk-x6 sock pid bin
  [ -n "$REAL_TMUX" ] || { skip "tmux not installed"; return 0; }
  dir=$(make_husk_case x6-renamed)
  write_husk_meta "$dir" "$id"
  bin="$dir/notmux"
  cp "$REAL_TMUX" "$bin"
  chmod +x "$bin"
  sock="$dir/x6.sock"
  env -u TMUX -u TMUX_PANE "$bin" -S "$sock" new-session -d -s huskx6 -n "fm-$id"
  pid=$(env -u TMUX -u TMUX_PANE "$bin" -S "$sock" display-message -p '#{pid}')
  # Confirm pgrep -x tmux misses (the v6 hole).
  if pgrep -x tmux -u "$UID_N" 2>/dev/null | grep -qx "$pid"; then
    env -u TMUX -u TMUX_PANE "$bin" -S "$sock" kill-server 2>/dev/null || true
    skip "renamed-binary still visible to pgrep -x tmux on this host"
    return 0
  fi
  set +e
  # Empty pgrep fake would hide secondary; use real tools so protocol must catch.
  env -u TMUX -u TMUX_PANE \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH" \
    "$TEARDOWN" "$id" --force >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  env -u TMUX -u TMUX_PANE "$bin" -S "$sock" kill-server 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "X6 renamed-binary husk allowed with live worker"
  grep -q 'live tmux server' "$dir/err" \
    || fail "X6 expected live-server refusal: $(cat "$dir/err")"
  [ -f "$dir/home/state/$id.meta" ] || fail "X6 meta deleted"
  pass "X6 renamed-binary live worker: husk refuses (protocol, not process name)"
}

test_husk_scout_requires_report_under_force() {
  local dir id=husk-scout
  dir=$(make_husk_case scout-force)
  write_husk_meta "$dir" "$id" "kind=scout"
  # rewrite kind (write_husk_meta defaults ship)
  printf 'endpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=scout\nbackend=tmux\n' \
    "$id" "$dir/worktree" "$dir/project" > "$dir/home/state/$id.meta"
  set +e
  run_husk "$dir" "$id" --force >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "scout husk force skipped report gate"
  grep -qi 'report' "$dir/err" || fail "expected report refusal: $(cat "$dir/err")"
  [ -f "$dir/home/state/$id.meta" ] || fail "scout meta deleted"
  pass "scout husk --force still requires report"
}

test_endpoint_bearing_force_unchanged() {
  local dir id=endpoint-force
  dir=$(make_husk_case endpoint-force)
  # Valid-looking endpoint with force should still reach later gates (not husk).
  printf 'window=isolated:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nbackend=tmux\n' \
    "$id" "$id" "$dir/worktree" "$dir/project" > "$dir/home/state/$id.meta"
  # Unlanded commit; --force should skip land for endpoint-bearing (existing semantics).
  printf 'x\n' > "$dir/worktree/x"
  git -C "$dir/worktree" add x
  git -C "$dir/worktree" -c user.email=t@t -c user.name=t commit -q -m x
  set +e
  # Need fake tmux kill for completion; use empty enum fakes + fake tmux
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    PATH="$dir/fakebin:/opt/homebrew/bin:/usr/bin:/bin:$PATH" \
    "$TEARDOWN" "$id" --force >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "endpoint-bearing --force should still skip land: $(cat "$dir/err")"
  [ ! -f "$dir/home/state/$id.meta" ] || fail "endpoint meta not removed under force"
  pass "endpoint-bearing --force land skip unchanged"
}

test_legacy_missing_endpoint_still_refuses
test_husk_with_empty_enum_and_land_allows
test_husk_force_does_not_skip_land
test_husk_live_server_refuses_even_with_land
test_husk_x6_renamed_binary_refuses
test_husk_scout_requires_report_under_force
test_endpoint_bearing_force_unchanged

echo "fm-teardown-husk: all tests passed"
