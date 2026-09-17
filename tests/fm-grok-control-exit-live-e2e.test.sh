#!/usr/bin/env bash
# Live Grok empty-composer and control-exit guard.
#
# This launches the installed Grok in a scratch Git repository on a private
# tmux socket, requires its fresh composer to classify `empty` through the real
# tmux adapter, then drives `bin/fm-control.sh <id> exit` and proves the agent
# stopped while the exact endpoint survived.
# The slash exit command submits no model prompt and spends no model tokens.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_GROK_CONTROL_EXIT_LIVE_E2E tmux grok

ID=grok-live-exit
SOCKET="fm-grok-control-exit-$$"
SESSION=grok-control-exit
TARGET="$SESSION:fm-$ID"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-grok-control-exit.XXXXXX")
REAL_TMUX=$(command -v tmux)
GROK_BIN=$(command -v grok)
VERSION=$($GROK_BIN --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION=version-unknown

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/bin" "$LAB/fmhome/state" "$LAB/fmhome/data" "$LAB/fmhome/config" "$LAB/project"
git -C "$LAB/project" init -q

cat > "$LAB/bin/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOF
chmod +x "$LAB/bin/tmux"
PATH="$LAB/bin:$PATH"
export PATH

cat > "$LAB/fmhome/state/$ID.meta" <<EOF
window=$TARGET
endpoint_task_id=$ID
worktree=$LAB/project
project=$LAB/project
harness=grok
kind=scout
mode=no-mistakes
yolo=off
model=default
effort=default
EOF

tmux new-session -d -s "$SESSION" -n control -x 180 -y 45 -- sleep 300 \
  || fail "grok ($VERSION): could not create the isolated control session"
# shellcheck disable=SC2016 # single quotes deliberately expand the binary and shell inside the child process
tmux new-window -d -t "$SESSION:" -n "fm-$ID" -c "$LAB/project" -- \
  env FM_GROK_LIVE_BIN="$GROK_BIN" /bin/bash -c \
    '"$FM_GROK_LIVE_BIN" --always-approve; exec "${SHELL:-/bin/bash}" -l' \
  || fail "grok ($VERSION): could not launch in the isolated target window"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

verdict=unknown
i=0
while [ "$i" -lt "${FM_GROK_CONTROL_EXIT_LIVE_POLLS:-60}" ]; do
  verdict=$(fm_tmux_composer_state "$TARGET")
  [ "$verdict" = empty ] && break
  i=$((i + 1))
  sleep 1
done
if [ "$verdict" != empty ]; then
  printf '# grok pane tail at failure:\n' >&2
  tmux capture-pane -p -t "$TARGET" -S -20 2>/dev/null \
    | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fail "grok ($VERSION): fresh composer never classified empty (last verdict: ${verdict:-unreadable})"
fi
pass "grok ($VERSION): fresh scratch-repository composer classifies empty"

out=$(FM_HOME="$LAB/fmhome" FM_ROOT_OVERRIDE="$ROOT" \
  FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 \
  "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1) \
  || fail "grok ($VERSION): fm-control exit failed: $out"
assert_contains "$out" "stopped $ID harness=grok backend=tmux endpoint=$TARGET" \
  "grok ($VERSION): fm-control did not report the verified stop"
tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null \
  || fail "grok ($VERSION): fm-control exit destroyed the target endpoint"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = dead ] \
  || fail "grok ($VERSION): endpoint survived but agent state was '$state', expected dead"
pass "grok ($VERSION): fm-control exit stopped the agent and preserved the endpoint"
