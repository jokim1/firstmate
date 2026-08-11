#!/usr/bin/env bash
# tests/fm-treehouse-pool-isolation.test.sh - cross-home treehouse pool binding
# guards (fm-treehouse-pool-root-audit): treehouse keys a pool by origin URL
# under one shared root, so two homes' clones of one remote would share a pool,
# and each slot stays bound (git worktree add) to whichever clone created it.
# This suite covers the three shipped guards:
#   1. fm-home-seed.sh pins a home-scoped pool root (repo-level treehouse.toml)
#      into every secondmate project clone.
#   2. fm-spawn.sh fail-closed refuses an acquired pool slot whose git common
#      dir is not the spawning home's project clone, returning the slot.
#   3. fm-teardown.sh destroys pool slots bound to a retiring secondmate home
#      before removing the home, and refuses the retirement when treehouse
#      will not destroy one.
# Plus the report's end-to-end regression: with the pin in place, two temp
# clones of one remote acquire slots from different pool roots.
# Every fixture is a temp clone and a temp pool root; no live pool slot or real
# home is ever touched.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-pool-isolation)
export FM_BACKEND=tmux

# Seed the direct-PR project alpha into a secondmate home via the real
# fm-home-seed.sh. Echoes "<main-home>|<secondmate-home>".
make_seeded_home() {  # <name>
  local name=$1 home smhome
  home="$TMP_ROOT/$name-main"
  smhome="$TMP_ROOT/$name-sm"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/$name-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='alpha domain' FM_SECONDMATE_SCOPE='alpha domain' \
    "$ROOT/bin/fm-home-seed.sh" "sm-$name" "$smhome" alpha >/dev/null \
    || fail "seed failed for $name"
  printf '%s|%s\n' "$home" "$smhome"
}

read_pair() {  # <record>  -> sets PAIR_MAIN PAIR_SM
  IFS='|' read -r PAIR_MAIN PAIR_SM <<EOF
$1
EOF
}

test_seed_pins_home_scoped_pool_root() {
  local rec cfg sm_real status
  rec=$(make_seeded_home pin)
  read_pair "$rec"
  # fm-home-seed canonicalizes the home to its physical path before writing.
  sm_real=$(cd "$PAIR_SM" && pwd -P)
  cfg="$PAIR_SM/projects/alpha/treehouse.toml"
  assert_present "$cfg" "seed did not write treehouse.toml into the secondmate project clone"
  assert_grep '# firstmate: seeded by fm-home-seed.sh' "$cfg" "seeded treehouse.toml lacks the firstmate marker"
  assert_grep "root = \"$sm_real/data/treehouse-pools\"" "$cfg" "seeded treehouse.toml does not pin the home-scoped pool root"
  assert_absent "$PAIR_MAIN/projects/alpha/treehouse.toml" "seed wrote treehouse.toml into the main home clone"
  if git -C "$PAIR_SM/projects/alpha" ls-files --error-unmatch treehouse.toml >/dev/null 2>&1; then
    fail "seeded treehouse.toml is tracked in the clone; crewmates could commit it"
  fi
  status=$(git -C "$PAIR_SM/projects/alpha" status --short)
  [ -z "$status" ] || fail "seeded project clone is dirty: $status"
  pass "seed pins a home-scoped treehouse pool root into the secondmate clone only"
}

test_seed_pins_pool_root_for_preexisting_clone() {
  local name=pre home smhome cfg
  home="$TMP_ROOT/$name-main"
  smhome="$TMP_ROOT/$name-sm"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$smhome/projects" "$smhome/data" "$smhome/state" "$smhome/config"
  mark_firstmate_home "$smhome"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/$name-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "file://$(cd "$TMP_ROOT/remotes/$name-alpha.git" && pwd)" "$smhome/projects/alpha"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='alpha domain' FM_SECONDMATE_SCOPE='alpha domain' \
    "$ROOT/bin/fm-home-seed.sh" "sm-$name" "$smhome" alpha >/dev/null \
    || fail "seed failed for a preexisting project clone"
  cfg="$smhome/projects/alpha/treehouse.toml"
  assert_present "$cfg" "seed did not pin a pool root for a preexisting clone"
  assert_grep "root = \"$(cd "$smhome" && pwd -P)/data/treehouse-pools\"" "$cfg" "preexisting clone got the wrong pool root"
  pass "seed pins the pool root for a preexisting project clone too"
}

test_seed_refuses_project_that_tracks_treehouse_toml() {
  local name=tracked home smhome err rc
  home="$TMP_ROOT/$name-main"
  smhome="$TMP_ROOT/$name-sm"
  err="$TMP_ROOT/$name.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  printf 'max_trees = 4\n' > "$home/projects/alpha/treehouse.toml"
  git -C "$home/projects/alpha" add treehouse.toml
  git -C "$home/projects/alpha" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'add treehouse.toml'
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/$name-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  set +e
  FM_HOME="$home" FM_SECONDMATE_CHARTER='alpha domain' FM_SECONDMATE_SCOPE='alpha domain' \
    "$ROOT/bin/fm-home-seed.sh" "sm-$name" "$smhome" alpha >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "seed succeeded for a project that tracks treehouse.toml"
  grep -F 'tracks treehouse.toml' "$err" >/dev/null || fail "seed refusal did not explain the tracked treehouse.toml"
  pass "seed refuses to override a project's own tracked treehouse.toml"
}

test_seed_refuses_foreign_untracked_treehouse_toml() {
  local name=foreigncfg home smhome err rc
  home="$TMP_ROOT/$name-main"
  smhome="$TMP_ROOT/$name-sm"
  err="$TMP_ROOT/$name.err"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$smhome/projects" "$smhome/data" "$smhome/state" "$smhome/config"
  mark_firstmate_home "$smhome"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/$name-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "file://$(cd "$TMP_ROOT/remotes/$name-alpha.git" && pwd)" "$smhome/projects/alpha"
  printf 'root = "/somewhere/else"\n' > "$smhome/projects/alpha/treehouse.toml"
  set +e
  FM_HOME="$home" FM_SECONDMATE_CHARTER='alpha domain' FM_SECONDMATE_SCOPE='alpha domain' \
    "$ROOT/bin/fm-home-seed.sh" "sm-$name" "$smhome" alpha >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "seed overwrote an operator's untracked treehouse.toml"
  grep -F 'without the firstmate seed marker' "$err" >/dev/null || fail "seed refusal did not explain the foreign treehouse.toml"
  assert_grep 'root = "/somewhere/else"' "$smhome/projects/alpha/treehouse.toml" "seed rewrote the operator's treehouse.toml"
  pass "seed refuses to overwrite an untracked treehouse.toml it did not write"
}

test_seed_rolls_back_preexisting_project_configs() {
  local name=rollback home smhome project err rc initial_exclude
  home="$TMP_ROOT/$name-main"
  smhome="$TMP_ROOT/$name-sm"
  err="$TMP_ROOT/$name.err"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$smhome/projects" "$smhome/data" "$smhome/state" "$smhome/config"
  mark_firstmate_home "$smhome"
  for project in alpha gamma beta; do
    fm_git_init_commit "$home/projects/$project"
    fm_git_add_origin "$home/projects/$project" "$TMP_ROOT/remotes/$name-$project.git"
    git clone --quiet "file://$(cd "$TMP_ROOT/remotes/$name-$project.git" && pwd)" "$smhome/projects/$project"
    printf -- '- %s [direct-PR] - %s project (added 2026-06-22)\n' "$project" "$project" >> "$home/data/projects.md"
  done
  cat > "$smhome/projects/alpha/treehouse.toml" <<'EOF'
# firstmate: seeded by fm-home-seed.sh - previous value
root = "/previous/root"
EOF
  printf '# fixture exclude without newline' > "$smhome/projects/alpha/.git/info/exclude"
  cp "$smhome/projects/alpha/.git/info/exclude" "$TMP_ROOT/$name-alpha-exclude"
  initial_exclude=$(cat "$smhome/projects/gamma/.git/info/exclude")
  printf 'root = "/operator/root"\n' > "$smhome/projects/beta/treehouse.toml"
  set +e
  FM_HOME="$home" FM_SECONDMATE_CHARTER='rollback domain' FM_SECONDMATE_SCOPE='rollback domain' \
    "$ROOT/bin/fm-home-seed.sh" "sm-$name" "$smhome" alpha gamma beta >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "seed succeeded despite a later foreign treehouse.toml"
  assert_grep 'root = "/previous/root"' "$smhome/projects/alpha/treehouse.toml" "rollback did not restore the prior seed-owned config"
  cmp -s "$TMP_ROOT/$name-alpha-exclude" "$smhome/projects/alpha/.git/info/exclude" \
    || fail "rollback did not restore the prior alpha info/exclude"
  assert_absent "$smhome/projects/gamma/treehouse.toml" "rollback preserved a newly created config in a preexisting clone"
  [ "$(cat "$smhome/projects/gamma/.git/info/exclude")" = "$initial_exclude" ] \
    || fail "rollback did not restore gamma info/exclude"
  pass "seed rollback restores configs and exclusions in preexisting clones"
}

test_seed_escapes_pool_root_for_toml() {
  # Secondmate ids are a closed character set on current main, so put the
  # quotes and backslashes only in the home path under test (the TOML target),
  # not in the registry id.
  local home smhome cfg sm_real escaped
  home="$TMP_ROOT/escape-main"
  smhome="$TMP_ROOT/escape\"slash\\home-sm"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/escape-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='alpha domain' FM_SECONDMATE_SCOPE='alpha domain' \
    "$ROOT/bin/fm-home-seed.sh" sm-escape-home "$smhome" alpha >/dev/null \
    || fail "seed failed for a home path containing quotes and backslashes"
  sm_real=$(cd "$smhome" && pwd -P)
  cfg="$smhome/projects/alpha/treehouse.toml"
  escaped=${sm_real//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  assert_grep "root = \"$escaped/data/treehouse-pools\"" "$cfg" "seed did not TOML-escape the home-scoped pool root"
  pass "seed TOML-escapes quotes and backslashes in the pool root"
}

# With the seeded pin, two clones of one remote must acquire slots from
# different pool roots (the audit's end-to-end regression). Uses the real
# treehouse binary against temp clones with HOME redirected to a temp dir, so
# the captain's real ~/.treehouse is never touched.
test_seeded_clones_do_not_share_pool_dirs() {
  if ! command -v treehouse >/dev/null 2>&1; then
    pass "treehouse not installed; skipped real-pool isolation check"
    return
  fi
  local rec fakeuser wt_main wt_sm pool_main pool_sm common_main common_sm sm_real
  rec=$(make_seeded_home pool)
  read_pair "$rec"
  sm_real=$(cd "$PAIR_SM" && pwd -P)
  fakeuser="$TMP_ROOT/pool-fakeuser"
  mkdir -p "$fakeuser"
  wt_main=$(cd "$PAIR_MAIN/projects/alpha" && HOME="$fakeuser" treehouse get --lease 2>/dev/null) \
    || fail "treehouse get --lease failed from the main clone"
  wt_sm=$(cd "$PAIR_SM/projects/alpha" && HOME="$fakeuser" treehouse get --lease 2>/dev/null) \
    || fail "treehouse get --lease failed from the secondmate clone"
  # treehouse cleans paths lexically while the fixture TMPDIR may carry a
  # trailing slash or symlink, so compare canonicalized paths throughout.
  wt_main=$(cd "$wt_main" && pwd -P)
  wt_sm=$(cd "$wt_sm" && pwd -P)
  fakeuser=$(cd "$fakeuser" && pwd -P)
  case "$wt_main" in
    "$fakeuser"/.treehouse/*) : ;;
    *) fail "main clone slot $wt_main did not land under the default pool root" ;;
  esac
  case "$wt_sm" in
    "$sm_real"/data/treehouse-pools/.treehouse/*) : ;;
    *) fail "secondmate clone slot $wt_sm did not land under the home-scoped pool root" ;;
  esac
  pool_main=$(dirname "$(dirname "$wt_main")")
  pool_sm=$(dirname "$(dirname "$wt_sm")")
  [ "$pool_main" != "$pool_sm" ] || fail "two homes' clones of one remote still share pool dir $pool_main"
  # Same origin URL must still produce the same pool NAME; only the root moved.
  [ "$(basename "$pool_main")" = "$(basename "$pool_sm")" ] \
    || fail "expected identical origin-keyed pool names, got $(basename "$pool_main") vs $(basename "$pool_sm")"
  common_main=$(git -C "$wt_main" rev-parse --path-format=absolute --git-common-dir)
  common_sm=$(git -C "$wt_sm" rev-parse --path-format=absolute --git-common-dir)
  [ "$(cd "$common_main" && pwd -P)" = "$(cd "$PAIR_MAIN/projects/alpha/.git" && pwd -P)" ] \
    || fail "main slot is not bound to the main clone"
  [ "$(cd "$common_sm" && pwd -P)" = "$(cd "$PAIR_SM/projects/alpha/.git" && pwd -P)" ] \
    || fail "secondmate slot is not bound to the secondmate clone"
  (cd "$PAIR_MAIN/projects/alpha" && HOME="$fakeuser" treehouse return --force "$wt_main" >/dev/null 2>&1) || true
  (cd "$PAIR_SM/projects/alpha" && HOME="$fakeuser" treehouse return --force "$wt_sm" >/dev/null 2>&1) || true
  pass "two clones of one remote acquire same-named pools under different roots"
}

# --- fm-spawn common-dir assert ----------------------------------------------

# Fake tmux (pane_current_path settles immediately on the fixture worktree) and
# a call-logging exit-0 treehouse. Echoes the fakebin dir.
make_spawn_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# Build a spawn fixture whose settled pane path is a real worktree. With
# binding=same the worktree belongs to the spawned project clone; with
# binding=foreign it belongs to a second clone of the same origin (the exact
# cross-home hazard). Echoes a pipe record.
make_spawn_case() {  # <name> <id> <binding>
  local name=$1 id=$2 binding=$3 case_dir home proj wt remote foreign fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$case_dir/remote.git"
  remote=$(cd "$case_dir/remote.git" && pwd)
  if [ "$binding" = foreign ]; then
    foreign="$case_dir/foreign-clone"
    git clone --quiet "file://$remote" "$foreign"
    git -C "$foreign" worktree add --quiet --detach "$wt"
  else
    git -C "$proj" worktree add --quiet --detach "$wt"
  fi
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_pool_spawn() {  # <record> <id>
  local home proj wt fakebin
  IFS='|' read -r _ home proj wt fakebin <<EOF
$1
EOF
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_TREEHOUSE_LOG="$home/treehouse.log" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$2" "$proj" --mode local-only --yolo off 2>&1
}

test_spawn_accepts_slot_bound_to_own_clone() {
  local id=pool-spawn-same rec out status home wt
  rec=$(make_spawn_case spawn-same "$id" same)
  IFS='|' read -r _ home _ wt _ <<EOF
$rec
EOF
  set +e
  out=$(run_pool_spawn "$rec" "$id")
  status=$?
  set -e
  expect_code 0 "$status" "spawn should accept a slot bound to the spawning clone"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$wt" "$home/state/$id.meta" "meta did not record the accepted worktree"
  pass "spawn accepts a pool slot bound to the spawning home's own clone"
}

test_spawn_refuses_slot_bound_to_foreign_clone() {
  local id=pool-spawn-foreign rec out status home wt
  rec=$(make_spawn_case spawn-foreign "$id" foreign)
  IFS='|' read -r _ home _ wt _ <<EOF
$rec
EOF
  set +e
  out=$(run_pool_spawn "$rec" "$id")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "spawn accepted a pool slot bound to a foreign clone"
  assert_contains "$out" "bound to a different clone" "spawn refusal did not explain the foreign binding"
  assert_grep "treehouse return --force $wt" "$home/treehouse.log" "spawn did not return the foreign-bound slot to the pool"
  if [ -e "$home/state/$id.meta" ]; then
    assert_no_grep "worktree=$wt" "$home/state/$id.meta" "refused spawn still recorded the foreign worktree"
  fi
  pass "spawn fail-closed refuses a pool slot bound to another clone and returns it"
}

# --- secondmate retirement pool-slot destruction ------------------------------

# Fake tmux plus a destroy-aware fake treehouse that logs every call, removes
# the destroyed target, and fails when FM_FAKE_TREEHOUSE_DESTROY_FAIL is set.
make_teardown_fakebin() {  # <dir>
  local dir=$1 fakebin capture
  fakebin=$(fm_fakebin "$dir")
  capture="$dir/pane.txt"
  printf 'idle prompt\n' > "$capture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
  list-windows) exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane) cat "$FM_FAKE_TMUX_CAPTURE"; exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
case "${1:-}" in
  destroy)
    shift
    [ -z "${FM_FAKE_TREEHOUSE_DESTROY_FAIL:-}" ] || exit 1
    target=
    for a in "$@"; do
      case "$a" in -*) ;; *) target=$a ;; esac
    done
    [ -n "$target" ] && rm -rf -- "$target"
    exit 0
    ;;
  return)
    [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# A plain-clone secondmate home with a project clone, plus a temp pool holding
# one slot bound to that clone and one slot bound to the main home's clone of
# the same origin. Echoes a pipe record.
make_teardown_case() {  # <name>
  local name=$1 home subhome poolroot mainclone remote slot_bound slot_foreign fakebin
  home="$TMP_ROOT/$name-home"
  subhome="$TMP_ROOT/$name-subhome"
  poolroot="$TMP_ROOT/$name-pools"
  mainclone="$home/projects/alpha"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$subhome/state" "$subhome/projects"
  mark_firstmate_home "$subhome"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_init_commit "$mainclone"
  fm_git_add_origin "$mainclone" "$TMP_ROOT/remotes/td-$name.git"
  remote=$(cd "$TMP_ROOT/remotes/td-$name.git" && pwd)
  git clone --quiet "file://$remote" "$subhome/projects/alpha"
  slot_bound="$poolroot/alpha-deadbeef/1/alpha"
  slot_foreign="$poolroot/alpha-deadbeef/2/alpha"
  mkdir -p "$(dirname "$slot_bound")" "$(dirname "$slot_foreign")"
  git -C "$subhome/projects/alpha" worktree add --quiet --detach "$slot_bound"
  git -C "$mainclone" worktree add --quiet --detach "$slot_foreign"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_teardown_fakebin "$TMP_ROOT/$name-fake")
  printf '%s\n' "$home|$subhome|$poolroot|$slot_bound|$slot_foreign|$fakebin"
}

run_pool_teardown() {  # <record> [extra-env...] -- runs fm-teardown domain
  local home subhome poolroot slot_bound slot_foreign fakebin
  IFS='|' read -r home subhome poolroot slot_bound slot_foreign fakebin <<EOF
$1
EOF
  shift
  env PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_TEARDOWN_POOL_SCAN_ROOTS="$poolroot" \
    FM_FAKE_TMUX_CAPTURE="$(dirname "$fakebin")/pane.txt" \
    FM_FAKE_TREEHOUSE_LOG="$home/treehouse.log" \
    "$@" \
    "$ROOT/bin/fm-teardown.sh" domain 2>&1
}

test_retirement_destroys_home_bound_pool_slots() {
  local rec home subhome slot_bound slot_foreign out status
  rec=$(make_teardown_case retire)
  IFS='|' read -r home subhome _ slot_bound slot_foreign _ <<EOF
$rec
EOF
  out=$(run_pool_teardown "$rec")
  status=$?
  expect_code 0 "$status" "retirement failed with disposable home-bound slots: $out"
  assert_grep "treehouse destroy $slot_bound --yes" "$home/treehouse.log" "retirement did not destroy the home-bound pool slot"
  assert_no_grep "destroy $slot_foreign" "$home/treehouse.log" "retirement destroyed a slot bound to another home"
  assert_absent "$slot_bound" "home-bound pool slot survived retirement"
  assert_present "$slot_foreign" "foreign-bound pool slot was removed"
  assert_absent "$subhome" "retirement did not remove the secondmate home"
  pass "secondmate retirement destroys exactly the pool slots bound to its own clones"
}

test_retirement_refuses_when_slot_not_disposable() {
  local rec home subhome slot_bound slot_foreign out status
  rec=$(make_teardown_case refuse)
  IFS='|' read -r home subhome _ slot_bound slot_foreign _ <<EOF
$rec
EOF
  set +e
  out=$(run_pool_teardown "$rec" FM_FAKE_TREEHOUSE_DESTROY_FAIL=1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "retirement succeeded although treehouse refused to destroy a bound slot"
  assert_contains "$out" "refused to destroy pool slot" "retirement did not report the refused destroy"
  assert_present "$subhome" "retirement removed the home after a refused slot destroy"
  assert_present "$home/state/domain.meta" "retirement cleared meta after a refused slot destroy"
  assert_present "$slot_foreign" "foreign-bound pool slot was removed"
  pass "secondmate retirement fails closed when a bound slot is not disposable"
}

test_force_retirement_includes_unlanded_but_never_in_use() {
  local rec home subhome poolroot slot_bound slot_foreign fakebin out status
  rec=$(make_teardown_case force)
  IFS='|' read -r home subhome poolroot slot_bound slot_foreign fakebin <<EOF
$rec
EOF
  set +e
  out=$(env PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_TEARDOWN_POOL_SCAN_ROOTS="$poolroot" \
    FM_FAKE_TMUX_CAPTURE="$(dirname "$fakebin")/pane.txt" \
    FM_FAKE_TREEHOUSE_LOG="$home/treehouse.log" \
    "$ROOT/bin/fm-teardown.sh" domain --force 2>&1)
  status=$?
  set -e
  expect_code 0 "$status" "forced retirement failed: $out"
  assert_grep "treehouse destroy $slot_bound --yes --include-unlanded" "$home/treehouse.log" \
    "forced retirement did not pass --include-unlanded for the home's own slots"
  assert_no_grep "--include-in-use" "$home/treehouse.log" "forced retirement passed --include-in-use"
  assert_no_grep "--include-leased" "$home/treehouse.log" "forced retirement passed --include-leased"
  assert_absent "$subhome" "forced retirement did not remove the secondmate home"
  pass "forced retirement discards unlanded home-bound slots but never in-use or leased ones"
}

test_seed_pins_home_scoped_pool_root
test_seed_pins_pool_root_for_preexisting_clone
test_seed_refuses_project_that_tracks_treehouse_toml
test_seed_refuses_foreign_untracked_treehouse_toml
test_seed_rolls_back_preexisting_project_configs
test_seed_escapes_pool_root_for_toml
test_seeded_clones_do_not_share_pool_dirs
test_spawn_accepts_slot_bound_to_own_clone
test_spawn_refuses_slot_bound_to_foreign_clone
test_retirement_destroys_home_bound_pool_slots
test_retirement_refuses_when_slot_not_disposable
test_force_retirement_includes_unlanded_but_never_in_use

echo "# all fm-treehouse-pool-isolation tests passed"
