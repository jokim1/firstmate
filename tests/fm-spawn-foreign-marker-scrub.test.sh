#!/usr/bin/env bash
# Behavioral tests for the foreign primary-harness marker scrub applied at every
# crewmate/secondmate launch boundary (bin/fm-spawn.sh foreign_marker_scrub_prefix).
#
# A launcher identity marker (CLAUDECODE, PI_CODING_AGENT/FM_PI_HARNESS, GROK_AGENT)
# that leaks into a DIFFERENT harness's worker makes bin/fm-harness.sh misdetect
# before ancestry is consulted. These tests drive real fm-spawn launch construction
# under a full foreign marker set and assert:
#   1. the constructed launch env drops every foreign verified marker
#   2. the target harness's own markers are preserved (not scrubbed)
# Coverage walks every verified adapter (claude, codex, opencode, pi, pi-signed,
# grok, kimi, muse) plus a secondmate path - not only the adapters active in one fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS_BIN="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-foreign-marker-scrub)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}
# The claude launch path pre-registers workspace trust (bin/fm-claude-trust.sh),
# which shells out to node; without it on PATH the claude case refuses to launch.
# Include node's own dir (when present) so the scrub assertions can run, matching
# how the trust suite relies on the ambient node.
NODE_BIN=$(command -v node 2>/dev/null || true)
[ -n "$NODE_BIN" ] && BASE_PATH="$BASE_PATH:$(dirname "$NODE_BIN")"

# Full foreign marker set a poisoned launcher environment may carry.
FOREIGN_ENV=(
  CLAUDECODE=1
  PI_CODING_AGENT=true
  FM_PI_HARNESS=pi-signed
  GROK_AGENT=1
)

make_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

# Fake tmux captures every send-keys -l literal (launch command) and can execute
# a captured launch under FM_FAKE_EXECUTE_LAUNCH=1 for env-probe cases.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*) printf '3\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  show-environment)
    [ "${FM_FAKE_WORKER_META_KEY:-}" = present ] || exit 1
    printf 'META_API_KEY=worker-key\n'
    exit 0
    ;;
  send-keys)
    prev=
    literal=
    for a in "$@"; do
      if [ "$prev" = "-l" ]; then
        literal=$a
        break
      fi
      prev=$a
    done
    if [ -n "$literal" ] && [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
      if [ "${FM_FAKE_EXECUTE_LAUNCH:-}" = 1 ]; then
        (cd "${FM_FAKE_PANE_PATH:-.}" && bash -c "$literal") || true
      fi
      # Kimi readiness progression for the bare launch-then-pointer path.
      case "$literal" in
        *' --auto'*)
          printf 'ready\n' > "${FM_FAKE_KIMI_STATE:-/dev/null}" 2>/dev/null || true
          ;;
        'Read the brief at '*)
          printf 'delivered\n' > "${FM_FAKE_KIMI_STATE:-/dev/null}" 2>/dev/null || true
          ;;
      esac
    fi
    case " $* " in
      *' Enter '*)
        if [ -f "${FM_FAKE_KIMI_STATE:-}" ]; then
          state=$(cat "$FM_FAKE_KIMI_STATE" 2>/dev/null || true)
          case "$state" in
            ''|launched) printf 'ready\n' > "$FM_FAKE_KIMI_STATE" ;;
            ready) : ;;
            pointer-typed) printf 'delivered\n' > "$FM_FAKE_KIMI_STATE" ;;
          esac
        fi
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    # Minimal ready/delivered screens for kimi's readiness gate.
    state=$(cat "${FM_FAKE_KIMI_STATE:-/dev/null}" 2>/dev/null || true)
    case "$state" in
      delivered)
        printf '✨ brief delivered\ncontext: 1%%\n╭────╮\n│ >  │\n╰────╯\n'
        ;;
      *)
        printf 'Welcome to Kimi Code!\ncontext: 0%%\n╭────╮\n│ >  │\n╰────╯\n'
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh claude codex opencode grok
  make_pi_probe "$fakebin" pi
  make_pi_probe "$fakebin" pi-signed
  # Kimi: absolute-path resolution prefers PATH entry.
  fm_fake_exit0 "$fakebin" kimi
  # Muse: versioned launcher + probe-capable shim.
  cp "$(command -v bash)" "$fakebin/muse-bin-test-version"
  cat > "$fakebin/muse" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_HARNESS_RESULT:-}" ]; then
  exec "$FM_FAKE_MUSE_VERSIONED" -c \
    'result=$($FM_FAKE_HARNESS_PROBE); printf "%s" "$result" > "$FM_FAKE_HARNESS_RESULT"'
fi
exit 0
SH
  chmod +x "$fakebin/muse"
  # Markerless codex probe binary for execute-style env checks.
  cat > "$fakebin/codex-probe" <<'SH'
#!/usr/bin/env bash
set -u
# Dump whether each verified marker is present after the launch env scrub.
{
  printf 'CLAUDECODE=%s\n' "${CLAUDECODE-__unset__}"
  printf 'PI_CODING_AGENT=%s\n' "${PI_CODING_AGENT-__unset__}"
  printf 'FM_PI_HARNESS=%s\n' "${FM_PI_HARNESS-__unset__}"
  printf 'GROK_AGENT=%s\n' "${GROK_AGENT-__unset__}"
  if [ -n "${FM_FAKE_HARNESS_PROBE:-}" ]; then
    printf 'DETECT=%s\n' "$("$FM_FAKE_HARNESS_PROBE")"
  fi
} > "${FM_FAKE_ENV_RESULT:?}"
exit 0
SH
  chmod +x "$fakebin/codex-probe"
  # Claude probe: preserve CLAUDECODE when present (target marker survival).
  cat > "$fakebin/claude-probe" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'CLAUDECODE=%s\n' "${CLAUDECODE-__unset__}"
  printf 'PI_CODING_AGENT=%s\n' "${PI_CODING_AGENT-__unset__}"
  printf 'FM_PI_HARNESS=%s\n' "${FM_PI_HARNESS-__unset__}"
  printf 'GROK_AGENT=%s\n' "${GROK_AGENT-__unset__}"
} > "${FM_FAKE_ENV_RESULT:?}"
exit 0
SH
  chmod +x "$fakebin/claude-probe"
  # Pi probe: confirm FM_PI_HARNESS survives (re-set on the launch line).
  cat > "$fakebin/pi-probe" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'CLAUDECODE=%s\n' "${CLAUDECODE-__unset__}"
  printf 'PI_CODING_AGENT=%s\n' "${PI_CODING_AGENT-__unset__}"
  printf 'FM_PI_HARNESS=%s\n' "${FM_PI_HARNESS-__unset__}"
  printf 'GROK_AGENT=%s\n' "${GROK_AGENT-__unset__}"
} > "${FM_FAKE_ENV_RESULT:?}"
exit 0
SH
  chmod +x "$fakebin/pi-probe"
  ln -sf "$JQ_BIN" "$fakebin/jq" 2>/dev/null || true
  printf '%s\n' "$fakebin"
}

make_ship_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="scrub-$name-z1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/xdgconfig" "$home/xdgdata" "$home/.kimi-code" "$home/grok-home"
  printf '# Kimi test\ndefault_model = "test"\n' > "$home/.kimi-code/config.toml"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
brief for $id

## Firstmate spec
Exercise the foreign-marker scrub under test.

Delivery contract: mode=no-mistakes
EOF
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  : > "$launchlog"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

make_secondmate_case() {
  local name=$1 harness=$2 case_dir home sm launchlog fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/primary"
  sm="$case_dir/secondmate"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="scrub-sm-$name-z1"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" \
    "$sm/bin" "$sm/data" "$sm/state" "$sm/config" "$sm/projects"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' "$harness" > "$home/config/secondmate-harness"
  printf 'claude\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  : > "$launchlog"
  printf '%s\n' "$case_dir|$home|$sm|$fakebin|$launchlog|$id"
}

read_ship() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

read_sm() {
  IFS='|' read -r CASE_DIR HOME_DIR SM_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

# Run a ship spawn under the full foreign marker set; capture launch log.
run_ship_under_foreign() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 id=$6 harness=$7
  shift 7
  : > "$launchlog"
  env "${FOREIGN_ENV[@]}" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_FAKE_EXECUTE_LAUNCH="${FM_FAKE_EXECUTE_LAUNCH:-}" \
    FM_FAKE_ENV_RESULT="${FM_FAKE_ENV_RESULT:-}" \
    FM_FAKE_HARNESS_PROBE="${FM_FAKE_HARNESS_PROBE:-}" \
    FM_FAKE_HARNESS_RESULT="${FM_FAKE_HARNESS_RESULT:-}" \
    FM_FAKE_MUSE_VERSIONED="${FM_FAKE_MUSE_VERSIONED:-$fakebin/muse-bin-test-version}" \
    FM_FAKE_WORKER_META_KEY="${FM_FAKE_WORKER_META_KEY:-present}" \
    META_API_KEY="${META_API_KEY:-test-key}" \
    XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$home/xdgconfig}" \
    XDG_DATA_HOME="${XDG_DATA_HOME:-$home/xdgdata}" \
    GROK_HOME="$home/grok-home" \
    HOME="$home" \
    FM_FAKE_KIMI_STATE="$(dirname "$launchlog")/kimi.state" \
    FM_KIMI_READY_POLLS=2 FM_KIMI_DELIVERY_POLLS=2 FM_KIMI_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness "$harness" --mode no-mistakes --yolo off "$@" 2>&1
}

run_secondmate_under_foreign() {
  local home=$1 sm=$2 fakebin=$3 launchlog=$4 id=$5
  : > "$launchlog"
  env "${FOREIGN_ENV[@]}" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$sm" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_SKIP_SECONDMATE_INHERIT=1 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$sm" --secondmate 2>&1
}

# Extract the agent launch command from the log. Prefer the line carrying the
# foreign-marker scrub prefix; fall back to the last non-export, non-brief-
# pointer line (kimi delivers a separate "Read the brief..." pointer after launch).
final_launch() {
  local log=$1 line
  line=$(grep -E '^env -u ' "$log" | tail -1 || true)
  if [ -n "$line" ]; then
    printf '%s\n' "$line"
    return 0
  fi
  awk '
    $0 ~ /^export / { next }
    $0 ~ /^Read the brief at / { next }
    NF { line=$0 }
    END { print line }
  ' "$log"
}

assert_unsets() {
  local launch=$1
  shift
  local var
  for var in "$@"; do
    assert_contains "$launch" " -u $var" \
      "launch did not scrub foreign marker $var: $launch"
  done
}

assert_does_not_unset() {
  local launch=$1
  shift
  local var
  for var in "$@"; do
    assert_not_contains "$launch" " -u $var" \
      "launch scrubbed the target harness's own marker $var: $launch"
  done
}

# --- per-harness launch-shape coverage --------------------------------------

test_markerless_harnesses_scrub_all_verified_markers() {
  local harness rec out status launch
  for harness in codex opencode kimi muse; do
    rec=$(make_ship_case "markerless-$harness" "$harness")
    read_ship "$rec"
    # kimi state file for readiness gate
    : > "$CASE_DIR/kimi.state"
    out=$(run_ship_under_foreign \
      "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$CASE_ID" "$harness")
    status=$?
    expect_code 0 "$status" "$harness spawn under foreign markers should succeed: $out"
    launch=$(final_launch "$LAUNCH_LOG")
    [ -n "$launch" ] || fail "$harness produced no launch command"
    assert_contains "$launch" "env -u " "$harness launch missing env scrub prefix: $launch"
    assert_unsets "$launch" CLAUDECODE PI_CODING_AGENT GROK_AGENT FM_PI_HARNESS
  done
  pass "markerless harnesses (codex, opencode, kimi, muse) scrub every verified foreign marker"
}

test_claude_preserves_own_marker_scrubs_foreign() {
  local rec out status launch
  rec=$(make_ship_case claude-preserve claude)
  read_ship "$rec"
  out=$(run_ship_under_foreign \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" claude)
  status=$?
  expect_code 0 "$status" "claude spawn under foreign markers should succeed: $out"
  launch=$(final_launch "$LAUNCH_LOG")
  assert_unsets "$launch" PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT
  assert_does_not_unset "$launch" CLAUDECODE
  pass "claude launch preserves CLAUDECODE and scrubs foreign markers"
}

test_pi_family_preserves_own_markers_scrubs_foreign() {
  local harness rec out status launch
  for harness in pi pi-signed; do
    rec=$(make_ship_case "pi-preserve-$harness" "$harness")
    read_ship "$rec"
    out=$(run_ship_under_foreign \
      "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$CASE_ID" "$harness")
    status=$?
    expect_code 0 "$status" "$harness spawn under foreign markers should succeed: $out"
    launch=$(final_launch "$LAUNCH_LOG")
    assert_unsets "$launch" CLAUDECODE GROK_AGENT
    assert_does_not_unset "$launch" PI_CODING_AGENT FM_PI_HARNESS
    assert_contains "$launch" "FM_PI_HARNESS=$harness" \
      "$harness launch did not re-set its selection marker: $launch"
  done
  pass "pi and pi-signed preserve their markers and scrub foreign ones"
}

test_grok_preserves_own_marker_scrubs_foreign() {
  local rec out status launch
  rec=$(make_ship_case grok-preserve grok)
  read_ship "$rec"
  out=$(run_ship_under_foreign \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" grok)
  status=$?
  expect_code 0 "$status" "grok spawn under foreign markers should succeed: $out"
  launch=$(final_launch "$LAUNCH_LOG")
  assert_unsets "$launch" CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS
  assert_does_not_unset "$launch" GROK_AGENT
  pass "grok launch preserves GROK_AGENT and scrubs foreign markers"
}

test_secondmate_codex_scrubs_foreign_markers() {
  local rec out status launch
  rec=$(make_secondmate_case sm-codex codex)
  read_sm "$rec"
  out=$(run_secondmate_under_foreign \
    "$HOME_DIR" "$SM_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID")
  status=$?
  expect_code 0 "$status" "secondmate codex spawn under foreign markers should succeed: $out"
  launch=$(final_launch "$LAUNCH_LOG")
  assert_contains "$out" "harness=codex kind=secondmate" \
    "secondmate did not report codex: $out"
  assert_unsets "$launch" CLAUDECODE PI_CODING_AGENT GROK_AGENT FM_PI_HARNESS
  pass "secondmate codex launch scrubs every verified foreign marker"
}

# --- execute-style: constructed env contains none of the foreign markers ----

test_codex_launch_env_drops_foreign_markers_at_runtime() {
  local rec out status launch env_result
  rec=$(make_ship_case codex-exec codex)
  read_ship "$rec"
  env_result="$CASE_DIR/env-result"
  # Replace the codex binary with a probe that records the post-scrub env.
  cp "$FAKEBIN_DIR/codex-probe" "$FAKEBIN_DIR/codex"
  out=$(FM_FAKE_EXECUTE_LAUNCH=1 FM_FAKE_ENV_RESULT="$env_result" \
    FM_FAKE_HARNESS_PROBE="$HARNESS_BIN" \
    run_ship_under_foreign \
      "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$CASE_ID" codex)
  status=$?
  expect_code 0 "$status" "codex execute-style spawn should succeed: $out"
  launch=$(final_launch "$LAUNCH_LOG")
  assert_unsets "$launch" CLAUDECODE PI_CODING_AGENT GROK_AGENT FM_PI_HARNESS
  [ -f "$env_result" ] || fail "codex probe never wrote the post-scrub env result"
  assert_contains "$(cat "$env_result")" 'CLAUDECODE=__unset__' \
    "codex worker still saw CLAUDECODE after scrub: $(cat "$env_result")"
  assert_contains "$(cat "$env_result")" 'PI_CODING_AGENT=__unset__' \
    "codex worker still saw PI_CODING_AGENT after scrub: $(cat "$env_result")"
  assert_contains "$(cat "$env_result")" 'FM_PI_HARNESS=__unset__' \
    "codex worker still saw FM_PI_HARNESS after scrub: $(cat "$env_result")"
  assert_contains "$(cat "$env_result")" 'GROK_AGENT=__unset__' \
    "codex worker still saw GROK_AGENT after scrub: $(cat "$env_result")"
  # Detection under a clean env must not report a foreign marker harness.
  assert_not_contains "$(cat "$env_result")" 'DETECT=claude' \
    "codex worker still misdetected as claude: $(cat "$env_result")"
  assert_not_contains "$(cat "$env_result")" 'DETECT=pi' \
    "codex worker still misdetected as pi: $(cat "$env_result")"
  assert_not_contains "$(cat "$env_result")" 'DETECT=grok' \
    "codex worker still misdetected as grok: $(cat "$env_result")"
  pass "codex launch env constructed under foreign markers contains none of them"
}

test_claude_launch_env_keeps_own_marker_drops_foreign() {
  local rec out status env_result
  rec=$(make_ship_case claude-exec claude)
  read_ship "$rec"
  env_result="$CASE_DIR/env-result"
  # Raw launch so we control the probe binary while still going through the
  # same foreign_marker_scrub_prefix path (HARNESS basename = claude-probe →
  # treated as non-claude * unless we name it claude). Use harness name claude
  # via a PATH claude that is the probe.
  cp "$FAKEBIN_DIR/claude-probe" "$FAKEBIN_DIR/claude"
  out=$(FM_FAKE_EXECUTE_LAUNCH=1 FM_FAKE_ENV_RESULT="$env_result" \
    run_ship_under_foreign \
      "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$CASE_ID" claude)
  status=$?
  expect_code 0 "$status" "claude execute-style spawn should succeed: $out"
  [ -f "$env_result" ] || fail "claude probe never wrote the post-scrub env result"
  # CLAUDECODE is claude's own marker: scrub must not drop it, so the inherited
  # CLAUDECODE=1 survives into the worker env.
  assert_contains "$(cat "$env_result")" 'CLAUDECODE=1' \
    "claude worker lost its own CLAUDECODE marker: $(cat "$env_result")"
  assert_contains "$(cat "$env_result")" 'PI_CODING_AGENT=__unset__' \
    "claude worker still saw foreign PI_CODING_AGENT: $(cat "$env_result")"
  assert_contains "$(cat "$env_result")" 'FM_PI_HARNESS=__unset__' \
    "claude worker still saw foreign FM_PI_HARNESS: $(cat "$env_result")"
  assert_contains "$(cat "$env_result")" 'GROK_AGENT=__unset__' \
    "claude worker still saw foreign GROK_AGENT: $(cat "$env_result")"
  pass "claude launch env keeps CLAUDECODE and drops foreign markers"
}

test_pi_launch_env_keeps_selection_marker_drops_foreign() {
  local rec out status env_result launch
  rec=$(make_ship_case pi-exec pi)
  read_ship "$rec"
  env_result="$CASE_DIR/env-result"
  # Swap the resolved pi binary for a probe after help probing... help runs
  # during spawn BEFORE launch, so the probe must still answer --help.
  cat > "$FAKEBIN_DIR/pi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
  exit 0
fi
{
  printf 'CLAUDECODE=%s\n' "${CLAUDECODE-__unset__}"
  printf 'PI_CODING_AGENT=%s\n' "${PI_CODING_AGENT-__unset__}"
  printf 'FM_PI_HARNESS=%s\n' "${FM_PI_HARNESS-__unset__}"
  printf 'GROK_AGENT=%s\n' "${GROK_AGENT-__unset__}"
} > "${FM_FAKE_ENV_RESULT:?}"
exit 0
SH
  chmod +x "$FAKEBIN_DIR/pi"
  out=$(FM_FAKE_EXECUTE_LAUNCH=1 FM_FAKE_ENV_RESULT="$env_result" \
    run_ship_under_foreign \
      "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$CASE_ID" pi)
  status=$?
  expect_code 0 "$status" "pi execute-style spawn should succeed: $out"
  launch=$(final_launch "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi" "pi launch lost selection marker: $launch"
  [ -f "$env_result" ] || fail "pi probe never wrote the post-scrub env result"
  assert_contains "$(cat "$env_result")" 'CLAUDECODE=__unset__' \
    "pi worker still saw foreign CLAUDECODE: $(cat "$env_result")"
  assert_contains "$(cat "$env_result")" 'GROK_AGENT=__unset__' \
    "pi worker still saw foreign GROK_AGENT: $(cat "$env_result")"
  # FM_PI_HARNESS is re-set on the launch line to the target identity.
  assert_contains "$(cat "$env_result")" 'FM_PI_HARNESS=pi' \
    "pi worker lost its FM_PI_HARNESS selection marker: $(cat "$env_result")"
  # PI_CODING_AGENT is pi's own marker family: scrub does not -u it, so the
  # inherited true value survives (and real pi would set it for children).
  assert_contains "$(cat "$env_result")" 'PI_CODING_AGENT=true' \
    "pi worker lost PI_CODING_AGENT: $(cat "$env_result")"
  pass "pi launch env keeps its markers and drops foreign ones"
}

# --- run --------------------------------------------------------------------

test_markerless_harnesses_scrub_all_verified_markers
test_claude_preserves_own_marker_scrubs_foreign
test_pi_family_preserves_own_markers_scrubs_foreign
test_grok_preserves_own_marker_scrubs_foreign
test_secondmate_codex_scrubs_foreign_markers
test_codex_launch_env_drops_foreign_markers_at_runtime
test_claude_launch_env_keeps_own_marker_drops_foreign
test_pi_launch_env_keeps_selection_marker_drops_foreign

printf 'All foreign-marker-scrub tests passed.\n'
