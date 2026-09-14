#!/usr/bin/env bash
# Retire ONE finished task's orphaned status record: a state/<id>.status log with
# no state/<id>.meta behind it.
# Usage: fm-status-gc.sh <id> [--finish-cleanup]
#
# Teardown removes a task's status log only through
# status_retire_presentation_task as part of writer-owned record retirement, so
# a status log that outlives its meta is evidence of interrupted cleanup. Left in
# place it keeps costing supervision: the heartbeat backstop rescans every
# *.status regardless of meta, so a terminal line goes on resurfacing as
# captain-relevant forever, and the presentation cursor keeps a row for a task
# nothing owns.
#
# This is a janitor, never a teardown. It touches no worktree, project, or
# data/<id>/. Without --finish-cleanup it retires nothing unless the record set
# is exactly that leak; the flag permits only the writer-owned interrupted-cleanup
# path documented below. Both modes require these gates:
#
#   1. This home's task-set lock is free, and is then HELD through retirement, so
#      a spawn cannot publish a record for this id while the gates below are
#      being evaluated (bin/fm-wake-lib.sh's fm_task_set_lock_path owns why).
#   2. No state/<id>.meta - re-checked immediately before deletion.
#   3. By default, no other record of this task anywhere in this home's state
#      directory. With --finish-cleanup, every survivor must be a recognized
#      family with writer-owned retirement, and gates 4 and 5 pass before any
#      survivor is retired.
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
#   6. No LIVE backend endpoint labeled for this task. Without a meta there is no
#      recorded endpoint to target, so this janitor asks every backend inventory
#      it can read whether an endpoint labeled fm-<id> is live
#      (bin/fm-backend.sh's fm_backend_task_endpoints_live owns the probe, both
#      in this plain path and inside --finish-cleanup, before anything is
#      retired). Absence of /tmp/fm-<id> is NOT proof the endpoint is gone: a
#      window created outside spawn's own path leaves no temp root. A live
#      labeled endpoint, or an inventory that cannot be read positively, is a
#      refusal - neither may ever be treated as proof of endpoint death. The
#      remaining hole is documented there too: backends without an id-keyed
#      inventory listing (zellij, orca, cmux, playbot) cannot be positively
#      probed, so on a home whose tasks run on one of those, this janitor cannot
#      establish endpoint death and refuses instead of retiring around it.
#
# --finish-cleanup is the forward path for an interrupted cleanup: when gate 3
# refuses because recognized per-task records survive next to the status log,
# teardown cannot run without the meta this record lacks and this janitor must
# not erase the last trace of unfinished work. With the flag, and only after
# this janitor's own terminal gates (4, 5, and 6) have
# passed first so no record of unfinished work is ever destroyed, every
# surviving family is retired through its own writer rather than by hand
# (bin/fm-task-records-retire-lib.sh owns the shared mechanics, and the herdr
# presentation journal goes through bin/fm-herdr-session-cleanup.sh's own orphan
# path); a family with no writer-owned retirement (locks, playbot route/outbox
# records, anything unrecognized) still refuses, naming what is missing. If a
# writer conservatively preserves its record (for example a herdr projection
# that may still be live), the whole finish refuses and nothing is retired, so
# the flag can never recreate a smaller partial cleanup.
#
# On success it retires, through their owners: the presentation-cursor row, the
# task's open-decisions cursor, all four watcher notification marker families,
# and the status log itself - the last two through
# bin/fm-classify-lib.sh's status_retire_presentation_task, which removes the
# status anchor LAST so an interrupted run always converges under a second
# identical invocation (idempotent while the anchor survives; nothing left once
# it is gone). A status anchor that is already ABSENT is only clean when no
# other record of the task remains (a previous run completed, or the id was
# never here): that rerun is a successful no-op. A missing anchor behind any
# surviving record is a partial state no invocation can resume; it is refused
# with the surviving records named.
#
# Marker-ambiguous task ids: legal ids that differ only by '.' vs '_' normalize
# to the SAME watcher marker names, so status_retire_presentation_task refuses
# to retire markers while a colliding sibling task is live (its meta or status
# anchor present). An injective re-encoding of the marker namespace is out of
# scope; the refusal is the contract.
#
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
# shellcheck source=bin/fm-task-records-retire-lib.sh
. "$SCRIPT_DIR/fm-task-records-retire-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

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
|.progress
|.busy-gen
|.busy-state
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
|.omp-ext.ts
|.gemini-settings.json
|.reconcile-nudged
|.playbot-outbox.json
|.playbot-route.json
|.control-relaunch
|.control-relaunch.note
|.control-relaunch.meta-prior
|.control-relaunch.brief-prior
.|.open-decisions-cursor
.|.branch-outcome-index
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
    .status-presentation-lock|.status-presentation-lock.*) return 0 ;;
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

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || ! fm_pr_task_id_valid "${1-}"; then
  echo "usage: fm-status-gc.sh <id> [--finish-cleanup]" >&2
  exit 2
fi
ID=$1
shift
FINISH_CLEANUP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --finish-cleanup) FINISH_CLEANUP=1 ;;
    *)
      echo "usage: fm-status-gc.sh <id> [--finish-cleanup]" >&2
      exit 2
      ;;
  esac
  shift
done
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
# Any other record of this task means a teardown that did not finish (or a task
# still being served), so name what survives and let the operator reconcile it
# rather than erasing this task's last remaining trace of the work. With
# --finish-cleanup, recognized survivors instead take the writer-owned forward
# path documented in the header.
gc_scan_task_records() {
  local entry name owner dir nested nested_name hit
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
}

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

GC_ID_RE=$(printf '%s' "$ID" | sed 's/[.[\*^$]/\\&/g')

if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
  echo "REFUSED: task $ID still has a task record; this is a live task, and cleanup belongs to bin/fm-teardown.sh." >&2
  exit 1
fi
if [ ! -e "$STATUS" ] && [ ! -L "$STATUS" ]; then
  # A missing status anchor is clean ONLY when nothing else of this task
  # remains: either the record was never here or a previous run retired every
  # family through its writer and this invocation is the idempotent rerun.
  # Any surviving record behind a missing anchor is a partial state no
  # invocation can resume (every gate below needs the anchor); name it.
  gc_scan_task_records
  if [ -z "$SURVIVING" ] && [ -z "$UNRECOGNIZED" ]; then
    echo "task $ID has no records to retire (its status anchor is already absent and no other record of the task remains)"
    exit 0
  fi
  echo "REFUSED: $STATUS does not exist, so this cleanup cannot resume, and task $ID still has other records: ${SURVIVING:-}${SURVIVING:+ }${UNRECOGNIZED:-}" >&2
  echo "Reconcile those records by hand; nothing was retired." >&2
  exit 1
fi
[ -f "$STATUS" ] && [ -r "$STATUS" ] && [ ! -L "$STATUS" ] \
  || { echo "REFUSED: $STATUS is not a readable status log." >&2; exit 1; }

# gc_refuse_live_endpoint: a meta-less record cannot name its recorded
# endpoint, so the only positive, writer-owned proof that the endpoint is gone
# is a live inventory read that finds no endpoint labeled for this task
# (bin/fm-backend.sh's fm_backend_task_endpoints_live owns the probe). Absence
# of /tmp/fm-<id> is NOT that proof. Refuse while any labeled endpoint is
# live, and refuse when an inventory cannot be read at all - neither may ever
# be treated as proof of endpoint death.
gc_refuse_live_endpoint() {
  local endpoints
  if ! endpoints=$(fm_backend_task_endpoints_live "$ID"); then
    echo "REFUSED: task $ID's backend inventory could not be read positively, so its endpoint cannot be proven gone; nothing was retired." >&2
    exit 1
  fi
  if [ -n "$endpoints" ]; then
    echo "REFUSED: task $ID still has a live backend endpoint, so this record is a live task, not an orphaned one:" >&2
    printf '%s\n' "$endpoints" >&2
    echo "Retire the endpoint first; nothing was retired." >&2
    exit 1
  fi
}

# Retire this task's herdr presentation journal through its own writer's
# orphan path (bin/fm-herdr-session-cleanup.sh), which closes a provably dead
# projection and also retires a journal whose bound projection reads
# authoritatively gone, preserving everything on any doubt. The journal's own
# writer decides; when it preserves, this janitor refuses so the projection
# can be reconciled first.
gc_retire_herdr_journal() {
  FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1
  # shellcheck source=bin/fm-herdr-session-cleanup.sh
  . "$SCRIPT_DIR/fm-herdr-session-cleanup.sh"
  if ! fm_herdr_cleanup_task_journal "$ID"; then
    echo "REFUSED: task $ID's herdr presentation journal is preserved by its own writer (its projection may still be live, or herdr is unreadable); reconcile that projection first, then re-run with --finish-cleanup." >&2
    return 1
  fi
}

# The --finish-cleanup forward path for a refused gate-3 scan (see the
# header). Runs this janitor's own terminal gates FIRST - no record of
# unfinished work may ever be destroyed - then classifies every survivor, and
# refuses to retire ANYTHING while one family has no writer-owned retirement,
# which would only recreate a smaller partial cleanup. Only then does each
# family go through its writer.
gc_finish_interrupted_cleanup() {
  local name refusal='' turnend_kimi=0 turnend_grok=0 busy=0 prpoll=0 herdr=0 residue=0 gen
  gc_refuse_live_endpoint
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
  for name in $SURVIVING; do
    case "$name" in
      "$ID.kimi-turnend-token") turnend_kimi=1 ;;
      "$ID.grok-turnend-token") turnend_grok=1 ;;
      "$ID.busy-gen"|"$ID.busy-state") busy=1 ;;
      "$ID.check.sh"|"$ID.check-trust"|"$ID.pr-poll"|"$ID.pr-poll-registration"|"$ID.pr-poll-retirement"|"$ID.pr-poll-merge-notified") prpoll=1 ;;
      "$ID.herdr-presentation") herdr=1 ;;
      "$ID.turn-ended"|"$ID.progress"|"$ID.muse-session"|"$ID.muse-session-current"|"$ID.cursor-session"|"$ID.pi-ext.ts"|"$ID.omp-ext.ts"|"$ID.gemini-settings.json"|"$ID.reconcile-nudged"|"$ID.control-relaunch"|"$ID.control-relaunch.note"|"$ID.control-relaunch.meta-prior"|"$ID.control-relaunch.brief-prior"|".$ID.branch-outcome-index"|"$ID.inbox") residue=1 ;;
      *) refusal="${refusal:+$refusal }$name" ;;
    esac
  done
  if [ -n "$refusal" ]; then
    echo "REFUSED: task $ID has records with no writer-owned retirement: $refusal" >&2
    echo "Reconcile those records first; --finish-cleanup retires only families their own writers own." >&2
    exit 1
  fi
  if [ "$turnend_kimi" = 1 ]; then
    fm_task_records_validate_turnend kimi "$STATE" "$ID" \
      || { echo "error: unsafe task $ID kimi turn-end token record; preserving task state" >&2; exit 1; }
  fi
  if [ "$turnend_grok" = 1 ]; then
    fm_task_records_validate_turnend grok "$STATE" "$ID" \
      || { echo "error: unsafe task $ID grok turn-end token record; preserving task state" >&2; exit 1; }
  fi
  if [ "$prpoll" = 1 ]; then
    fm_task_records_validate_pr_poll_cleanup "$STATE" "$ID" \
      || { echo "error: unsafe task $ID PR-check artifacts; preserving task state" >&2; exit 1; }
  fi
  if [ "$busy" = 1 ]; then
    gen=$(fm_task_records_read_busy_gen "$STATE" "$ID") \
      || { echo "error: unsafe task $ID busy-state record; preserving task state" >&2; exit 1; }
    fm_task_records_validate_busy_cleanup "$STATE" "$ID" "$gen" \
      || { echo "error: unsafe task $ID busy-state record; preserving task state" >&2; exit 1; }
  fi
  if [ "$residue" = 1 ]; then
    fm_task_records_validate_residue "$STATE" "$ID" \
      || { echo "error: unsafe task $ID state residue; preserving task state" >&2; exit 1; }
  fi
  status_validate_retire_presentation_task "$STATE" "$ID" \
    || { echo "error: unsafe task $ID status presentation records; preserving task state" >&2; exit 1; }
  if [ "$herdr" = 1 ]; then
    gc_retire_herdr_journal \
      || { echo "error: task $ID's herdr presentation journal could not be retired through its writer" >&2; exit 1; }
  fi
  if [ "$turnend_kimi" = 1 ]; then
    fm_task_records_retire_turnend kimi "$STATE" "$ID" \
      || { echo "error: could not deregister task $ID's kimi turn-end wiring through its control-plane path" >&2; exit 1; }
  fi
  if [ "$turnend_grok" = 1 ]; then
    fm_task_records_retire_turnend grok "$STATE" "$ID" \
      || { echo "error: could not deregister task $ID's grok turn-end wiring through its control-plane path" >&2; exit 1; }
  fi
  if [ "$busy" = 1 ]; then
    fm_task_records_retire_busy "$STATE" "$ID" "$gen" \
      || { echo "error: could not retire task $ID's busy-state record through bin/fm-busy-event.sh" >&2; exit 1; }
  fi
  if [ "$prpoll" = 1 ]; then
    fm_task_records_remove_pr_poll_artifacts "$STATE" "$ID" \
      || { echo "error: could not retire task $ID's PR-check artifacts through bin/fm-pr-lib.sh" >&2; exit 1; }
  fi
  if [ "$residue" = 1 ]; then
    fm_task_records_retire_residue "$STATE" "$ID" \
      || { echo "error: could not retire task $ID's remaining state residue" >&2; exit 1; }
  fi
}

gc_scan_task_records
if { [ -n "$SURVIVING" ] || [ -n "$UNRECOGNIZED" ]; } && [ "$FINISH_CLEANUP" = 1 ] \
   && [ -z "$UNRECOGNIZED" ]; then
  gc_finish_interrupted_cleanup
  # The writers made their own calls; re-scan so whatever a writer preserved
  # is refused below exactly like any other survivor.
  gc_scan_task_records
fi
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

gc_refuse_live_endpoint

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

# Final mutation, owned by bin/fm-classify-lib.sh's status_retire_presentation_task:
# the presentation-cursor row, the open-decisions cursor, all four watcher
# notification marker families, and the status anchor itself, anchor LAST so
# every interruption point converges under a second identical invocation (the
# writer is idempotent while the anchor survives; once it is gone, nothing of
# this task remains).
status_retire_presentation_task "$STATE" "$ID" \
  || { echo "error: could not retire task $ID's status and presentation records" >&2; exit 1; }
echo "retired orphaned status record for task $ID ($LAST)"
