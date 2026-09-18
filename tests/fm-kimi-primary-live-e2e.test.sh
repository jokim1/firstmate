#!/usr/bin/env bash
# Opt-in credentialed Kimi primary Stop-hook regression using the real user
# home and an isolated Kimi home and secondmate fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if command -v kimi >/dev/null 2>&1; then
  KIMI=$(command -v kimi)
elif [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
  KIMI="$HOME/.kimi-code/bin/kimi"
else
  KIMI=kimi
fi
fm_live_gate opt-in FM_KIMI_LIVE_E2E "$KIMI" jq python3

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

KIMI_VERSION=$("$KIMI" --version 2>/dev/null | head -1 | tr -d '\r')
REAL_HOME=${HOME:?}
SOURCE_KIMI_HOME=${KIMI_CODE_HOME:-$REAL_HOME/.kimi-code}
LAB=$(fm_test_tmproot fm-kimi-primary-live-e2e)
USER_HOME="$LAB/user"
KIMI_HOME="$USER_HOME/.kimi-code"
MATE="$LAB/mate"
EMPTY_SKILLS="$LAB/empty-skills"
HOOK_LOG="$LAB/hook.log"
RUN_LOG="$LAB/kimi.log"
CHILD_PID=

fail_live() {
  fail "Kimi Code $KIMI_VERSION: $1"
}

cleanup() {
  if [ -n "$CHILD_PID" ]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

[ -f "$SOURCE_KIMI_HOME/config.toml" ] \
  || fail_live "the credentialed live guard was requested but $SOURCE_KIMI_HOME/config.toml is absent"

mkdir -p "$KIMI_HOME" "$MATE" "$EMPTY_SKILLS"
chmod 700 "$USER_HOME" "$KIMI_HOME"
cp "$SOURCE_KIMI_HOME/config.toml" "$KIMI_HOME/config.toml"
chmod 600 "$KIMI_HOME/config.toml"
# Keep any token refresh inside the private fixture rather than mutating the
# credential store the real home owns.
for name in credentials oauth device_id region; do
  [ -e "$SOURCE_KIMI_HOME/$name" ] || continue
  cp -R "$SOURCE_KIMI_HOME/$name" "$KIMI_HOME/$name"
done
chmod -R go-rwx "$KIMI_HOME"

git clone -q "$ROOT" "$MATE" \
  || fail_live "could not clone the repository into the isolated secondmate fixture"
mkdir -p "$MATE/state" "$MATE/config" "$MATE/data" "$MATE/projects"
printf '%s\n' kimi-primary-live-e2e > "$MATE/.fm-secondmate-home"
printf '%s\n' '# Kimi live guard fixture' > "$MATE/AGENTS.md"

HOME="$USER_HOME" KIMI_CODE_HOME="$KIMI_HOME" \
  "$MATE/bin/fm-kimi-turnend-hook.sh" install >/dev/null \
  || fail_live "the tracked Kimi Stop-hook installer failed in the isolated home"

TOKEN=fm.KimiLiveE2E1
printf 'token=%s\n' "$TOKEN" > "$MATE/.fm-kimi-turnend"
printf 'primary=%s\n' "$MATE" > "$KIMI_HOME/fm-turn-end.d/$TOKEN"
chmod 600 "$MATE/.fm-kimi-turnend" "$KIMI_HOME/fm-turn-end.d/$TOKEN"

mv "$KIMI_HOME/fm-turn-end.sh" "$KIMI_HOME/fm-turn-end.real.sh"
cat > "$KIMI_HOME/fm-turn-end.sh" <<'SH'
#!/usr/bin/env bash
set -u
payload=$(cat)
rc=0
printf '%s\n' "$payload" | "$FM_KIMI_LIVE_GUARD_REAL_HOOK" || rc=$?
event=$(printf '%s\n' "$payload" | jq -r '.hook_event_name // "missing"' 2>/dev/null || printf invalid)
active=$(printf '%s\n' "$payload" | jq -r 'if has("stop_hook_active") then .stop_hook_active else "missing" end' 2>/dev/null || printf invalid)
printf 'rc=%s event=%s active=%s\n' "$rc" "$event" "$active" >> "$FM_KIMI_LIVE_GUARD_LOG"
exit "$rc"
SH
chmod 700 "$KIMI_HOME/fm-turn-end.sh" "$KIMI_HOME/fm-turn-end.real.sh"

FM_TASK_ID=kimi-live-child sleep 180 &
CHILD_PID=$!
kill -0 "$CHILD_PID" 2>/dev/null || fail_live "the real child process did not remain live"
printf 'kind=ship\npid=%s\n' "$CHILD_PID" > "$MATE/state/kimi-live-child.meta"

printf 'harness: Kimi Code %s\n' "$KIMI_VERSION"
status=0
(
  cd "$MATE" || exit 1
  HOME="$REAL_HOME" \
    KIMI_CODE_HOME="$KIMI_HOME" \
    KIMI_CODE_NO_AUTO_UPDATE=1 \
    FM_CODEX_WATCH_CHECKPOINT=1 \
    FM_KIMI_LIVE_GUARD_REAL_HOOK="$KIMI_HOME/fm-turn-end.real.sh" \
    FM_KIMI_LIVE_GUARD_LOG="$HOOK_LOG" \
    fm_run_timed "${FM_KIMI_LIVE_TIMEOUT_SECONDS:-120}" \
      "$KIMI" --skills-dir "$EMPTY_SKILLS" --prompt \
      'Reply exactly KIMI_LIVE_INITIAL. If a Stop hook blocks that stop, continue once and then stop again without using tools.'
) > "$RUN_LOG" 2>&1 || status=$?

if [ "$status" -ne 0 ]; then
  diagnostic=$(sed '/^See log:/d' "$RUN_LOG" 2>/dev/null | tail -12 | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  fail_live "the real prompt exited $status before proving Stop continuation; output: $diagnostic"
fi

first=$(sed -n '1p' "$HOOK_LOG" 2>/dev/null || true)
second=$(sed -n '2p' "$HOOK_LOG" 2>/dev/null || true)
[ "$first" = 'rc=2 event=Stop active=false' ] \
  || fail_live "the first real Stop did not preserve the guard's exit 2 with stop_hook_active=false; observed '${first:-no hook event}'"
[ "$second" = 'rc=0 event=Stop active=true' ] \
  || fail_live "Kimi did not compel one retry carrying stop_hook_active=true after exit 2; observed '${second:-no retry event}'"

pass "Kimi Code $KIMI_VERSION compelled the exit-2 continuation and marked its bounded retry stop_hook_active=true"
