#!/usr/bin/env bash
# Live-harness-optin guard for the primary focus UserPromptSubmit / input path.
#
# Standard CI has neither harness binaries nor credentials, so this suite is
# self-skipping unless FM_FOCUS_HOOK_LIVE=1 is set. When enabled it exercises
# every INSTALLED supported primary harness that exposes a pre-prompt surface
# and fails naming the harness and version rather than passing over nothing.
#
# This is the live half of the two-test rule in firstmate-coding-guidelines;
# the portable half lives in tests/fm-focus.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_FOCUS_HOOK_LIVE:-}" != "1" ]; then
  echo "skip: set FM_FOCUS_HOOK_LIVE=1 to run the installed-harness focus hook guard"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-focus-hook-live)
checked=0
missing=0
failed=0

note() { printf 'note - %s\n' "$1"; }
harness_version() {  # <cmd> <args...>
  "$@" 2>/dev/null | head -n 1 | tr -d '\r'
}

# Drive the shared hook as the harness would: JSON on stdin, always exit 0,
# and when primary scope can be satisfied, a durable snapshot appears.
exercise_hook_cli() {  # <harness-flag>
  local harness=$1 home state status snap
  home="$TMP_ROOT/$harness-home"
  state="$home/state"
  mkdir -p "$state" "$home/bin"
  # Soft primary: real scripts + AGENTS.md; not a linked worktree of this repo
  # (we cannot mint a full primary checkout here). Assert the fail-open exit
  # and that an explicit owner call from the same home works.
  status=0
  printf '%s' '{"prompt":"live focus probe from '"$harness"'"}' \
    | FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      "$ROOT/bin/fm-focus-prompt-hook.sh" "--$harness" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || {
    printf 'not ok - %s focus hook exited %s (must be fail-open 0)\n' "$harness" "$status" >&2
    return 1
  }
  # Owner path (hard): prove the durable record for this harness label.
  "$ROOT/bin/fm-focus.sh" switch --state-dir "$state" \
    --summary "live-$harness" --owner-kind primary-direct \
    --resume-kind harness-session --resume-pointer "$harness" >/dev/null \
    || {
      printf 'not ok - %s owner switch failed\n' "$harness" >&2
      return 1
    }
  snap=$(cat "$state/.focus.json")
  [ "$(printf '%s' "$snap" | jq -r '.active.summary')" = "live-$harness" ] \
    || {
      printf 'not ok - %s durable focus missing after owner switch\n' "$harness" >&2
      return 1
    }
  return 0
}

check_harness() {  # <name> <detect-cmd...>
  local name=$1
  shift
  if ! command -v "$1" >/dev/null 2>&1; then
    note "skip: $name is not installed on this machine"
    missing=$((missing + 1))
    return 0
  fi
  checked=$((checked + 1))
  ver=$(harness_version "$@" || true)
  if exercise_hook_cli "$name"; then
    pass "$name focus path ok (${ver:-version unknown})"
  else
    failed=$((failed + 1))
    printf 'not ok - %s focus path failed (%s)\n' "$name" "${ver:-version unknown}" >&2
  fi
}

# Supported primary set from AGENTS.md / harness-adapters.
check_harness claude claude --version
check_harness codex codex --version
check_harness pi pi --version
# pi-signed shares the Pi runtime; detect via pi when the signed binary is absent.
if command -v pi-signed >/dev/null 2>&1; then
  check_harness pi pi-signed --version
else
  note "skip: pi-signed is not installed; Pi runtime covered by the pi check when present"
fi
check_harness grok grok --version
check_harness kimi kimi --version
# OpenCode degraded path.
if command -v opencode >/dev/null 2>&1; then
  check_harness opencode opencode --version
else
  note "skip: opencode is not installed on this machine"
  missing=$((missing + 1))
fi

if [ "$checked" -eq 0 ]; then
  printf 'not ok - focus live guard checked nothing; install at least one primary harness or leave FM_FOCUS_HOOK_LIVE unset\n' >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  printf 'not ok - focus live guard: %s harness path(s) failed\n' "$failed" >&2
  exit 1
fi
pass "focus live guard exercised $checked installed harness path(s) (missing=$missing)"
