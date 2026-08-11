#!/usr/bin/env bash
# Opt-in fail-open and owner-path smoke for the primary focus lifecycle.
#
# This invokes the shared hook CLI and owner directly. It does not submit a
# prompt through any installed harness and does not verify harness callbacks.
# Standard CI self-skips it unless FM_FOCUS_HOOK_LIVE=1 is set.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_FOCUS_HOOK_LIVE:-}" != "1" ]; then
  echo "skip: set FM_FOCUS_HOOK_LIVE=1 to run the focus fail-open and owner-path smoke"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-focus-hook-live)

exercise_shared_paths() {
  local home state status snap
  home="$TMP_ROOT/smoke-home"
  state="$home/state"
  mkdir -p "$state" "$home/bin"

  status=0
  printf '%s' '{"prompt":"focus smoke probe"}' \
    | FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      "$ROOT/bin/fm-focus-prompt-hook.sh" --claude >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || {
    printf 'not ok - shared focus hook exited %s (must be fail-open 0)\n' "$status" >&2
    return 1
  }

  "$ROOT/bin/fm-focus.sh" switch --state-dir "$state" \
    --summary "owner-smoke" --owner-kind primary-direct >/dev/null \
    || {
      printf 'not ok - focus owner switch failed\n' >&2
      return 1
    }
  snap=$(cat "$state/.focus.json")
  [ "$(printf '%s' "$snap" | jq -r '.active.summary')" = "owner-smoke" ] \
    || {
      printf 'not ok - durable focus missing after owner switch\n' >&2
      return 1
    }
  return 0
}

exercise_shared_paths || exit 1
pass "focus shared-hook fail-open and owner-path smoke passed; no harness callbacks exercised"
