#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin/main tip or stops when origin is
# unreachable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-base-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn left the pooled worktree on stale history"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  id='pool-current-base-repeat-r1'
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  # A pool slot is only handed out again once its previous task is gone; spawn
  # now refuses a slot another live record still claims (upstream #3075), so the
  # repeat models a returned slot rather than two live tasks in one directory.
  rm -f "$HOME_DIR/state/pool-current-base-r1.meta"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the pool away from current origin/main"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "a branch created after spawn differs from current origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "the branch created after spawn omitted advanced-main content"
  pass "a stale pooled worktree refreshes to current origin/main before a crew branch is created"
}

test_non_main_default_branch_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree on a non-main default branch"
  current=$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to current origin/$DEFAULT_BRANCH"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced past the pool base"
  pass "a stale pooled worktree resolves and refreshes a non-main default branch"
}

test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin refuses a potentially stale pooled worktree"
}

test_direct_pr_and_scout_refresh_before_launch() {
  local rec id out status contract current
  for contract in direct-pr scout; do
    id="pool-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a stale pooled worktree"
    current=$(git -C "$POOL_DIR" rev-parse origin/main)
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
      "$contract spawn omitted advanced-main content"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "direct-PR ships and scouts both refresh stale pooled worktrees before launch"
}

test_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-dirty-refusal-r4'
  rec=$(make_case dirty-refusal "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the pool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed dirty refusal: %s; preserved=%s\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$(cat "$POOL_DIR/uncommitted.txt")"
  fi
  pass "a dirty pooled worktree is refused without discarding its local work"
}

test_unresolved_remote_default_refuses_pool() {
  local rec id out status before
  id='pool-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remote default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolved-default refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unresolved remote default branch refuses the pooled worktree"
}

# Replace this case's `treehouse` stub with one that models what the real binary
# does to a returned slot: v2.3.0's `return` terminates the processes running in
# it, and `--force` cleans and resets it without prompting. A stub that just
# exits 0 makes every "the claimed copy survived" assertion vacuously true, which
# is exactly how the round-2 panel found this test proving the opposite of the
# production behaviour. Args: fakebin case_dir base_sha
install_destructive_treehouse_fake() {
  local fakebin=$1 case_dir=$2 base=$3
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
[ "\${1:-}" = return ] || exit 0
slot=""
for a in "\$@"; do
  case "\$a" in /*) slot=\$a ;; esac
done
printf '%s\n' "return \$*" >> '$case_dir/treehouse-return.log'
[ -n "\$slot" ] || exit 0
# Terminate the processes running in the slot, then clean and reset it.
while read -r pid; do
  [ -n "\$pid" ] || continue
  kill -KILL "\$pid" 2>/dev/null || true
done < <(cat '$case_dir/slot-pids' 2>/dev/null || true)
git -C "\$slot" reset --hard '$base' >/dev/null 2>&1 || true
git -C "\$slot" clean -fdx >/dev/null 2>&1 || true
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

# Upstream #3075, allocation half. A pool slot whose earlier task was never
# returned can be handed back out while that task's record still names it. The
# base refresh below reaches `git reset --hard`, which discards that task's
# unpushed commits before this task's own record exists for any teardown-side
# check to see. The refusal must therefore touch NOTHING: returning the slot -
# with or without --force - resets it and kills its processes, which is the same
# destruction, moved onto the refusal path.
test_pool_slot_another_task_records_refuses_without_touching_it() {
  local rec id out status stale_head sleeper_pid
  id='pool-claimed-slot-r6'
  rec=$(make_case claimed-slot "$id")
  read_case_record "$rec"
  install_destructive_treehouse_fake "$FAKEBIN_DIR" "$CASE_DIR" "$INITIAL_SHA"

  # An earlier task still records this slot and is genuinely working in it:
  # a committed-but-unpushed change, an uncommitted change, and a live process.
  printf 'unpushed work that must survive\n' > "$POOL_DIR/stale-task-work.txt"
  git -C "$POOL_DIR" add stale-task-work.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'stale task work'
  stale_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'uncommitted work that must survive\n' > "$POOL_DIR/stale-task-dirty.txt"
  ( cd "$POOL_DIR" && exec sleep 300 ) &
  sleeper_pid=$!
  disown
  printf '%s\n' "$sleeper_pid" > "$CASE_DIR/slot-pids"
  sleep 0.3
  kill -0 "$sleeper_pid" 2>/dev/null || fail "claimed-slot: setup sleeper did not start"
  printf '%s\n' 'window=firstmate:fm-stale-task' 'endpoint_task_id=stale-task' \
    "worktree=$POOL_DIR" "project=$PROJECT_DIR" 'kind=ship' 'mode=local-only' \
    > "$HOME_DIR/state/stale-task.meta"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  if kill -0 "$sleeper_pid" 2>/dev/null; then
    kill -KILL "$sleeper_pid" 2>/dev/null || true
  else
    fail "the refusal killed the claiming task's process"
  fi
  [ "$status" -ne 0 ] || fail "spawn took a pool slot another task's record still claims"
  assert_contains "$out" "already record that worktree" \
    "spawn did not clearly refuse an already-claimed pool slot"
  assert_contains "$out" "stale-task" "the refusal did not name the claiming task"
  assert_contains "$out" "Nothing was changed" \
    "the refusal did not state that the claimed slot was left alone"
  [ ! -e "$CASE_DIR/treehouse-return.log" ] \
    || fail "the refusal returned the claimed slot: $(cat "$CASE_DIR/treehouse-return.log")"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$stale_head" ] \
    || fail "spawn moved the claimed slot's HEAD despite refusing"
  [ -f "$POOL_DIR/stale-task-work.txt" ] \
    || fail "spawn discarded the claiming task's committed-but-unpushed work"
  [ -f "$POOL_DIR/stale-task-dirty.txt" ] \
    || fail "spawn discarded the claiming task's uncommitted work"
  [ ! -f "$HOME_DIR/state/$id.meta" ] \
    || fail "spawn published a record for a task it refused to start"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed claimed-slot refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "a pool slot another task's record claims is refused without returning, resetting, or reaping it"
}

# bin/fm-status-gc.sh refuses to retire a status log while /tmp/fm-<id> exists,
# and treats that as the earliest durable trace that a spawn ran for the id. That
# is only true if the temp root is created before the endpoint: every backend
# creates its window or task before the worktree settles and long before the meta
# is published, so a spawn that dies in between would otherwise leave a live
# endpoint that no gate can see. Proven from observed state at endpoint-creation
# time, not from source order.
test_task_temp_root_exists_before_the_endpoint() {
  local rec id out status
  id="pool-temp-order-r8-$$"
  rec=$(make_case temp-order "$id")
  read_case_record "$rec"
  rm -rf "/tmp/fm-$id"

  # Snapshot whether the temp root already exists at the moment the backend is
  # asked to create this task's window.
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  new-window)
    if [ -d "/tmp/fm-$id" ]; then
      printf 'present\n' >> '$CASE_DIR/temp-at-endpoint'
    else
      printf 'absent\n' >> '$CASE_DIR/temp-at-endpoint'
    fi
    exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/tmux"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  rm -rf "/tmp/fm-$id"
  expect_code 0 "$status" "temp-order: spawn should succeed: $out"
  assert_present "$CASE_DIR/temp-at-endpoint" \
    "temp-order: the backend was never asked to create a window"
  if grep -qx absent "$CASE_DIR/temp-at-endpoint"; then
    fail "temp-order: the endpoint was created before /tmp/fm-<id> existed"
  fi
  pass "the per-task temp root exists before any endpoint is created"
}

# The guard above is only meaningful if the fixture's treehouse fake would in
# fact destroy the slot when invoked. Prove that directly, so a future stub that
# silently stops modelling the real binary cannot make the case vacuous again.
test_destructive_treehouse_fake_actually_destroys() {
  local rec id sleeper_pid
  id='pool-fake-fidelity-r7'
  rec=$(make_case fake-fidelity "$id")
  read_case_record "$rec"
  install_destructive_treehouse_fake "$FAKEBIN_DIR" "$CASE_DIR" "$INITIAL_SHA"

  printf 'work\n' > "$POOL_DIR/doomed.txt"
  git -C "$POOL_DIR" add doomed.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'doomed work'
  printf 'dirty\n' > "$POOL_DIR/doomed-dirty.txt"
  ( cd "$POOL_DIR" && exec sleep 300 ) &
  sleeper_pid=$!
  disown
  printf '%s\n' "$sleeper_pid" > "$CASE_DIR/slot-pids"
  sleep 0.3

  PATH="$FAKEBIN_DIR:$PATH" treehouse return --force "$POOL_DIR" >/dev/null 2>&1 || true
  sleep 0.3
  [ -e "$CASE_DIR/treehouse-return.log" ] || fail "fake-fidelity: the fake did not record the return"
  kill -0 "$sleeper_pid" 2>/dev/null && { kill -KILL "$sleeper_pid" 2>/dev/null || true; fail "fake-fidelity: the fake left the slot process alive"; }
  [ ! -f "$POOL_DIR/doomed.txt" ] || fail "fake-fidelity: the fake left the committed work in the slot"
  [ ! -f "$POOL_DIR/doomed-dirty.txt" ] || fail "fake-fidelity: the fake left the uncommitted work in the slot"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$INITIAL_SHA" ] \
    || fail "fake-fidelity: the fake did not reset the slot to its base"
  pass "the fixture's treehouse return fake really does reset the slot and kill its processes"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_pool_slot_another_task_records_refuses_without_touching_it
test_task_temp_root_exists_before_the_endpoint
test_destructive_treehouse_fake_actually_destroys

echo "# all fm-spawn-pool-base-freshen tests passed"
