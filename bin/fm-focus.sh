#!/usr/bin/env bash
# fm-focus.sh - single owner of Firstmate's durable primary-focus lifecycle.
#
# Phase 0 contract (minimal): one atomic JSON snapshot under state/ that records
# what the primary is actively driving, a suspended stack with resume pointers,
# and revision + lock semantics. Suspend-before-switch is the load-bearing
# transition: when a new captain prompt arrives while a focus is active, the
# previous nonterminal focus is recorded as suspended BEFORE the new focus
# becomes active.
#
# This script deliberately is NOT a scheduler or second backlog. Backlog
# identity, task selection, spawn, and Playbot adapter work stay with their
# existing owners. Focus entries may carry a Playbot-carried focus as an entry
# (owner_kind=playbot) but never invent occupancy or capacity accounting.
#
# Snapshot path (single atomic file, never partial):
#   state/.focus.json
# Writer lock (mkdir):
#   state/.focus.json.lock
#
# Schema (v1), owned here and by --help:
# {
#   "v": 1,
#   "revision": <non-negative integer>,
#   "active": null | FocusEntry,
#   "suspended": [ FocusEntry, ... ]   # newest first (stack)
# }
#
# FocusEntry:
# {
#   "focus_id": string,                 # stable id for this focus commitment
#   "task_id": string,                  # optional backlog id; empty until known
#   "project": string,                  # optional project name
#   "owner_kind": "primary-direct" | "playbot" | "crew" | "secondmate",
#   "state": "active" | "suspended" | "paused_explicit" | "blocked"
#            | "completed" | "failed",
#   "resume_kind": string,              # e.g. session, task, playbot-thread
#   "resume_pointer": string,           # opaque pointer for the resume path
#   "checkpoint": string,               # short free-form checkpoint note
#   "summary": string,                  # short caption, not a full task body
#   "fingerprint": string,              # optional source fingerprint for idempotency
#   "created_at": <epoch seconds>,
#   "updated_at": <epoch seconds>
# }
#
# Mutation model:
#   - Exactly one writer holds the mkdir lock for a read-modify-write.
#   - Publish is always write-temp then rename; never in-place rewrite.
#   - --expected-revision N is compare-and-swap: refuse (exit 1) when the
#     on-disk revision is not exactly N. Omitted means "advance under the lock".
#   - Never event-source; the snapshot is the whole truth.
#
# Wake emission:
#   After publishing suspend, resume, complete, and switch transitions, attempt
#   one durable wake asynchronously so supervision re-evaluates without delaying
#   the owner command. Phase 0 uses kind=signal key=focus with payload
#   "focus: <transition>". When the Phase 2 advisory refill kind is present on
#   the base, prefer that instead; this branch deliberately does not stack on
#   fm/fm-refill-wake-phase2. Wake failure never changes mutation success.
#
# Exit codes:
#   0 success (including idempotent no-op)
#   1 refused (CAS mismatch, missing focus, invalid state transition, I/O)
#   2 usage
#
# Fail-open rule for harness adapters: the prompt hook (bin/fm-focus-prompt-hook.sh)
# always exits 0 so a focus-record failure never blocks the captain's prompt.
# Callers that need hard refusal (tests, explicit operators) call this script
# directly and honor its exit code.
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE_DEFAULT="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

FOCUS_SCHEMA_V=1
FOCUS_LOCK_STALE_SECS=${FM_FOCUS_LOCK_STALE_SECS:-5}
FOCUS_LOCK_TRIES=${FM_FOCUS_LOCK_TRIES:-40}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-focus.sh show [--state-dir DIR] [--json]
  fm-focus.sh switch [--state-dir DIR] [--expected-revision N]
                     [--focus-id ID] [--task-id T] [--project P]
                     [--owner-kind primary-direct|playbot|crew|secondmate]
                     [--resume-kind K] [--resume-pointer P] [--checkpoint C]
                     [--summary S] [--fingerprint F]
  fm-focus.sh suspend [--state-dir DIR] [--expected-revision N]
                      [--reason suspended|paused_explicit]
  fm-focus.sh resume [--state-dir DIR] [--expected-revision N] [--focus-id ID]
  fm-focus.sh complete [--state-dir DIR] [--expected-revision N]
                       [--outcome completed|failed]
  fm-focus.sh set-checkpoint [--state-dir DIR] [--expected-revision N]
                             --checkpoint C

Owner of state/.focus.json (atomic snapshot, CAS revision, suspend-before-switch).

Schema (v1):
  {
    "v": 1,
    "revision": <non-negative integer>,
    "active": null | FocusEntry,
    "suspended": [ FocusEntry, ... ]
  }

FocusEntry:
  {
    "focus_id": string,
    "task_id": string,
    "project": string,
    "owner_kind": "primary-direct" | "playbot" | "crew" | "secondmate",
    "state": "active" | "suspended" | "paused_explicit" | "blocked"
             | "completed" | "failed",
    "resume_kind": string,
    "resume_pointer": string,
    "checkpoint": string,
    "summary": string,
    "fingerprint": string,
    "created_at": <epoch seconds>,
    "updated_at": <epoch seconds>
  }

Mutation contract:
  - Exactly one writer holds the mkdir lock for a read-modify-write.
  - Publish is always write-temp then rename; never in-place rewrite.
  - --expected-revision N refuses with exit 1 unless the on-disk revision is N.
    Without it, the command advances the revision while holding the lock.
  - switch records the previous nonterminal active focus as suspended before
    making the new focus active.
  - The atomic snapshot is the whole truth; this owner never event-sources.
  - Wake delivery is best effort after publish and never changes mutation success.

Exit codes: 0 success or idempotent no-op; 1 refusal; 2 usage.
EOF
}

die_usage() {
  usage >&2
  exit 2
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-focus: jq is required\n' >&2
    return 1
  }
}

focus_path() {  # <state-dir>
  printf '%s/.focus.json' "$1"
}

focus_lock_path() {  # <state-dir>
  printf '%s/.focus.json.lock' "$1"
}

empty_snapshot() {
  printf '{"v":%s,"revision":0,"active":null,"suspended":[]}\n' "$FOCUS_SCHEMA_V"
}

now_epoch() {
  date +%s
}

mint_focus_id() {
  printf 'f%s.%s.%s' "$(date +%s)" "$$" "${RANDOM:-0}"
}

owner_kind_ok() {
  case "$1" in
    primary-direct|playbot|crew|secondmate) return 0 ;;
    *) return 1 ;;
  esac
}

nonterminal_state() {
  case "$1" in
    active|suspended|paused_explicit|blocked) return 0 ;;
    *) return 1 ;;
  esac
}

# Acquire the writer lock. Breaks a stale lock after FOCUS_LOCK_STALE_SECS.
lock_acquire() {  # <lock-path>
  local lock=$1 tries=0 now mtime age
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$FOCUS_LOCK_TRIES" ]; then
      now=$(now_epoch)
      mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")
      age=$((now - mtime))
      if [ "$age" -ge "$FOCUS_LOCK_STALE_SECS" ]; then
        rmdir "$lock" 2>/dev/null || rm -rf "$lock" 2>/dev/null || true
        mkdir "$lock" 2>/dev/null && return 0
      fi
      printf 'fm-focus: lock timeout\n' >&2
      return 1
    fi
    sleep 0.05
  done
  return 0
}

lock_release() {  # <lock-path>
  rmdir "$1" 2>/dev/null || true
}

# Read the snapshot under the lock (caller holds lock). Missing file -> empty.
read_snapshot() {  # <path> -> stdout
  local path=$1
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    cat "$path" 2>/dev/null || empty_snapshot
  else
    empty_snapshot
  fi
}

# Atomic replace under the lock. Refuses symlinks and partial writes.
write_snapshot() {  # <path> <json-string>
  local path=$1 json=$2 tmp dir
  dir=$(dirname -- "$path")
  [ -d "$dir" ] || {
    printf 'fm-focus: state dir missing: %s\n' "$dir" >&2
    return 1
  }
  if [ -L "$path" ]; then
    printf 'fm-focus: refusing to write through symlink: %s\n' "$path" >&2
    return 1
  fi
  tmp="$path.tmp.$$"
  # Validate JSON before publishing.
  printf '%s\n' "$json" | jq -c -e . >/dev/null 2>&1 || {
    printf 'fm-focus: refusing to publish invalid JSON\n' >&2
    return 1
  }
  printf '%s\n' "$json" > "$tmp" || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path" || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  return 0
}

# Prefer Phase 2 refill kind when the queue accepts it; otherwise signal.
# Rebinds queue paths to the mutation's --state-dir so hermetic tests and
# multi-home processes never write the wrong home's queue.
emit_focus_wake() {  # <transition>
  local transition=$1
  (
    mkdir -p "$STATE" 2>/dev/null || exit 0
    FM_WAKE_QUEUE="$STATE/.wake-queue"
    FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
    export FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
    if fm_wake_append_try refill focus "focus: $transition"; then
      exit 0
    fi
    fm_wake_append_try signal focus "focus: $transition" || true
  ) </dev/null >/dev/null 2>&1 &
  return 0
}

# Build a FocusEntry JSON object from shell vars.
build_entry_json() {
  # Uses environment: FOCUS_ID TASK_ID PROJECT OWNER_KIND FSTATE RESUME_KIND
  # RESUME_POINTER CHECKPOINT SUMMARY FINGERPRINT CREATED UPDATED
  jq -nc \
    --arg focus_id "${FOCUS_ID}" \
    --arg task_id "${TASK_ID:-}" \
    --arg project "${PROJECT:-}" \
    --arg owner_kind "${OWNER_KIND}" \
    --arg state "${FSTATE}" \
    --arg resume_kind "${RESUME_KIND:-}" \
    --arg resume_pointer "${RESUME_POINTER:-}" \
    --arg checkpoint "${CHECKPOINT:-}" \
    --arg summary "${SUMMARY:-}" \
    --arg fingerprint "${FINGERPRINT:-}" \
    --argjson created_at "${CREATED}" \
    --argjson updated_at "${UPDATED}" \
    '{
      focus_id: $focus_id,
      task_id: $task_id,
      project: $project,
      owner_kind: $owner_kind,
      state: $state,
      resume_kind: $resume_kind,
      resume_pointer: $resume_pointer,
      checkpoint: $checkpoint,
      summary: $summary,
      fingerprint: $fingerprint,
      created_at: $created_at,
      updated_at: $updated_at
    }'
}

# Apply CAS check. Snap is the current JSON. Returns 0 if ok to write next rev.
cas_check() {  # <snap-json> <expected-or-empty> -> sets NEXT_REV
  local snap=$1 expected=$2 cur
  cur=$(printf '%s' "$snap" | jq -r '.revision // 0')
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  if [ -n "$expected" ]; then
    case "$expected" in *[!0-9]*) 
      printf 'fm-focus: invalid --expected-revision\n' >&2
      return 1
      ;;
    esac
    if [ "$cur" -ne "$expected" ]; then
      printf 'fm-focus: CAS refused: expected revision %s, have %s\n' "$expected" "$cur" >&2
      return 1
    fi
  fi
  NEXT_REV=$((cur + 1))
  return 0
}

cmd_show() {
  local json=0 snap path
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --state-dir) STATE=${2:-}; shift 2 || die_usage ;;
      --state-dir=*) STATE=${1#--state-dir=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die_usage ;;
    esac
  done
  STATE=${STATE:-$STATE_DEFAULT}
  path=$(focus_path "$STATE")
  require_jq || exit 1
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    snap=$(cat "$path")
  else
    snap=$(empty_snapshot)
  fi
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$snap" | jq -c .
  else
    printf '%s\n' "$snap" | jq -r '
      "revision=\(.revision // 0)",
      (if .active == null then "active=(none)"
       else "active=\(.active.focus_id) state=\(.active.state) owner=\(.active.owner_kind) task=\(.active.task_id // "") summary=\(.active.summary // "")"
       end),
      "suspended=\((.suspended // []) | length)"
    '
  fi
}

# Shared option parser for mutation commands. Sets STATE, EXPECTED, and entry fields.
parse_common_opts() {
  STATE=$STATE_DEFAULT
  EXPECTED=
  FOCUS_ID=
  TASK_ID=
  PROJECT=
  OWNER_KIND=primary-direct
  RESUME_KIND=
  RESUME_POINTER=
  CHECKPOINT=
  SUMMARY=
  FINGERPRINT=
  REASON=suspended
  OUTCOME=completed
  while [ $# -gt 0 ]; do
    case "$1" in
      --state-dir) STATE=${2:-}; shift 2 || die_usage ;;
      --state-dir=*) STATE=${1#--state-dir=}; shift ;;
      --expected-revision) EXPECTED=${2:-}; shift 2 || die_usage ;;
      --expected-revision=*) EXPECTED=${1#--expected-revision=}; shift ;;
      --focus-id) FOCUS_ID=${2:-}; shift 2 || die_usage ;;
      --focus-id=*) FOCUS_ID=${1#--focus-id=}; shift ;;
      --task-id) TASK_ID=${2:-}; shift 2 || die_usage ;;
      --task-id=*) TASK_ID=${1#--task-id=}; shift ;;
      --project) PROJECT=${2:-}; shift 2 || die_usage ;;
      --project=*) PROJECT=${1#--project=}; shift ;;
      --owner-kind) OWNER_KIND=${2:-}; shift 2 || die_usage ;;
      --owner-kind=*) OWNER_KIND=${1#--owner-kind=}; shift ;;
      --resume-kind) RESUME_KIND=${2:-}; shift 2 || die_usage ;;
      --resume-kind=*) RESUME_KIND=${1#--resume-kind=}; shift ;;
      --resume-pointer) RESUME_POINTER=${2:-}; shift 2 || die_usage ;;
      --resume-pointer=*) RESUME_POINTER=${1#--resume-pointer=}; shift ;;
      --checkpoint) CHECKPOINT=${2:-}; shift 2 || die_usage ;;
      --checkpoint=*) CHECKPOINT=${1#--checkpoint=}; shift ;;
      --summary) SUMMARY=${2:-}; shift 2 || die_usage ;;
      --summary=*) SUMMARY=${1#--summary=}; shift ;;
      --fingerprint) FINGERPRINT=${2:-}; shift 2 || die_usage ;;
      --fingerprint=*) FINGERPRINT=${1#--fingerprint=}; shift ;;
      --reason) REASON=${2:-}; shift 2 || die_usage ;;
      --reason=*) REASON=${1#--reason=}; shift ;;
      --outcome) OUTCOME=${2:-}; shift 2 || die_usage ;;
      --outcome=*) OUTCOME=${1#--outcome=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *)
        # Leave remaining for caller if needed; unknown here is usage.
        printf 'fm-focus: unknown argument: %s\n' "$1" >&2
        die_usage
        ;;
    esac
  done
  [ -n "$STATE" ] || die_usage
}

cmd_switch() {
  parse_common_opts "$@"
  owner_kind_ok "$OWNER_KIND" || {
    printf 'fm-focus: invalid --owner-kind\n' >&2
    exit 1
  }
  require_jq || exit 1
  [ -d "$STATE" ] || {
    printf 'fm-focus: state dir not found: %s\n' "$STATE" >&2
    exit 1
  }

  local path lock snap entry next now active_fp active_id
  path=$(focus_path "$STATE")
  lock=$(focus_lock_path "$STATE")
  now=$(now_epoch)

  lock_acquire "$lock" || exit 1
  snap=$(read_snapshot "$path")
  if ! cas_check "$snap" "$EXPECTED"; then
    lock_release "$lock"
    exit 1
  fi

  # Idempotent: same fingerprint already active -> no-op success.
  if [ -n "$FINGERPRINT" ]; then
    active_fp=$(printf '%s' "$snap" | jq -r '.active.fingerprint // empty')
    if [ -n "$active_fp" ] && [ "$active_fp" = "$FINGERPRINT" ]; then
      lock_release "$lock"
      printf '%s\n' "$snap" | jq -c .
      exit 0
    fi
  fi
  if [ -n "$FOCUS_ID" ]; then
    active_id=$(printf '%s' "$snap" | jq -r '.active.focus_id // empty')
    if [ -n "$active_id" ] && [ "$active_id" = "$FOCUS_ID" ]; then
      lock_release "$lock"
      printf '%s\n' "$snap" | jq -c .
      exit 0
    fi
  fi

  [ -n "$FOCUS_ID" ] || FOCUS_ID=$(mint_focus_id)
  CREATED=$now
  UPDATED=$now
  FSTATE=active
  entry=$(build_entry_json) || {
    lock_release "$lock"
    exit 1
  }

  # Suspend current active if nonterminal, then activate new.
  next=$(printf '%s' "$snap" | jq -c \
    --argjson entry "$entry" \
    --argjson rev "$NEXT_REV" \
    --argjson now "$now" \
    --arg schema_v "$FOCUS_SCHEMA_V" '
    . as $s
    | ($s.active) as $a
    | (
        if $a == null then []
        elif ($a.state == "completed" or $a.state == "failed") then []
        else [ ($a | .state = "suspended" | .updated_at = $now) ]
        end
      ) as $push
    | {
        v: ($schema_v | tonumber),
        revision: $rev,
        active: $entry,
        suspended: ($push + ($s.suspended // []))
      }
  ') || {
    lock_release "$lock"
    printf 'fm-focus: switch compose failed\n' >&2
    exit 1
  }

  if ! write_snapshot "$path" "$next"; then
    lock_release "$lock"
    exit 1
  fi
  lock_release "$lock"

  # Wake outside the lock after the durable snapshot is visible.
  emit_focus_wake switched
  printf '%s\n' "$next" | jq -c .
  exit 0
}

cmd_suspend() {
  parse_common_opts "$@"
  case "$REASON" in
    suspended|paused_explicit) ;;
    *) printf 'fm-focus: invalid --reason\n' >&2; exit 1 ;;
  esac
  require_jq || exit 1
  [ -d "$STATE" ] || { printf 'fm-focus: state dir not found: %s\n' "$STATE" >&2; exit 1; }

  local path lock snap next now active_state
  path=$(focus_path "$STATE")
  lock=$(focus_lock_path "$STATE")
  now=$(now_epoch)

  lock_acquire "$lock" || exit 1
  snap=$(read_snapshot "$path")
  if ! cas_check "$snap" "$EXPECTED"; then
    lock_release "$lock"
    exit 1
  fi

  active_state=$(printf '%s' "$snap" | jq -r '.active.state // empty')
  if [ -z "$active_state" ]; then
    # Already idle: idempotent success.
    lock_release "$lock"
    printf '%s\n' "$snap" | jq -c .
    exit 0
  fi
  if ! nonterminal_state "$active_state"; then
    # Terminal active: clear it without stacking.
    next=$(printf '%s' "$snap" | jq -c --argjson rev "$NEXT_REV" '
      .revision = $rev | .active = null
    ') || { lock_release "$lock"; exit 1; }
    if ! write_snapshot "$path" "$next"; then
      lock_release "$lock"
      exit 1
    fi
    lock_release "$lock"
    printf '%s\n' "$next" | jq -c .
    exit 0
  fi

  next=$(printf '%s' "$snap" | jq -c \
    --argjson rev "$NEXT_REV" \
    --argjson now "$now" \
    --arg reason "$REASON" '
    . as $s
    | ($s.active | .state = $reason | .updated_at = $now) as $sus
    | {
        v: $s.v,
        revision: $rev,
        active: null,
        suspended: ([$sus] + ($s.suspended // []))
      }
  ') || { lock_release "$lock"; exit 1; }

  if ! write_snapshot "$path" "$next"; then
    lock_release "$lock"
    exit 1
  fi
  lock_release "$lock"

  emit_focus_wake suspended
  printf '%s\n' "$next" | jq -c .
  exit 0
}

cmd_resume() {
  parse_common_opts "$@"
  require_jq || exit 1
  [ -d "$STATE" ] || { printf 'fm-focus: state dir not found: %s\n' "$STATE" >&2; exit 1; }

  local path lock snap next now target_id
  path=$(focus_path "$STATE")
  lock=$(focus_lock_path "$STATE")
  now=$(now_epoch)
  target_id=$FOCUS_ID

  lock_acquire "$lock" || exit 1
  snap=$(read_snapshot "$path")
  if ! cas_check "$snap" "$EXPECTED"; then
    lock_release "$lock"
    exit 1
  fi

  # If something is already active with the requested id, idempotent.
  if [ -n "$target_id" ]; then
    if [ "$(printf '%s' "$snap" | jq -r '.active.focus_id // empty')" = "$target_id" ]; then
      lock_release "$lock"
      printf '%s\n' "$snap" | jq -c .
      exit 0
    fi
  fi

  # Pick target from suspended stack (head if no id).
  if [ -z "$target_id" ]; then
    target_id=$(printf '%s' "$snap" | jq -r '.suspended[0].focus_id // empty')
  fi
  if [ -z "$target_id" ]; then
    lock_release "$lock"
    printf 'fm-focus: no suspended focus to resume\n' >&2
    exit 1
  fi

  # If active is nonterminal, push it onto the stack first (resume is also a switch).
  next=$(printf '%s' "$snap" | jq -c \
    --argjson rev "$NEXT_REV" \
    --argjson now "$now" \
    --arg tid "$target_id" '
    . as $s
    | ($s.suspended // []) as $stack
    | ([ $stack[] | select(.focus_id == $tid) ] | first) as $found
    | if $found == null then error("missing") else . end
    | ($stack | map(select(.focus_id != $tid))) as $rest
    | (
        if $s.active == null then $rest
        elif ($s.active.state == "completed" or $s.active.state == "failed") then $rest
        else [ ($s.active | .state = "suspended" | .updated_at = $now) ] + $rest
        end
      ) as $new_stack
    | {
        v: $s.v,
        revision: $rev,
        active: ($found | .state = "active" | .updated_at = $now),
        suspended: $new_stack
      }
  ' 2>/dev/null) || {
    lock_release "$lock"
    printf 'fm-focus: suspended focus not found: %s\n' "$target_id" >&2
    exit 1
  }

  if ! write_snapshot "$path" "$next"; then
    lock_release "$lock"
    exit 1
  fi
  lock_release "$lock"

  emit_focus_wake resumed
  printf '%s\n' "$next" | jq -c .
  exit 0
}

cmd_complete() {
  parse_common_opts "$@"
  case "$OUTCOME" in
    completed|failed) ;;
    *) printf 'fm-focus: invalid --outcome\n' >&2; exit 1 ;;
  esac
  require_jq || exit 1
  [ -d "$STATE" ] || { printf 'fm-focus: state dir not found: %s\n' "$STATE" >&2; exit 1; }

  local path lock snap next now
  path=$(focus_path "$STATE")
  lock=$(focus_lock_path "$STATE")
  now=$(now_epoch)

  lock_acquire "$lock" || exit 1
  snap=$(read_snapshot "$path")
  if ! cas_check "$snap" "$EXPECTED"; then
    lock_release "$lock"
    exit 1
  fi

  if [ "$(printf '%s' "$snap" | jq -r 'if .active == null then "none" else "yes" end')" = "none" ]; then
    # Already idle: idempotent.
    lock_release "$lock"
    printf '%s\n' "$snap" | jq -c .
    exit 0
  fi

  # Terminalize active and drop it (not kept on the suspended stack).
  next=$(printf '%s' "$snap" | jq -c \
    --argjson rev "$NEXT_REV" '
    {
      v: .v,
      revision: $rev,
      active: null,
      suspended: (.suspended // [])
    }
  ') || { lock_release "$lock"; exit 1; }

  if ! write_snapshot "$path" "$next"; then
    lock_release "$lock"
    exit 1
  fi
  lock_release "$lock"

  emit_focus_wake "$OUTCOME"
  printf '%s\n' "$next" | jq -c .
  exit 0
}

cmd_set_checkpoint() {
  parse_common_opts "$@"
  [ -n "$CHECKPOINT" ] || {
    printf 'fm-focus: --checkpoint is required\n' >&2
    exit 2
  }
  require_jq || exit 1
  [ -d "$STATE" ] || { printf 'fm-focus: state dir not found: %s\n' "$STATE" >&2; exit 1; }

  local path lock snap next now
  path=$(focus_path "$STATE")
  lock=$(focus_lock_path "$STATE")
  now=$(now_epoch)

  lock_acquire "$lock" || exit 1
  snap=$(read_snapshot "$path")
  if ! cas_check "$snap" "$EXPECTED"; then
    lock_release "$lock"
    exit 1
  fi
  if [ "$(printf '%s' "$snap" | jq -r 'if .active == null then "none" else "yes" end')" = "none" ]; then
    lock_release "$lock"
    printf 'fm-focus: no active focus to checkpoint\n' >&2
    exit 1
  fi

  next=$(printf '%s' "$snap" | jq -c \
    --argjson rev "$NEXT_REV" \
    --argjson now "$now" \
    --arg cp "$CHECKPOINT" '
    .revision = $rev
    | .active.checkpoint = $cp
    | .active.updated_at = $now
  ') || { lock_release "$lock"; exit 1; }

  if ! write_snapshot "$path" "$next"; then
    lock_release "$lock"
    exit 1
  fi
  lock_release "$lock"
  printf '%s\n' "$next" | jq -c .
  exit 0
}

CMD=${1:-}
[ -n "$CMD" ] || die_usage
shift || true

case "$CMD" in
  show) cmd_show "$@" ;;
  switch) cmd_switch "$@" ;;
  suspend) cmd_suspend "$@" ;;
  resume) cmd_resume "$@" ;;
  complete) cmd_complete "$@" ;;
  set-checkpoint) cmd_set_checkpoint "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) die_usage ;;
esac
