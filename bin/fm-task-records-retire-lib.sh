#!/usr/bin/env bash
# bin/fm-task-records-retire-lib.sh - shared retirement of one task's volatile
# per-task state records through their own writers.
#
# bin/fm-teardown.sh retires these families at the end of a successful
# cleanup, and bin/fm-status-gc.sh --finish-cleanup retires the same families
# for a record whose task meta is already gone (an interrupted cleanup).
# Both must retire a family exactly the way its writer expects, so the
# retirement mechanics live here once, not as two drifting copies:
#
#   fm_task_records_retire_turnend <grok|kimi> <state-dir> <id>
#       The grok and kimi turn-end hooks are global and gated by a private
#       token file (bin/fm-control-lib.sh owns both paths): read the token
#       from state/<id>.<harness>-turnend-token, remove the registered hook
#       auth file it names, then remove the token file itself. Both halves
#       are deregistration through the control plane's own path contract,
#       never a hand-computed rm of a harness config.
#   fm_task_records_retire_busy <state-dir> <id> <gen>
#       Retire the busy-state incarnation through bin/fm-busy-event.sh (the
#       only writer of the busy record) with an exact gen when known, with
#       --current-gen when only the sidecar survives, or as a no-op when
#       neither exists.
#   fm_task_records_remove_pr_poll_artifacts <state-dir> <id>
#       The PR-check artifact family (check.sh, check-trust, pr-poll,
#       pr-poll-registration, pr-poll-retirement) is validated as ordinary
#       single-link files on the state device and retired through
#       bin/fm-pr-lib.sh's recovery and merge-notified owners, exactly as
#       bin/fm-teardown.sh has always done.
#   fm_task_records_retire_residue <state-dir> <id>
#       The plain firstmate-owned state residue bin/fm-teardown.sh removes
#       with rm -f after every safety gate has passed: turn-ended and
#       progress markers, harness wiring sidecars (muse-session(-current),
#       cursor-session, pi-ext.ts, omp-ext.ts, gemini-settings.json),
#       reconcile-nudged, the control-relaunch prior-record family, and the
#       per-task branch-outcome index, plus the steering inbox directory.
#       These files name no live external resource; their only writer is
#       firstmate itself, so plain removal IS the writer retirement.
#       Turn-end token files are deliberately NOT in this list: they belong
#       to fm_task_records_retire_turnend.
#
# Every function refuses (non-zero) before removing anything when its writer
# proof fails, and every removal is idempotent: a second run finds nothing
# to do and succeeds.
# This lib is source-only; it has no main.

FM_TASK_RECORDS_RETIRE_BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=bin/fm-pr-lib.sh
. "$FM_TASK_RECORDS_RETIRE_BIN/fm-pr-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$FM_TASK_RECORDS_RETIRE_BIN/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$FM_TASK_RECORDS_RETIRE_BIN/fm-busy-lib.sh"

fm_task_records_validate_turnend() {  # <grok|kimi> <state-dir> <id>
  local harness=$1 state_dir=$2 id=$3 token_path token='' path inode
  token_path=$(fm_control_harness_turnend_token_path "$harness" "$state_dir" "$id") || return 1
  [ -e "$token_path" ] || [ -L "$token_path" ] || return 0
  if [ ! -f "$token_path" ] || [ -L "$token_path" ] \
    || [ "$(fm_pr_file_link_count "$token_path")" != 1 ]; then
    echo "REFUSED: unsafe task turn-end token record; preserving task state." >&2
    return 1
  fi
  inode=$(fm_pr_file_inode "$token_path") || return 1
  IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  if [ ! -f "$token_path" ] || [ -L "$token_path" ] \
    || [ "$(fm_pr_file_link_count "$token_path")" != 1 ] \
    || [ "$(fm_pr_file_inode "$token_path")" != "$inode" ]; then
    echo "REFUSED: unsafe task turn-end token record; preserving task state." >&2
    return 1
  fi
  path=$(fm_control_harness_turnend_auth_path "$harness" "$token") || return 1
  [ -n "$path" ] || return 0
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if [ ! -f "$path" ] || [ -L "$path" ] \
    || [ "$(fm_pr_file_link_count "$path")" != 1 ]; then
    echo "REFUSED: unsafe task turn-end auth target; preserving task state." >&2
    return 1
  fi
}

fm_task_records_retire_turnend() {  # <grok|kimi> <state-dir> <id>
  local harness=$1 state_dir=$2 id=$3 token_path token='' path inode
  token_path=$(fm_control_harness_turnend_token_path "$harness" "$state_dir" "$id") || return 1
  fm_task_records_validate_turnend "$harness" "$state_dir" "$id" || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    inode=$(fm_pr_file_inode "$token_path") || return 1
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
    fm_task_records_validate_turnend "$harness" "$state_dir" "$id" || return 1
    [ "$(fm_pr_file_inode "$token_path")" = "$inode" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path "$harness" "$token") || return 1
  # The token file is firstmate-owned state and always goes; the global hook
  # registration it names is removed only when the token resolves to a valid
  # auth path (an empty or invalid token has no registration to retire).
  if [ -n "$path" ]; then
    rm -f -- "$path" || return 1
  fi
  [ -z "$token_path" ] || rm -f -- "$token_path"
}

fm_task_records_retire_busy() {  # <state-dir> <id> <gen>
  local state_dir=$1 id=$2 gen=${3:-}
  if [ -n "$gen" ]; then
    "$FM_TASK_RECORDS_RETIRE_BIN/fm-busy-event.sh" retire "$state_dir" "$id" --gen "$gen"
  else
    "$FM_TASK_RECORDS_RETIRE_BIN/fm-busy-event.sh" retire "$state_dir" "$id" --current-gen
  fi
}

fm_task_records_validate_busy_shapes() {  # <state-dir> <id>
  local state_dir=$1 id=$2 state_device artifact
  fm_task_id_path_safe "$id" || return 1
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.busy-gen" "$state_dir/$id.busy-state"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task busy-state record; preserving task state." >&2
      return 1
    fi
  done
}

fm_task_records_read_busy_gen() {  # <state-dir> <id> [<recorded-gen>]
  local state_dir=$1 id=$2 recorded_gen=${3:-}
  fm_task_records_validate_busy_shapes "$state_dir" "$id" || return 1
  if [ -n "$recorded_gen" ]; then
    printf '%s' "$recorded_gen"
  elif [ -e "$state_dir/$id.busy-gen" ]; then
    fm_busy_current_gen "$state_dir" "$id"
  fi
}

fm_task_records_validate_busy_cleanup() {  # <state-dir> <id> <gen>
  local state_dir=$1 id=$2 gen=${3:-} current
  fm_task_records_validate_busy_shapes "$state_dir" "$id" || return 1
  if [ -e "$state_dir/$id.busy-gen" ] || [ -L "$state_dir/$id.busy-gen" ]; then
    current=$(fm_busy_current_gen "$state_dir" "$id") || return 1
    [ "$gen" = "$current" ]
  else
    return 0
  fi
}

fm_task_records_validate_pr_poll_cleanup() {  # <state-dir> <id>
  local state_dir=$1 id=$2 state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust" "$state_dir/$id.pr-poll-merge-notified"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust" "$state_dir/$id.pr-poll-merge-notified"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  if [ -e "$state_dir/$id.pr-poll-retirement" ] \
    || [ -L "$state_dir/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state_dir" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
}

fm_task_records_remove_pr_poll_artifacts() {  # <state-dir> <id>
  local state_dir=$1 id=$2
  fm_task_records_validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state_dir" "$id" \
    "$FM_TASK_RECORDS_RETIRE_BIN/fm-pr-poll.sh" || return 1
  fm_pr_poll_merge_notified_remove "$state_dir" "$id" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust" || return 1
}

fm_task_records_residue_paths() {  # <state-dir> <id>
  local state_dir=$1 id=$2
  printf '%s\n' \
    "$state_dir/$id.turn-ended" \
    "$state_dir/$id.progress" \
    "$state_dir/$id.pi-ext.ts" \
    "$state_dir/$id.omp-ext.ts" \
    "$state_dir/$id.muse-session" \
    "$state_dir/$id.muse-session-current" \
    "$state_dir/$id.cursor-session" \
    "$state_dir/$id.control-relaunch" \
    "$state_dir/$id.control-relaunch.meta-prior" \
    "$state_dir/$id.control-relaunch.brief-prior" \
    "$state_dir/$id.control-relaunch.note" \
    "$state_dir/$id.reconcile-nudged" \
    "$state_dir/$id.gemini-settings.json" \
    "$state_dir/.$id.branch-outcome-index"
}

fm_task_records_validate_residue() {  # <state-dir> <id>
  local state_dir=$1 id=$2 state_device path inbox
  fm_task_id_path_safe "$id" || return 1
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  while IFS= read -r path; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    if [ ! -f "$path" ] || [ -L "$path" ] \
      || [ "$(fm_pr_file_device "$path")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$path")" != 1 ]; then
      echo "REFUSED: unsafe task state residue; preserving task state." >&2
      return 1
    fi
  done < <(fm_task_records_residue_paths "$state_dir" "$id")
  inbox="$state_dir/$id.inbox"
  [ -e "$inbox" ] || [ -L "$inbox" ] || return 0
  if [ ! -d "$inbox" ] || [ -L "$inbox" ]; then
    echo "REFUSED: unsafe task steering inbox; preserving task state." >&2
    return 1
  fi
}

fm_task_records_validate_cleanup() {  # <state-dir> <id> <busy-gen>
  local state_dir=$1 id=$2 busy_gen=${3:-}
  fm_task_records_validate_turnend grok "$state_dir" "$id" || return 1
  fm_task_records_validate_turnend kimi "$state_dir" "$id" || return 1
  fm_task_records_validate_busy_cleanup "$state_dir" "$id" "$busy_gen" || return 1
  fm_task_records_validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_task_records_validate_residue "$state_dir" "$id"
}

fm_task_records_retire_residue() {  # <state-dir> <id>
  local state_dir=$1 id=$2 path
  fm_task_records_validate_residue "$state_dir" "$id" || return 1
  while IFS= read -r path; do
    rm -f -- "$path" || return 1
  done < <(fm_task_records_residue_paths "$state_dir" "$id")
  rm -rf -- "$state_dir/$id.inbox"
}
