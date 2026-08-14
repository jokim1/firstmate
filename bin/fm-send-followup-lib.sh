#!/usr/bin/env bash
# fm-send-followup-lib.sh - durable per-task follow-up queue for fm-send.
#
# Problem: when fm-send steers a mid-turn worker, harnesses such as OpenCode
# accept Enter into a busy-queue that fires after the current turn. If that turn
# ends in terminal done/failed (or the task is torn down), those already-accepted
# messages still start fresh worker turns - ghost instructions for a finished
# incarnation. Each interrupt only advances the harness queue, so recovery is
# painful and re-triggers work.
#
# Fix: park steers for a busy task selector in a firstmate-owned queue instead of
# the harness busy-queue, and invalidate that queue at delivery time when the
# task's last status verb is done or failed (and on teardown).
#
# Owner path chosen: delivery-time check inside this queue's owner (fm-send).
# Why: it is the smaller fail-closed fix. Every dispatch re-reads status and
# refuses delivery when terminal, so a missed transition cleanup cannot
# resurrect a queued steer. Terminal-transition-only cleanup would fail open
# whenever the transition path was skipped or raced the harness. Teardown still
# invalidates for hygiene; it is not the sole safety gate.
#
# Dispatch contract (exclusive lease / transport fence / ack / release):
#   - lease peeks the head under the queue lock and records lifecycle generation
#     plus exclusive dispatcher identity (pid + process identity). It does NOT
#     remove the message file. A second live owner is refused (exit 3); reclaim
#     requires proving the prior owner is dead or identity-mismatched (pid reuse).
#     Callers that meet exit 3 MUST wait and retry rather than fall through to a
#     fresh send, so FIFO order (old head before new steer) is preserved.
#   - transport_begin records ownership + status fence under the queue lock and
#     aborts early on terminal. It is a setup/precheck, not the last word.
#   - transport_confirm is the final terminal + ownership check, invoked at the
#     last possible instant before backend transport (inside the deliver path
#     immediately before send-keys). A done: observed here aborts without send.
#   - ack removes the leased head only when this dispatcher still owns the lease
#     after confirmed transport.
#   - release drops only this dispatcher's lease marker so a transport failure
#     keeps the item.
#   - invalidate bumps the lifecycle generation and clears the queue under the
#     same lock, serializing terminal cleanup against concurrent dispatch.
#
# Known limitation (captain-accepted, option B 2026-08-13): residual race of
# milliseconds between the final transport_confirm under the queue lock and the
# backend completing send-keys. A done:/failed: line published in that window can
# still reach a worker that just went terminal. Full linearization of status
# publication with transport is explicitly out of scope; shrink the seam by
# keeping the final check as late as possible, do not attempt to lock status
# writers.
#
# Layout (under the home's state dir):
#   <id>.followup-queue/          directory present only while messages wait
#     0000000001                  one file per message, lexical order = FIFO
#     0000000002
#     .lease                      active exclusive lease (see format below)
#   <id>.followup-queue.lock      directory lock (bin/fm-wake-lib.sh), sibling
#   <id>.followup-gen             monotonic lifecycle generation (bumped on
#                                 invalidate); absent means generation 0
# Lease file lines:
#   1: generation at lease time
#   2: basename of the leased message file
#   3: owner pid
#   4: owner identity (fm_pid_identity)
#   5: status fence (byte size) recorded by transport_begin; empty before begin
# Each message file holds the raw text bytes to deliver (no framing). fm-send
# is one-line text, so files are single-line in practice.
#
# Sourced by bin/fm-send.sh and bin/fm-teardown.sh. No side effects on source.
# set -u / set -e safe when callers use the documented returns.

# shellcheck source=bin/fm-classify-lib.sh
_FM_SEND_FOLLOWUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_SEND_FOLLOWUP_LIB_DIR="."
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_SEND_FOLLOWUP_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$_FM_SEND_FOLLOWUP_LIB_DIR/fm-wake-lib.sh"

# 0 when the task's status log is in a completed-work terminal state (done or
# failed). Scans newest-first past trailing resolved-verb lines: a post-terminal
# "resolved [key=...]: ..." (fm-send --resolve-key after done, or a worker
# self-close) must not re-arm ghost delivery. A later non-resolved non-terminal
# line (working:, needs-decision:, ...) is a new incarnation and is live.
# needs-decision and blocked alone stay non-terminal: parked steers remain
# eligible while a decision is still open.
fm_send_followup_is_terminal() {  # <state-dir> <id>
  local state=$1 id=$2 status_file line verb resolve
  status_file="$state/$id.status"
  [ -e "$status_file" ] || return 1
  resolve="${FM_CLASSIFY_RESOLVE_VERB:-${FM_CLASSIFY_RESOLVE_VERB_DEFAULT:-resolved}}"
  # Newest-first over non-blank lines; skip resolved, stop at first other verb.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    verb=$(status_line_verb "$line")
    case "$verb" in
      "$resolve") continue ;;
      done|failed) return 0 ;;
      *) return 1 ;;
    esac
  done < <(awk 'NF { a[++n] = $0 } END { for (i = n; i >= 1; i--) print a[i] }' "$status_file" 2>/dev/null)
  return 1
}

fm_send_followup_dir() {  # <state-dir> <id>
  printf '%s/%s.followup-queue' "$1" "$2"
}

fm_send_followup_lock() {  # <state-dir> <id>
  printf '%s/%s.followup-queue.lock' "$1" "$2"
}

fm_send_followup_gen_file() {  # <state-dir> <id>
  printf '%s/%s.followup-gen' "$1" "$2"
}

# Read the durable lifecycle generation (0 when absent/unreadable).
fm_send_followup_gen_read() {  # <state-dir> <id>
  local f g
  f=$(fm_send_followup_gen_file "$1" "$2")
  g=$(cat "$f" 2>/dev/null || true)
  case "$g" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$g" ;;
  esac
}

# Bump generation under the caller's held queue lock. Fail closed on write error.
fm_send_followup_gen_bump_locked() {  # <state-dir> <id>
  local state=$1 id=$2 f g
  f=$(fm_send_followup_gen_file "$state" "$id")
  g=$(fm_send_followup_gen_read "$state" "$id")
  g=$((g + 1))
  printf '%s\n' "$g" > "$f" || return 1
  return 0
}

# Status fence: byte size of the status file (0 if absent). Any append after
# transport_begin changes the fence so transport_confirm can detect publication.
fm_send_followup_status_fence() {  # <state-dir> <id>
  local f size
  f="$1/$2.status"
  [ -e "$f" ] || { printf '0'; return 0; }
  size=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]') || size=0
  case "$size" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$size" ;;
  esac
}

# This dispatcher's identity pair for exclusive leases.
# Prints: <pid><TAB><identity>
# Use $$ (process pid), never BASHPID: lease is often taken inside command
# substitution, and a subshell pid would die before begin/confirm/ack run in
# the parent. Concurrent fm-send processes still differ by $$.
fm_send_followup_self_owner() {
  local pid ident
  pid=$$
  ident=$(fm_pid_identity "$pid" 2>/dev/null) || ident="opaque:${pid}:$RANDOM$RANDOM"
  printf '%s\t%s' "$pid" "$ident"
}

# 0 when the lease file names a still-live exclusive owner (alive pid whose
# identity still matches). 1 when the owner is dead, identity-mismatched (pid
# reuse), or the lease is malformed - reclaim is then allowed.
fm_send_followup_lease_owner_live() {  # <lease-path>
  local lease_path=$1 owner_pid owner_ident cur
  [ -f "$lease_path" ] || return 1
  owner_pid=$(sed -n '3p' "$lease_path" 2>/dev/null || true)
  owner_ident=$(sed -n '4p' "$lease_path" 2>/dev/null || true)
  case "$owner_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_pid_alive "$owner_pid" || return 1
  # Alive pid: require identity match when we can read one. Opaque tokens have no
  # re-checkable identity, so a still-alive pid alone proves the owner is live.
  case "$owner_ident" in
    '') return 1 ;;
    opaque:*) return 0 ;;
  esac
  cur=$(fm_pid_identity "$owner_pid" 2>/dev/null || true)
  [ -n "$cur" ] || return 0
  [ "$cur" = "$owner_ident" ]
}

# 0 when this process owns the lease (pid + identity match lines 3-4).
fm_send_followup_lease_is_ours() {  # <lease-path>
  local lease_path=$1 owner_pid owner_ident self self_pid self_ident
  [ -f "$lease_path" ] || return 1
  owner_pid=$(sed -n '3p' "$lease_path" 2>/dev/null || true)
  owner_ident=$(sed -n '4p' "$lease_path" 2>/dev/null || true)
  self=$(fm_send_followup_self_owner)
  self_pid=${self%%$'\t'*}
  self_ident=${self#*$'\t'}
  [ -n "$owner_pid" ] && [ -n "$owner_ident" ] || return 1
  [ "$owner_pid" = "$self_pid" ] && [ "$owner_ident" = "$self_ident" ]
}

# Remove the queue directory entirely and bump lifecycle generation so any
# in-flight lease observes a mismatch. Idempotent. Holds the sibling lock so a
# concurrent enqueue/lease cannot recreate messages under a half-cleared dir.
fm_send_followup_invalidate() {  # <state-dir> <id>
  local state=$1 id=$2 qdir lock
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  qdir=$(fm_send_followup_dir "$state" "$id")
  lock=$(fm_send_followup_lock "$state" "$id")
  [ -e "$qdir" ] || [ -e "$lock" ] || [ -e "$(fm_send_followup_gen_file "$state" "$id")" ] || return 0
  fm_lock_acquire_wait "$lock"
  fm_send_followup_gen_bump_locked "$state" "$id" || {
    fm_lock_release "$lock" || true
    return 1
  }
  rm -rf "$qdir"
  fm_lock_release "$lock" || true
  return 0
}

fm_send_followup_count() {  # <state-dir> <id> -> stdout count
  local state=$1 id=$2 qdir n=0 f
  qdir=$(fm_send_followup_dir "$state" "$id")
  [ -d "$qdir" ] || { printf '0'; return 0; }
  for f in "$qdir"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
    [ -f "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# Append one message. Creates the queue dir. Fails closed on empty id/message.
fm_send_followup_enqueue() {  # <state-dir> <id> <message>
  local state=$1 id=$2 msg=$3 qdir lock seq f tmp
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ -n "$msg" ] || return 1
  qdir=$(fm_send_followup_dir "$state" "$id")
  lock=$(fm_send_followup_lock "$state" "$id")
  fm_lock_acquire_wait "$lock"
  if ! mkdir -p "$qdir"; then
    fm_lock_release "$lock" || true
    return 1
  fi
  seq=0
  for f in "$qdir"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
    [ -f "$f" ] || continue
    seq=${f##*/}
    # force base-10 so a leading-zero lexical name never looks octal
    seq=$((10#$seq))
  done
  seq=$((seq + 1))
  f=$(printf '%s/%010d' "$qdir" "$seq")
  tmp=$f.tmp.$$
  if ! printf '%s' "$msg" > "$tmp"; then
    rm -f "$tmp"
    fm_lock_release "$lock" || true
    return 1
  fi
  if ! mv "$tmp" "$f"; then
    rm -f "$tmp"
    fm_lock_release "$lock" || true
    return 1
  fi
  fm_lock_release "$lock" || true
  return 0
}

# Internal: path of the lease marker inside the queue dir.
fm_send_followup_lease_path() {  # <qdir>
  printf '%s/.lease' "$1"
}

# Write a lease file for this dispatcher. Under caller's held lock.
fm_send_followup_lease_write_locked() {  # <lease-path> <gen> <base>
  local lease_path=$1 gen=$2 base=$3 self self_pid self_ident
  self=$(fm_send_followup_self_owner)
  self_pid=${self%%$'\t'*}
  self_ident=${self#*$'\t'}
  printf '%s\n%s\n%s\n%s\n\n' "$gen" "$base" "$self_pid" "$self_ident" > "$lease_path"
}

# Invalidate under an already-held queue lock (bumps gen, removes qdir).
fm_send_followup_invalidate_locked() {  # <state-dir> <id> <qdir>
  local state=$1 id=$2 qdir=$3
  fm_send_followup_gen_bump_locked "$state" "$id" || return 1
  rm -rf "$qdir"
  return 0
}

# Lease the oldest message for transport without removing it.
# Exit 0 and print the message when this dispatcher exclusively leases a live
# head item.
# Exit 1 when empty or terminal (invalidates on terminal).
# Exit 2 on IO failure after the lock was taken.
# Exit 3 when another live dispatcher holds the exclusive lease - callers must
# wait and retry (do not fall through to a fresh send; that overtakes FIFO).
fm_send_followup_lease() {  # <state-dir> <id>
  local state=$1 id=$2 qdir lock f msg gen lease_path base
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  if fm_send_followup_is_terminal "$state" "$id"; then
    fm_send_followup_invalidate "$state" "$id"
    return 1
  fi
  qdir=$(fm_send_followup_dir "$state" "$id")
  [ -d "$qdir" ] || return 1
  lock=$(fm_send_followup_lock "$state" "$id")
  fm_lock_acquire_wait "$lock"
  # Re-check terminal under the lock so a done: that landed between the
  # pre-lock read and acquire still drops the queue and bumps generation.
  if fm_send_followup_is_terminal "$state" "$id"; then
    fm_send_followup_invalidate_locked "$state" "$id" "$qdir" || {
      fm_lock_release "$lock" || true
      return 2
    }
    fm_lock_release "$lock" || true
    return 1
  fi
  lease_path=$(fm_send_followup_lease_path "$qdir")
  if [ -f "$lease_path" ]; then
    if fm_send_followup_lease_is_ours "$lease_path"; then
      : # re-enter our own lease (retry after confirm failure without release)
    elif fm_send_followup_lease_owner_live "$lease_path"; then
      # Exclusive: a second live dispatcher must wait (exit 3), not steal or skip.
      fm_lock_release "$lock" || true
      return 3
    fi
    # Dead or identity-mismatched owner: reclaim below.
  fi
  f=
  for f in "$qdir"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
    [ -f "$f" ] || continue
    break
  done
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    rm -f "$lease_path"
    rmdir "$qdir" 2>/dev/null || true
    fm_lock_release "$lock" || true
    return 1
  fi
  msg=$(cat "$f" 2>/dev/null) || {
    fm_lock_release "$lock" || true
    return 2
  }
  gen=$(fm_send_followup_gen_read "$state" "$id")
  base=${f##*/}
  if ! fm_send_followup_lease_write_locked "$lease_path" "$gen" "$base"; then
    fm_lock_release "$lock" || true
    return 2
  fi
  fm_lock_release "$lock" || true
  printf '%s' "$msg"
  return 0
}

# Setup precheck under the queue lock: this dispatcher owns the lease, the task
# is not terminal, and the status fence is recorded on the lease. Exit 0 when
# transport may proceed toward the late confirm; exit 1 when aborted (terminal
# invalidates); exit 2 on IO failure. The authoritative final terminal check is
# transport_confirm immediately before backend send, not this function.
fm_send_followup_transport_begin() {  # <state-dir> <id>
  local state=$1 id=$2 qdir lock lease_path gen_lease base gen_now fence tmp
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  qdir=$(fm_send_followup_dir "$state" "$id")
  lock=$(fm_send_followup_lock "$state" "$id")
  lease_path=$(fm_send_followup_lease_path "$qdir")
  fm_lock_acquire_wait "$lock"
  if fm_send_followup_is_terminal "$state" "$id"; then
    fm_send_followup_invalidate_locked "$state" "$id" "$qdir" || {
      fm_lock_release "$lock" || true
      return 2
    }
    fm_lock_release "$lock" || true
    return 1
  fi
  if ! fm_send_followup_lease_is_ours "$lease_path"; then
    fm_lock_release "$lock" || true
    return 1
  fi
  gen_lease=$(sed -n '1p' "$lease_path" 2>/dev/null || true)
  base=$(sed -n '2p' "$lease_path" 2>/dev/null || true)
  gen_now=$(fm_send_followup_gen_read "$state" "$id")
  if [ "$gen_lease" != "$gen_now" ] || [ -z "$base" ] || [ ! -f "$qdir/$base" ]; then
    rm -f "$lease_path"
    fm_lock_release "$lock" || true
    return 1
  fi
  fence=$(fm_send_followup_status_fence "$state" "$id")
  tmp=$lease_path.tmp.$$
  if ! {
    sed -n '1,4p' "$lease_path"
    printf '%s\n' "$fence"
  } > "$tmp" || ! mv "$tmp" "$lease_path"; then
    rm -f "$tmp"
    fm_lock_release "$lock" || true
    return 2
  fi
  fm_lock_release "$lock" || true
  return 0
}

# Final terminal + ownership re-validation immediately before backend transport.
# Under the queue lock: still our lease, generation current, and not terminal
# (status fence change is allowed only while still non-terminal). On terminal,
# invalidates. Call at the last possible instant before send-keys (the residual
# milliseconds after this return until the backend finishes are the known
# captain-accepted limitation in the header).
fm_send_followup_transport_confirm() {  # <state-dir> <id>
  local state=$1 id=$2 qdir lock lease_path gen_lease base gen_now fence_lease fence_now tmp
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  qdir=$(fm_send_followup_dir "$state" "$id")
  lock=$(fm_send_followup_lock "$state" "$id")
  lease_path=$(fm_send_followup_lease_path "$qdir")
  fm_lock_acquire_wait "$lock"
  if fm_send_followup_is_terminal "$state" "$id"; then
    fm_send_followup_invalidate_locked "$state" "$id" "$qdir" || {
      fm_lock_release "$lock" || true
      return 2
    }
    fm_lock_release "$lock" || true
    return 1
  fi
  if ! fm_send_followup_lease_is_ours "$lease_path"; then
    fm_lock_release "$lock" || true
    return 1
  fi
  gen_lease=$(sed -n '1p' "$lease_path" 2>/dev/null || true)
  base=$(sed -n '2p' "$lease_path" 2>/dev/null || true)
  fence_lease=$(sed -n '5p' "$lease_path" 2>/dev/null || true)
  gen_now=$(fm_send_followup_gen_read "$state" "$id")
  fence_now=$(fm_send_followup_status_fence "$state" "$id")
  if [ "$gen_lease" != "$gen_now" ] || [ -z "$base" ] || [ ! -f "$qdir/$base" ]; then
    rm -f "$lease_path"
    fm_lock_release "$lock" || true
    return 1
  fi
  # Fence advanced without becoming terminal (e.g. working: append): refresh and
  # continue. Fence is an ordering signal paired with the terminal scan under the
  # same lock, not a hard freeze of all status writes.
  if [ -n "$fence_lease" ] && [ "$fence_lease" != "$fence_now" ]; then
    tmp=$lease_path.tmp.$$
    if ! {
      sed -n '1,4p' "$lease_path"
      printf '%s\n' "$fence_now"
    } > "$tmp" || ! mv "$tmp" "$lease_path"; then
      rm -f "$tmp"
      fm_lock_release "$lock" || true
      return 2
    fi
  fi
  fm_lock_release "$lock" || true
  return 0
}

# Back-compat name used by older tests: confirm ownership + non-terminal under
# lock without requiring a prior transport_begin fence line.
fm_send_followup_lease_may_deliver() {  # <state-dir> <id>
  fm_send_followup_transport_confirm "$@"
}

# Acknowledge a successful transport: remove the leased head only when this
# dispatcher still owns the lease. Terminal or foreign/stale lease clears or
# refuses without resurrecting the item for a second live owner.
# Exit 0 when settled (acked, already cleared, or invalidated as terminal).
# Exit 2 on IO failure or foreign lease after we claim we delivered.
fm_send_followup_ack() {  # <state-dir> <id>
  local state=$1 id=$2 qdir lock lease_path gen_lease base gen_now
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  qdir=$(fm_send_followup_dir "$state" "$id")
  lock=$(fm_send_followup_lock "$state" "$id")
  lease_path=$(fm_send_followup_lease_path "$qdir")
  fm_lock_acquire_wait "$lock"
  if fm_send_followup_is_terminal "$state" "$id"; then
    fm_send_followup_invalidate_locked "$state" "$id" "$qdir" || {
      fm_lock_release "$lock" || true
      return 2
    }
    fm_lock_release "$lock" || true
    return 0
  fi
  if [ ! -f "$lease_path" ]; then
    # Lease already gone: either we never owned it or another path cleared it.
    # Do not treat as success for a foreign delivery; empty is settled.
    fm_lock_release "$lock" || true
    return 0
  fi
  if ! fm_send_followup_lease_is_ours "$lease_path"; then
    fm_lock_release "$lock" || true
    return 2
  fi
  gen_lease=$(sed -n '1p' "$lease_path" 2>/dev/null || true)
  base=$(sed -n '2p' "$lease_path" 2>/dev/null || true)
  gen_now=$(fm_send_followup_gen_read "$state" "$id")
  if [ "$gen_lease" != "$gen_now" ]; then
    rm -f "$lease_path"
    fm_lock_release "$lock" || true
    return 0
  fi
  if [ -n "$base" ]; then
    rm -f "$qdir/$base" || {
      fm_lock_release "$lock" || true
      return 2
    }
  fi
  rm -f "$lease_path"
  if [ -d "$qdir" ] && ! ls "$qdir"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] >/dev/null 2>&1; then
    rmdir "$qdir" 2>/dev/null || true
  fi
  fm_lock_release "$lock" || true
  return 0
}

# Release a lease after failed transport: keep the message file, drop only this
# dispatcher's lease marker. Terminal invalidates. Foreign lease is a no-op
# success (we never owned it).
fm_send_followup_release() {  # <state-dir> <id>
  local state=$1 id=$2 qdir lock lease_path
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  qdir=$(fm_send_followup_dir "$state" "$id")
  lock=$(fm_send_followup_lock "$state" "$id")
  lease_path=$(fm_send_followup_lease_path "$qdir")
  fm_lock_acquire_wait "$lock"
  if fm_send_followup_is_terminal "$state" "$id"; then
    fm_send_followup_invalidate_locked "$state" "$id" "$qdir" || {
      fm_lock_release "$lock" || true
      return 2
    }
    fm_lock_release "$lock" || true
    return 0
  fi
  if [ ! -f "$lease_path" ]; then
    fm_lock_release "$lock" || true
    return 0
  fi
  if ! fm_send_followup_lease_is_ours "$lease_path"; then
    fm_lock_release "$lock" || true
    return 0
  fi
  rm -f "$lease_path" || {
    fm_lock_release "$lock" || true
    return 2
  }
  fm_lock_release "$lock" || true
  return 0
}
