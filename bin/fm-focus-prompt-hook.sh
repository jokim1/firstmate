#!/usr/bin/env bash
# fm-focus-prompt-hook.sh - fail-open harness adapter for suspend-before-switch.
#
# Invoked from verified primary-harness pre-prompt surfaces (UserPromptSubmit,
# Pi input, OpenCode message events, etc.). Translates the harness event into
# one call of bin/fm-focus.sh switch so a new captain prompt durably suspends
# any nonterminal active focus before the model takes the new work.
#
# ALWAYS fail-open: this script exits 0 on every path. A focus-record failure,
# missing jq, unwritable state, non-primary scope, or operational/injected input
# must never prevent the captain's prompt. Adapter waits are bounded.
# The owner script (bin/fm-focus.sh) remains the hard-refusal surface for
# operators and tests.
#
# Usage:
#   <hook JSON on stdin> | bin/fm-focus-prompt-hook.sh [--claude|--codex|--grok|--pi|--opencode|--kimi]
#   bin/fm-focus-prompt-hook.sh --prompt '<text>' [--summary S] ...
#
# Prompt and identity extraction (stdin JSON):
#   .prompt // .user_prompt // .content // .message.content // .text
# A vendor event id enables retry idempotency. Without one, each callback is a
# distinct submission. A vendor session id becomes the opaque resume pointer.
# Operational Firstmate-injected inputs are skipped (no focus mutation).
# Codex and Kimi have no verified tracked pre-prompt adapter in Phase 0.
# --codex and --kimi remain label-only for external callers.
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 0
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}" || exit 0
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" 2>/dev/null || exit 0
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh" 2>/dev/null || exit 0

PROMPT=
SUMMARY=
OWNER_KIND=primary-direct
TASK_ID=
PROJECT=
RESUME_KIND=
RESUME_POINTER=
EVENT_ID=
SESSION_ID=
HARNESS=
PAYLOAD=

while [ $# -gt 0 ]; do
  case "$1" in
    --claude|--codex|--grok|--kimi|--pi|--opencode)
      HARNESS=${1#--}
      shift
      ;;
    --prompt)
      PROMPT=${2:-}
      shift 2 || exit 0
      ;;
    --prompt=*)
      PROMPT=${1#--prompt=}
      shift
      ;;
    --summary)
      SUMMARY=${2:-}
      shift 2 || exit 0
      ;;
    --summary=*)
      SUMMARY=${1#--summary=}
      shift
      ;;
    --owner-kind)
      OWNER_KIND=${2:-primary-direct}
      shift 2 || exit 0
      ;;
    --task-id)
      TASK_ID=${2:-}
      shift 2 || exit 0
      ;;
    --project)
      PROJECT=${2:-}
      shift 2 || exit 0
      ;;
    --resume-kind)
      RESUME_KIND=${2:-}
      shift 2 || exit 0
      ;;
    --resume-pointer)
      RESUME_POINTER=${2:-}
      shift 2 || exit 0
      ;;
    --event-id)
      EVENT_ID=${2:-}
      shift 2 || exit 0
      ;;
    --session-id)
      SESSION_ID=${2:-}
      shift 2 || exit 0
      ;;
    -h|--help)
      cat <<'EOF'
Usage: fm-focus-prompt-hook.sh [--claude|--codex|--grok|--pi|--opencode|--kimi] [options]
Fail-open primary pre-prompt adapter for bin/fm-focus.sh switch.
Codex and Kimi have no verified tracked pre-prompt adapter in Phase 0.
Always exits 0. See the script header for the full contract.
EOF
      exit 0
      ;;
    *)
      # Unknown args: ignore and stay fail-open.
      shift
      ;;
  esac
done

# Silent no-op outside a genuine primary home (or when state is missing).
fm_primary_scope_matches "$FM_ROOT" "$STATE" 2>/dev/null || exit 0
[ -d "$STATE" ] || exit 0
[ -x "$SCRIPT_DIR/fm-focus.sh" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

if [ -z "$PROMPT" ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '
    (.prompt // .user_prompt // .content // .message.content // .text // empty)
    | if type == "string" then .
      elif type == "array" then (map(if type == "string" then . elif type == "object" then (.text // empty) else empty end) | join("\n"))
      else empty end
  ' 2>/dev/null) || exit 0
fi

if [ -n "$PAYLOAD" ]; then
  if [ -z "$EVENT_ID" ]; then
    EVENT_ID=$(printf '%s' "$PAYLOAD" | jq -r '
      (.event_id // .eventId // .eventID // .prompt_id // .promptId
       // .message_id // .messageId // .message.id // empty)
      | if type == "string" or type == "number" then tostring else empty end
    ' 2>/dev/null) || EVENT_ID=
  fi
  if [ -z "$SESSION_ID" ]; then
    SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '
      (.session_id // .sessionId // .sessionID // .thread_id // .threadId
       // .conversation_id // empty)
      | if type == "string" or type == "number" then tostring else empty end
    ' 2>/dev/null) || SESSION_ID=
  fi
fi

[ -n "$PROMPT" ] || exit 0

# Skip Firstmate operational / injected inputs so adapters never recurse into
# their own session-start, turn-end, or away-mode messages.
# shellcheck disable=SC2034 # Set by the shared classifier through its output-name argument.
op_kind=
if fm_operational_input_kind "$PROMPT" op_kind 2>/dev/null || \
   fm_operational_input_classify "$PROMPT" op_kind 2>/dev/null; then
  exit 0
fi
case "$PROMPT" in
  "$FM_OPERATIONAL_PREFIX"*|"$FM_FROMFIRST_MARK"*) exit 0 ;;
esac

# Short caption for the focus record; full prompt text is not stored.
if [ -z "$SUMMARY" ]; then
  SUMMARY=$(printf '%s' "$PROMPT" | tr '\n\r\t' '   ' | cut -c1-160)
fi

# Fingerprint only a vendor-identified submission so later identical prompts
# remain distinct while a retry of the same callback is idempotent.
FINGERPRINT=
if [ -n "$EVENT_ID" ] && command -v shasum >/dev/null 2>&1; then
  FINGERPRINT=$(printf '%s\n%s\n%s' "$HARNESS" "$SESSION_ID" "$EVENT_ID" | shasum -a 256 2>/dev/null | awk '{print $1}')
elif [ -n "$EVENT_ID" ] && command -v sha256sum >/dev/null 2>&1; then
  FINGERPRINT=$(printf '%s\n%s\n%s' "$HARNESS" "$SESSION_ID" "$EVENT_ID" | sha256sum 2>/dev/null | awk '{print $1}')
fi

args=(switch --state-dir "$STATE" --owner-kind "$OWNER_KIND" --summary "$SUMMARY")
[ -n "$TASK_ID" ] && args+=(--task-id "$TASK_ID")
[ -n "$PROJECT" ] && args+=(--project "$PROJECT")
[ -n "$RESUME_KIND" ] && args+=(--resume-kind "$RESUME_KIND")
[ -n "$RESUME_POINTER" ] && args+=(--resume-pointer "$RESUME_POINTER")
[ -n "$FINGERPRINT" ] && args+=(--fingerprint "$FINGERPRINT")
# Use only a real vendor session identity as a resume pointer.
if [ -z "$RESUME_KIND" ] && [ -z "$RESUME_POINTER" ] && \
   [ -n "$HARNESS" ] && [ -n "$SESSION_ID" ]; then
  args+=(--resume-kind "$HARNESS-session" --resume-pointer "$SESSION_ID")
fi

# NEVER let a focus failure affect the harness exit path. Bound contention at
# this adapter boundary while leaving explicit operator calls free to wait.
FM_FOCUS_LOCK_TRIES=3 \
  "$SCRIPT_DIR/fm-focus.sh" "${args[@]}" >/dev/null 2>&1 || true
exit 0
