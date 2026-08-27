#!/usr/bin/env bash
# Retire ONE finished task's orphaned status record: a state/<id>.status log with
# no state/<id>.meta behind it.
# Usage: fm-status-gc.sh <id>
#
# Teardown removes a task's status log only through status_retire_presentation_task
# and only after every other record is gone, so a status log that outlives its meta
# is a leak a completed teardown cannot produce. Left in place it keeps costing
# supervision: the heartbeat backstop rescans every *.status regardless of meta, so
# a terminal line goes on resurfacing as captain-relevant forever, and the
# presentation cursor keeps a row for a task nothing owns.
#
# This is a janitor, never a teardown. It touches no worktree, project, or
# data/<id>/, and it retires nothing unless the record set is exactly that leak:
#
#   1. This home's task-set lock is free, and is then HELD through retirement, so
#      a spawn cannot publish a record for this id while the gates below are
#      being evaluated (bin/fm-wake-lib.sh's fm_task_set_lock_path owns why).
#   2. No state/<id>.meta - re-checked immediately before deletion.
#   3. No other record of this task anywhere in this home's state directory.
#      TOP LEVEL is resolved by name: every family is enumerated below from its
#      writer rather than matched with a glob, because a glob over `<id>.*` and
#      `.<id>.*` misses every id-SUFFIXED family (`.lease-<id>` and friends) and
#      over-matches a sibling id's records. SUBDIRECTORIES are resolved by BOTH
#      name and CONTENTS, and need no family entry at all: several nested records
#      are keyed by a correlation id, a source id, or a watch id and bind to a
#      task only inside the file (`pending-replies/<corr>` carries `task_id=` and
#      `parent_status=`, naming the very log this would delete), while others are
#      task-keyed in directories no family names (`remote-replies/<id>.caught-up`,
#      `handoff/<id>.outbox.md`). Enumerating directories one at a time is what
#      let both shapes through. Anything unrecognized that names this task is a
#      refusal, so a family added later fails closed rather than being retired
#      around, and a symlinked subdirectory refuses rather than being skipped.
#   4. No per-task temp root /tmp/fm-<id>. Spawn creates it (bin/fm-spawn.sh) and
#      teardown removes it, so a surviving temp root is durable evidence that a
#      spawn ran for this id and its cleanup never finished.
#   5. The last recorded line is `done:` or `failed:` (not `needs-decision:` or
#      `blocked:`, which are unfinished work), and the log holds no open decision.
#
# What this cannot prove: the originating recipe also asked for "no live backend
# window". Without a meta there is no recorded endpoint to probe, and no backend
# exposes id-keyed window enumeration, so no positive endpoint check is available
# here. Gate 4 is the substitute: a surviving temp root is durable evidence that
# a spawn ran for this id and its teardown never completed, so it refuses while
# that trace is present. It is a strong signal of unfinished cleanup rather than a
# complete endpoint check - a spawn that died before its temp root was created, or
# an endpoint created outside firstmate's own spawn path, leaves no temp root -
# which is a residual no meta-less check could see either.
#
# On success it retires, through their owners: the status log, the task's
# open-decisions cursor, its presentation-cursor row (under the presentation lock,
# bin/fm-classify-lib.sh), and the watcher's per-task notification markers.
# The watcher's other markers are keyed by ENDPOINT, not by task id
# (`.hash-<window>`, `.stale-<window>`, ...), so they cannot be resolved here and
# are never removed. Where a window name embeds the task id, such a leftover is
# an unrecognized record that names this task and therefore REFUSES - clear it,
# or let the watcher's own reset path clear it, and rerun.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-push-transition-lib.sh
. "$SCRIPT_DIR/fm-push-transition-lib.sh"

# Every per-task record family this home can hold, as "<prefix>|<suffix>" with the
# task id between them. Sourced from the writers, not from prose: fm-spawn.sh,
# fm-teardown.sh, fm-control-lib.sh, fm-pr-lib.sh, fm-check-register.sh,
# fm-lease-lib.sh, fm-wake-lib.sh, fm-backlog-handoff.sh, fm-secondmate-*.sh.
# Keep this list in step with AGENTS.md section 2's state ledger when a family is
# added; an unlisted family still refuses through the unrecognized-record check.
fm_gc_record_families() {
  cat <<'EOF'
|.meta
|.status
|.turn-ended
|.busy-gen
|.check.sh
|.check-trust
|.pr-poll
|.pr-poll-registration
|.pr-poll-retirement
|.pr-poll-merge-notified
|.inbox
|.herdr-presentation
|.grok-turnend-token
|.kimi-turnend-token
|.muse-session
|.muse-session-current
|.cursor-session
|.pi-ext.ts
|.playbot-outbox.json
|.playbot-route.json
|.control-relaunch
|.control-relaunch.note
|.control-relaunch.meta-prior
|.control-relaunch.brief-prior
.|.open-decisions-cursor
.lease-|
.control-|.lock
.meta-|.lock
.spawn-|.lock
.registry-|.lock
.remote-inherit-|.lock
.remote-reply-lifecycle-|.lock
.backlog-handoff-|.lock
.remote-reply-ingest-|.lock
.backlog-handoff-|.wake-pending
.backlog-handoff-|.wake-retiring
.remote-handoff-|.generation
.secondmate-wake-stall-|
.hb-surfaced-|
.seen-|_status
.seen-|_turn-ended
.playbot-dispatch/|.txn
.secondmate-wake-stall-receipts/|
EOF
}

# The directory components of any nested family above, so the scan visits them
# too. A per-task record that lives one level down is exactly as disqualifying as
# a top-level one: `.playbot-dispatch/<id>.txn` carries the workspace and thread
# identities of a Playbot dispatch, is written BEFORE both the temp root and the
# meta, and is deliberately RETAINED when abort cleanup cannot prove the endpoint
# is gone (bin/fm-spawn.sh's playbot_txn_path and its abort path).
fm_gc_record_family_dirs() {
  while IFS= read -r family; do
    case "$family" in */*) ;; *) continue ;; esac
    printf '%s\n' "${family%%/*}"
  done <<EOF
$FM_GC_FAMILIES
EOF
}

# The task id a recognized record name belongs to, or empty when the name matches
# no known family. Longest prefix+suffix wins, so `<id>.pr-poll-registration` is
# never mistaken for `<id>.pr-poll`'s task.
fm_gc_owner_id() {  # <record-name>
  local name=$1 family prefix suffix mid best='' best_len=-1 len
  while IFS= read -r family; do
    [ -n "$family" ] || continue
    prefix=${family%%|*}
    suffix=${family#*|}
    case "$name" in "$prefix"*"$suffix") ;; *) continue ;; esac
    mid=${name#"$prefix"}
    mid=${mid%"$suffix"}
    [ -n "$mid" ] || continue
    len=$(( ${#prefix} + ${#suffix} ))
    if [ "$len" -gt "$best_len" ]; then
      best=$mid
      best_len=$len
    fi
  done <<EOF
$FM_GC_FAMILIES
EOF
  printf '%s' "$best"
}

# 0 when <record-name> is one of the names this janitor retires.
fm_gc_is_retirable() {  # <record-name>
  printf '%s\n' "$RETIRABLE" | grep -Fxq -- "$1"
}

# 0 when <record-name> is a home-wide artifact rather than a per-task record.
# Task ids may legally be words that appear in those names (`lock`, `task`, `set`,
# `watch` all pass fm_pr_task_id_valid), and this janitor holds the task-set lock
# itself while it scans, so without this the catch-all below would report the
# janitor's own lock as a surviving record of the task and park the leak forever.
fm_gc_is_home_wide() {  # <record-name>
  case "$1" in
    # Reached only for a record that resolved to NO task, because the top-level
    # scan computes the owner first. Every per-task lock this repo writes
    # (.control-<id>.lock, .meta-<id>.lock, .spawn-<id>.lock,
    # .remote-reply-ingest-<id>.lock, ...) is enumerated in the family table and
    # is claimed there before this test runs, so what remains is home-wide by
    # construction. Without this, a task whose id is an ordinary word (`lock`,
    # `watch`, `queue`, `focus`) could never be retired, because the catch-all
    # read every home-wide lock in the home as that task's record - including the
    # one this janitor holds while it scans.
    *.lock|*.lock.*|*.log) return 0 ;;
    .wake-queue|.wake-queue.*|.status-presentation-cursor) return 0 ;;
    .last-watcher-beat|.watcher-down|.afk|.focus.json|.heartbeat-streak) return 0 ;;
    .watch-downtime|.watch-deliveries.*|.branch-session|.branch-mirror-cursor) return 0 ;;
  esac
  return 1
}

# 0 when <record-name> names <id> as a delimiter-bounded token. Used only for
# names no known family claims, so an unrecognized record referencing this task
# refuses instead of being retired around.
fm_gc_references_task() {  # <record-name> <id>
  local name=$1 id=$2
  # `/` is a delimiter as much as `.`, `-`, and `_`: a nested name like
  # `.playbot-dispatch/<id>.workspace` carries the id immediately after a slash,
  # and leaving `/` out let exactly that shape fail OPEN.
  case "$name" in
    "$id"|"$id"[._/-]*|*[._/-]"$id"|*[._/-]"$id"[._/-]*) return 0 ;;
  esac
  return 1
}

# Names of home-wide records that are shaped like a per-task status log. Retiring
# one would delete a home-wide record, not an orphan, so the id itself refuses.
fm_gc_is_home_wide_status_id() {  # <id>
  case "$1" in
    parent-replies) return 0 ;;
  esac
  return 1
}

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "${1-}"; then
  echo "usage: fm-status-gc.sh <id>" >&2
  exit 2
fi

ID=$1
if fm_gc_is_home_wide_status_id "$ID"; then
  echo "REFUSED: state/$ID.status is a home-wide record, not a task's status log." >&2
  exit 1
fi
STATUS="$STATE/$ID.status"
TASK_TMP="/tmp/fm-$ID"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }

# The names this janitor is allowed to retire, resolved through the same owners
# that write them so an id containing `.` cannot drift from the real filenames.
# Everything else in state/ that belongs to this task is a refusal.
FM_GC_FAMILIES=$(fm_gc_record_families)
RETIRABLE="$ID.status
.$ID.open-decisions-cursor
$(basename "$(_hb_surfaced_path "$ID")")
$(basename "$(fm_wake_signal_seen_path "$STATE" "$STATUS")")
$(basename "$(fm_wake_signal_seen_path "$STATE" "$STATE/$ID.turn-ended")")"

TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || {
  echo "error: could not resolve the task-set lock for $STATE" >&2
  exit 1
}
TASK_SET_LOCK_HELD=0
gc_release_locks() {
  local status=$?
  if [ "$TASK_SET_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TASK_SET_LOCK" || true
    TASK_SET_LOCK_HELD=0
  fi
  return "$status"
}
trap gc_release_locks EXIT
if ! fm_lock_try_acquire "$TASK_SET_LOCK"; then
  echo "REFUSED: this home's task set is locked by another operation (a spawn or teardown is running); rerun once it finishes." >&2
  exit 1
fi
TASK_SET_LOCK_HELD=1

if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
  echo "REFUSED: task $ID still has a task record; this is a live task, and cleanup belongs to bin/fm-teardown.sh." >&2
  exit 1
fi
[ -f "$STATUS" ] && [ -r "$STATUS" ] && [ ! -L "$STATUS" ] \
  || { echo "REFUSED: $STATUS is not a readable status log." >&2; exit 1; }

# Any other record of this task means a teardown that did not finish (or a task
# still being served), so name what survives and let the operator reconcile it
# rather than erasing this task's last remaining trace of the work.
SURVIVING=
UNRECOGNIZED=
for entry in "$STATE"/* "$STATE"/.*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  name=${entry##*/}
  case "$name" in .|..) continue ;; esac
  if fm_gc_is_retirable "$name"; then continue; fi
  # Task binding is resolved FIRST, and it wins. A record that belongs to a task
  # is that task's whatever else its name resembles; only a record that resolves
  # to no task at all can be a home-wide artifact. Testing the home-wide shape
  # first exempted every per-task lock before its owner was ever computed, which
  # made the enumerated lock families dead entries and let a HELD
  # .remote-reply-ingest-<id>.lock - whose holder appends to state/<id>.status
  # without taking the task-set lock - pass while the log was being written.
  owner=$(fm_gc_owner_id "$name")
  if [ -n "$owner" ]; then
    [ "$owner" = "$ID" ] || continue
    SURVIVING="${SURVIVING:+$SURVIVING }$name"
    continue
  fi
  if fm_gc_is_home_wide "$name"; then continue; fi
  if fm_gc_references_task "$name" "$ID"; then
    UNRECOGNIZED="${UNRECOGNIZED:+$UNRECOGNIZED }$name"
  fi
done

# Subdirectory records cannot be resolved by name alone: several are keyed by a
# correlation id, a source id, or a watch id and bind to a task only inside the
# file (`pending-replies/<corr>` carries `task_id=` and `parent_status=`, which is
# the very log this janitor deletes - teardown already refuses on exactly that
# evidence). Others ARE task-keyed but sit in directories no family names
# (`remote-replies/<id>.caught-up`, `handoff/<id>.outbox.md`). Enumerating
# directories one at a time is what let both classes through, so every
# subdirectory is scanned by BOTH tests, and neither needs the family table:
# a nested name that carries the task id as a delimiter-bounded token, or any
# file whose contents carry it that way, is a refusal.
#
# A symlinked subdirectory REFUSES rather than being skipped. Skipping was
# fail-open: a symlinked family directory hid the record it was added to find,
# while the writers that follow it kept working through the link.
GC_ID_RE=$(printf '%s' "$ID" | sed 's/[.[\*^$]/\\&/g')
for entry in "$STATE"/*/ "$STATE"/.*/; do
  dir=${entry%/}
  [ -e "$dir" ] || [ -L "$dir" ] || continue
  name=${dir##*/}
  case "$name" in .|..) continue ;; esac
  # Home-wide artifacts are not per-task records, and the lock this janitor holds
  # is itself a symlink to its owner directory - it must not trip the check below.
  if fm_gc_is_home_wide "$name"; then continue; fi
  if [ -L "$dir" ]; then
    UNRECOGNIZED="${UNRECOGNIZED:+$UNRECOGNIZED }$name/ (symlinked directory, not followed)"
    continue
  fi
  [ -d "$dir" ] || continue
  for nested in "$dir"/* "$dir"/.*; do
    [ -e "$nested" ] || [ -L "$nested" ] || continue
    nested_name=${nested##*/}
    case "$nested_name" in .|..) continue ;; esac
    fm_gc_references_task "$name/$nested_name" "$ID" || continue
    SURVIVING="${SURVIVING:+$SURVIVING }$name/$nested_name"
  done
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    hit=${hit#"$STATE/"}
    case " $SURVIVING " in *" $hit "*) continue ;; esac
    SURVIVING="${SURVIVING:+$SURVIVING }$hit (names this task)"
  done <<EOF
$(grep -r -l -I -E "(^|[^A-Za-z0-9._-])$GC_ID_RE([^A-Za-z0-9._-]|\$)" "$dir" 2>/dev/null || true)
EOF
done
if [ -n "$SURVIVING" ] || [ -n "$UNRECOGNIZED" ]; then
  echo "REFUSED: task $ID still has other records: ${SURVIVING:-}${SURVIVING:+ }${UNRECOGNIZED:-}" >&2
  [ -z "$UNRECOGNIZED" ] || echo "Records this janitor does not recognize are refused rather than retired around: $UNRECOGNIZED" >&2
  echo "That is an unfinished cleanup, not an orphaned status log; reconcile those records first." >&2
  exit 1
fi

if [ -e "$TASK_TMP" ] || [ -L "$TASK_TMP" ]; then
  echo "REFUSED: task $ID still has its per-task temp root at $TASK_TMP." >&2
  echo "Spawn creates it before the worker starts and teardown removes it last, so a worker was started here and cleanup never finished." >&2
  exit 1
fi

LAST=$(last_status_line "$STATUS")
case "$(status_line_verb "$LAST")" in
  done|failed) ;;
  *)
    echo "REFUSED: task $ID's last recorded line is not a finished one: ${LAST:-<empty>}" >&2
    exit 1
    ;;
esac

OPEN=$(status_open_decisions "$STATUS")
if [ -n "$OPEN" ]; then
  echo "REFUSED: task $ID still has an unanswered decision in its record:" >&2
  printf '%s\n' "$OPEN" >&2
  exit 1
fi

# Last word before deletion: the task-set lock has been held since before the
# first gate, so this can only differ if something published outside that lock.
if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
  echo "REFUSED: a task record for $ID appeared while its status log was being checked; nothing was retired." >&2
  exit 1
fi

status_retire_presentation_task "$STATE" "$ID" \
  || { echo "error: could not retire task $ID's status and presentation records" >&2; exit 1; }
rm -f -- "$(_hb_surfaced_path "$ID")" \
  "$(fm_wake_signal_seen_path "$STATE" "$STATUS")" \
  "$(fm_wake_signal_seen_path "$STATE" "$STATE/$ID.turn-ended")" \
  || { echo "error: could not remove task $ID's notification markers" >&2; exit 1; }
echo "retired orphaned status record for task $ID ($LAST)"
