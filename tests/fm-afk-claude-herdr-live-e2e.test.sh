#!/usr/bin/env bash
# Live Claude/Herdr away-mode transport guard (live-harness-optin family).
#
# The away daemon's busy guard consumes Herdr native agent state and Claude's
# rendered footer, so a fake harness can only confirm its own fixtures.
# This guard launches real Claude Code in an isolated Herdr lab, starts the
# production separate-workspace path, and requires one idle delivery plus one
# real-turn deferral with branch-specific diagnostics.
#
# Run explicitly with FM_AFK_CLAUDE_HERDR_LIVE=1 after a Herdr or Claude
# upgrade and before refreshing docs/verification/runtime-backends.md.
# Every Herdr call, including production adapter calls, is routed through
# bin/fm-herdr-lab.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
case "$LAB_HELPER" in
  /*) ;;
  *) LAB_HELPER="$(cd "$(dirname "$LAB_HELPER")" && pwd -P)/$(basename "$LAB_HELPER")" ;;
esac

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_AFK_CLAUDE_HERDR_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_AFK_CLAUDE_HERDR_LIVE=1 to run the live Claude/Herdr away-mode transport guard"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_AFK_CLAUDE_HERDR_LIVE=1 but Herdr is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_AFK_CLAUDE_HERDR_LIVE=1 but jq is not installed"
command -v claude >/dev/null 2>&1 || fail "FM_AFK_CLAUDE_HERDR_LIVE=1 but Claude Code is not installed"
[ -x "$LAB_HELPER" ] || fail "FM_AFK_CLAUDE_HERDR_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name fm-afk-claude-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-afk-claude-live.XXXXXX")
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
FAKEBIN="$TMP_ROOT/fakebin"
ENTRY="$TMP_ROOT/probe-entry"
CAPTAIN_PANE=
CAPTAIN_TARGET=
LAUNCH_ACTIVE=0
CHECKED=0
CLAUDE_VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VERSION=version-unknown

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$LAUNCH_ACTIVE" -eq 1 ]; then
    PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      FM_SUPERVISOR_TARGET="$CAPTAIN_TARGET" FM_SUPERVISOR_BACKEND=herdr \
      "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1 || rc=1
  fi
  if [ -n "$CAPTAIN_PANE" ]; then
    "$LAB_HELPER" run "$SESSION" pane send-keys "$CAPTAIN_PANE" escape >/dev/null 2>&1 || true
  fi
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$FAKEBIN"

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n - 2))]}" = --session ]; then
  [ "\${args[\$((n - 1))]}" = "\$session" ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n - 2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo 'wrapper requires isolated session' >&2; exit 98; }
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

cat > "$ENTRY" <<EOF
#!/usr/bin/env bash
set -u
root='$ROOT'
home=\${FM_HOME:?}
state=\$home/state
[ "\${FM_AFK_LAUNCH_PROVENANCE:-}" = separate-terminal ] || exit 97
export FM_STATE_OVERRIDE=\$state
export HERDR_LAB_HELPER='$LAB_HELPER'
export HERDR_LAB_SESSION
HERDR_LAB_SESSION=\$(cat "\$home/lab-session")
export HERDR_SESSION=\$HERDR_LAB_SESSION
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export FM_DAEMON_PRIMARY_HARNESS=claude
export FM_INJECT_CONFIRM_RETRIES=6
export FM_INJECT_CONFIRM_SLEEP=0.5
. "\$root/bin/fm-supervise-daemon.sh"
if [ -e "\$home/force-rendered-busy" ]; then
  fm_backend_busy_state() { printf unknown; }
fi
LOG="\$state/probe.log"
if inject_msg "\$(cat "\$home/probe-message")" "\$state"; then
  printf 'delivered\n' > "\$state/probe-result"
else
  printf 'deferred\n' > "\$state/probe-result"
fi
exec sleep 120
EOF
chmod +x "$ENTRY"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab for Claude Code ($CLAUDE_VERSION)"
STATUS_JSON=$("$LAB_HELPER" run "$SESSION" status --json 2>/dev/null) \
  || fail "Claude Code ($CLAUDE_VERSION): could not read the isolated Herdr version"
HERDR_VERSION=$(printf '%s' "$STATUS_JSON" | jq -r '.server.version // .client.version // "version-unknown"')
PAIR="Claude Code ($CLAUDE_VERSION) on Herdr ($HERDR_VERSION)"
printf '%s\n' "$SESSION" > "$HOME_DIR/lab-session"

CAPTAIN_JSON=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$ROOT" --label fm-afk-claude-primary --no-focus) \
  || fail "$PAIR: could not create the isolated captain workspace"
CAPTAIN_PANE=$(printf '%s' "$CAPTAIN_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "$PAIR: workspace creation returned no captain pane"
CAPTAIN_TARGET="$SESSION:$CAPTAIN_PANE"
"$LAB_HELPER" run "$SESSION" pane run "$CAPTAIN_PANE" \
  "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" >/dev/null \
  || fail "$PAIR: could not launch the real Claude captain"

wait_for_idle() {
  local stable=0 status _
  for _ in $(seq 1 180); do
    status=$("$LAB_HELPER" run "$SESSION" agent get "$CAPTAIN_PANE" 2>/dev/null \
      | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in
      idle|done|blocked) stable=$((stable + 1)); [ "$stable" -ge 2 ] && return 0 ;;
      *) stable=0 ;;
    esac
    sleep 0.25
  done
  return 1
}

run_probe() {  # <message> <expected-result>
  local message=$1 expected=$2 result record _
  printf '%s\n' "$message" > "$HOME_DIR/probe-message"
  rm -f "$STATE/probe-result" "$STATE/probe.log"
  PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_SUPERVISOR_TARGET="$CAPTAIN_TARGET" FM_SUPERVISOR_BACKEND=herdr FM_AFK_LAUNCH_ENTRY="$ENTRY" \
    "$ROOT/bin/fm-afk-launch.sh" start >/dev/null \
    || fail "$PAIR: separate-workspace away launch failed"
  LAUNCH_ACTIVE=1
  record=$(cat "$STATE/.afk-daemon-terminal" 2>/dev/null || true)
  case "$record" in
    $'herdr\t'"$SESSION":* ) ;;
    *) fail "$PAIR: launcher did not record a separate Herdr daemon pane: ${record:-missing}" ;;
  esac
  [ "$(printf '%s' "$record" | cut -f2)" != "$CAPTAIN_TARGET" ] \
    || fail "$PAIR: daemon was hosted in the captain pane"
  for _ in $(seq 1 300); do
    [ -s "$STATE/probe-result" ] && break
    sleep 0.1
  done
  result=$(cat "$STATE/probe-result" 2>/dev/null || true)
  if [ "$result" != "$expected" ]; then
    printf '%s\n' "$PAIR: probe diagnostics:" >&2
    sed -n '1,80p' "$STATE/probe.log" >&2 2>/dev/null || true
    "$LAB_HELPER" run "$SESSION" pane read "$CAPTAIN_PANE" --source recent --lines 60 >&2 2>/dev/null || true
    fail "$PAIR: separate-pane probe returned '${result:-missing}', expected '$expected'"
  fi
}

stop_probe() {
  PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_SUPERVISOR_TARGET="$CAPTAIN_TARGET" FM_SUPERVISOR_BACKEND=herdr \
    "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null \
    || fail "$PAIR: separate-workspace away stop failed"
  LAUNCH_ACTIVE=0
}

wait_for_idle || fail "$PAIR: captain never reached a stable idle state"
IDLE_TOKEN="FMIDLE$$_$RANDOM"
run_probe "Lab away-mode delivery probe. Reply exactly $IDLE_TOKEN and nothing else." delivered
IDLE_LANDED=0
for _ in $(seq 1 180); do
  SCREEN=$("$LAB_HELPER" run "$SESSION" pane read "$CAPTAIN_PANE" --source recent --lines 200 2>/dev/null || true)
  OCCURRENCES=$(printf '%s\n' "$SCREEN" | grep -F -c "$IDLE_TOKEN" || true)
  if [ "$OCCURRENCES" -ge 2 ]; then IDLE_LANDED=1; break; fi
  sleep 0.25
done
[ "$IDLE_LANDED" -eq 1 ] || fail "$PAIR: idle injection reported delivered but Claude never rendered its reply"
CHECKED=$((CHECKED + 1))
stop_probe
wait_for_idle || fail "$PAIR: captain did not settle after the idle delivery"
pass "$PAIR: separate-pane away transport delivers while the captain is idle"

TURN_TOKEN="FMTURN$$_$RANDOM"
"$LAB_HELPER" run "$SESSION" pane send-text "$CAPTAIN_PANE" \
  "Write a detailed 600-word explanation of external supervision. End with exactly $TURN_TOKEN. Do not use tools." >/dev/null \
  || fail "$PAIR: could not type the real-turn prompt"
"$LAB_HELPER" run "$SESSION" pane send-keys "$CAPTAIN_PANE" enter >/dev/null \
  || fail "$PAIR: could not submit the real-turn prompt"
TURN_BUSY=0
for _ in $(seq 1 120); do
  STATUS=$("$LAB_HELPER" run "$SESSION" agent get "$CAPTAIN_PANE" 2>/dev/null \
    | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
  if [ "$STATUS" = working ]; then TURN_BUSY=1; break; fi
  sleep 0.1
done
[ "$TURN_BUSY" -eq 1 ] || fail "$PAIR: real Claude turn never reported working"
BUSY_TOKEN="FMBUSY$$_$RANDOM"
: > "$HOME_DIR/force-rendered-busy"
run_probe "Lab busy-turn probe. Reply exactly $BUSY_TOKEN and nothing else." deferred
grep -F 'native=unknown rendered=match' "$STATE/probe.log" >/dev/null \
  || fail "$PAIR: real-turn deferral did not run and match the rendered busy branch"
SCREEN=$("$LAB_HELPER" run "$SESSION" pane read "$CAPTAIN_PANE" --source recent --lines 200 2>/dev/null || true)
if printf '%s\n' "$SCREEN" | grep -F "$BUSY_TOKEN" >/dev/null; then
  fail "$PAIR: deferred probe text appeared in the captain pane during a real turn"
fi
CHECKED=$((CHECKED + 1))
stop_probe
"$LAB_HELPER" run "$SESSION" pane send-keys "$CAPTAIN_PANE" escape >/dev/null 2>&1 || true
pass "$PAIR: separate-pane away transport defers during a real turn through the rendered branch"

[ "$CHECKED" -gt 0 ] || fail "$PAIR: live away-mode transport guard checked nothing"
pass "live Claude/Herdr away-mode transport guard verified $CHECKED path(s)"
