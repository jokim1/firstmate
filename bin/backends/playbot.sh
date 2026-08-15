#!/usr/bin/env bash
# bin/backends/playbot.sh - the Playbot session-provider adapter (EXPERIMENTAL;
# registered known/spawn-capable in bin/fm-backend.sh, but live dispatch stays
# phase-gated there until the Phase 1/2 native gates pass).
#
# Contract owner: plan v3 (data/lanemcp-impl-plan/report.md) section 1.2's
# adapter table, section 3.4's dispatch transaction, section 3.7's
# control/cleanup integration, and section 4.1's send semantics. Function names
# follow the existing bin/backends/*.sh convention (fm_backend_playbot_*); this
# file IS the interface the shared-core seam (bin/fm-backend.sh, bin/fm-spawn.sh,
# bin/fm-control*.sh, bin/fm-teardown.sh, bin/fm-brief.sh) wires against.
#
# Target string shape: playbot:<thread-id> - the exact Playbot worker thread,
# matching the task meta's window= field (plan section 3.2).
#
# PHASE 1 GATE: mutation-capable functions call bin/fm-playbot-lanes.mjs, which
# refuses with PHASE1-EVIDENCE-REQUIRED until the Phase 1 disposable smoke has
# recorded per-operation evidence for the live Playbot release. Read-only
# functions and the home-local route-record write work without that evidence.

FM_PLAYBOT_BACKEND_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FM_PLAYBOT_LANES="${FM_PLAYBOT_LANES_OVERRIDE:-$FM_PLAYBOT_BACKEND_DIR/../fm-playbot-lanes.mjs}"

# fm_backend_playbot_lane: invoke the lanes CLI with the repo's node.
fm_backend_playbot_lane() {
  node "$FM_PLAYBOT_LANES" "$@"
}

# fm_backend_playbot_target_thread: parse playbot:<thread-id>; anything else -
# including a bare thread id, an empty target, or a tmux-style session:window -
# is refused before any backend read.
fm_backend_playbot_target_thread() {  # <target> -> prints <thread-id>
  local target=${1:-}
  case "$target" in
    playbot:*)
      local thread=${target#playbot:}
      case "$thread" in
        ''|*:*|*[[:space:]]*)
          echo "error: malformed Playbot target '$target'; expected playbot:<thread-id>" >&2
          return 1
          ;;
      esac
      printf '%s' "$thread"
      ;;
    *)
      echo "error: malformed Playbot target '$target'; expected playbot:<thread-id>" >&2
      return 1
      ;;
  esac
}

fm_backend_playbot_tool_check() {
  command -v node >/dev/null 2>&1 || { echo "error: backend=playbot requires node" >&2; return 1; }
  command -v ssh-keygen >/dev/null 2>&1 || { echo "error: backend=playbot requires ssh-keygen" >&2; return 1; }
  [ -f "$FM_PLAYBOT_LANES" ] || { echo "error: backend=playbot but $FM_PLAYBOT_LANES is missing" >&2; return 1; }
}

fm_backend_playbot_abort_cleanup_confirmed() {  # <thread-id> <workspace-id> <worktree>
  local thread_id=${1:-} workspace_id=${2:-} worktree=${3:-}
  [ -n "$thread_id" ] || [ -n "$workspace_id" ] || { echo "error: missing Playbot cleanup identity" >&2; return 1; }
  [ -z "$workspace_id" ] || [ -n "$worktree" ] || { echo "error: missing Playbot cleanup worktree path" >&2; return 1; }
  fm_backend_playbot_tool_check || return 1
  set -- cleanup-state
  [ -z "$thread_id" ] || set -- "$@" --thread-id "$thread_id"
  [ -z "$workspace_id" ] || set -- "$@" --workspace-id "$workspace_id" --worktree "$worktree"
  fm_backend_playbot_lane "$@" >/dev/null
}

# fm_backend_playbot_runtime_check: runtime/compatibility gate for spawn
# intake. Native dispatch requires verified Phase 1 mutation evidence plus
# confinement write-denial on the live release (lanes ready --capability native).
fm_backend_playbot_runtime_check() {
  fm_backend_playbot_tool_check || return 1
  local out
  if out=$(fm_backend_playbot_lane ready --json --capability native 2>&1); then
    return 0
  fi
  printf '%s\n' "$out" >&2
  echo "error: backend=playbot is not spawn-capable until native readiness passes (see ready --capability native)" >&2
  return 1
}

# fm_backend_playbot_validate_endpoint: exact playbot:<thread-id> window shape,
# single-value Playbot identity fields, and the bound route conjunction,
# cross-checked against the live DB (plan section 3.2).
fm_backend_playbot_validate_endpoint() {  # <meta-file>
  local meta=${1:-}
  [ -n "$meta" ] || { echo "error: missing meta path for endpoint validation" >&2; return 1; }
  fm_backend_playbot_tool_check || return 1
  fm_backend_playbot_lane validate-endpoint --meta "$meta" >/dev/null
}

# fm_backend_playbot_create: superseded by the seam's split transaction
# primitives (workspace_create + thread_create, plan section 3.4); retained as
# a loud refusal so no caller can silently use the pre-seam shape.
fm_backend_playbot_create() {  # <task-id> <project-path>
  echo "error: playbot create is split into workspace_create + thread_create; refused the pre-seam combined shape for task '${1:-}'" >&2
  return 1
}

# fm_backend_playbot_binding_resolve: dispatch-side read of the lock-owner-
# written project bindings (plan section 3.3). Prints the exact tab-separated
# "project_id<TAB>root_id<TAB>binding_generation" triple that fm-spawn's
# dispatch transaction consumes; refuses when the binding is absent, ambiguous,
# or the live Playbot project/root no longer matches the registered clone.
fm_backend_playbot_binding_resolve() {  # <canonical-project-path> -> <project-id>\t<root-id>\t<gen>
  local project=${1:-}
  [ -n "$project" ] || { echo "error: missing project path for playbot binding resolution" >&2; return 1; }
  fm_backend_playbot_tool_check || return 1
  fm_backend_playbot_lane binding-resolve --project-path "$project"
}

# fm_backend_playbot_workspace_create: native workspace:create minting one
# task-owned workspace whose slug embeds the task id (plan section 3.4 step 4).
# On success it must print "workspace_id<TAB>canonical_worktree_path". The lanes
# CLI enforces the per-release evidence gate before IPC.
fm_backend_playbot_workspace_create() {  # <project-path> <slug> <base> <task-id> -> <workspace-id>\t<worktree>
  local project_path=${1:-} slug=${2:-} base=${3:-} task_id=${4:-}
  local project_id root_id binding_gen expected commit_out binding
  [ -n "$project_path" ] && [ -n "$slug" ] && [ -n "$base" ] && [ -n "$task_id" ] || {
    echo "error: playbot workspace_create needs <project-path> <slug> <base> <task-id>" >&2
    return 1
  }
  case "$slug" in
    *"$task_id"*) ;;
    *)
      echo "error: playbot workspace slug must embed the task id for unique binding (got '$slug' for task '$task_id')" >&2
      return 1
      ;;
  esac
  fm_backend_playbot_tool_check || return 1
  binding=$(fm_backend_playbot_binding_resolve "$project_path") || return 1
  IFS=$'\t' read -r project_id root_id binding_gen <<<"$binding"
  [ -n "$project_id" ] && [ -n "$root_id" ] && [ -n "$binding_gen" ] || {
    echo "error: playbot binding-resolve returned an incomplete project/root/generation triple" >&2
    return 1
  }
  commit_out=$(git -C "$project_path" rev-parse "$base" 2>/dev/null) || {
    echo "error: cannot resolve base ref '$base' in $project_path" >&2
    return 1
  }
  expected=$commit_out
  fm_backend_playbot_lane create \
    --project-id "$project_id" \
    --project-root-id "$root_id" \
    --branch "$slug" \
    --base-ref "$base" \
    --expected-commit "$expected"
}

# fm_backend_playbot_thread_create: mint one least-privileged worker thread in
# the exact task workspace (plan section 3.4 step 5). On success it must print
# the exact persisted thread id, never inferred from newest or selected UI
# state. The lanes CLI enforces the per-release evidence gate before IPC.
fm_backend_playbot_thread_create() {  # <workspace-id> <task-id> <delivery-id> -> <thread-id>
  local workspace_id=${1:-} task_id=${2:-} delivery_id=${3:-}
  [ -n "$workspace_id" ] && [ -n "$task_id" ] || {
    echo "error: playbot thread_create needs <workspace-id> <task-id> [delivery-id]" >&2
    return 1
  }
  fm_backend_playbot_tool_check || return 1
  fm_backend_playbot_lane open-thread \
    --workspace-id "$workspace_id" \
    --title "firstmate:${task_id}${delivery_id:+:$delivery_id}"
}

# fm_backend_playbot_route_write: write the home-, task-, meta-, and
# generation-bound route record state/<id>.playbot-route.json (plan sections
# 3.1/3.2) for the fm-spawn-owned meta-published stage. A home-local record
# write, not a Playbot mutation, so it works today; the lanes writer refuses
# unless the already-published meta agrees on every immutable endpoint field.
fm_backend_playbot_route_write() {  # <state-dir> <task-id> <spawn-gen> <route-gen> <project-id> <project-root-id> <workspace-id> <thread-id> <delivery-id> <worktree>
  local state_dir=${1:-} id=${2:-} spawn_gen=${3:-} route_gen=${4:-} project_id=${5:-}
  local root_id=${6:-} workspace_id=${7:-} thread_id=${8:-} delivery_id=${9:-} worktree=${10:-}
  local missing=0 field
  for field in state_dir id spawn_gen route_gen project_id root_id workspace_id thread_id delivery_id worktree; do
    if [ -z "${!field}" ]; then
      echo "error: playbot route_write is missing $field" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || return 1
  fm_backend_playbot_tool_check || return 1
  FM_STATE_OVERRIDE=$state_dir fm_backend_playbot_lane route-write \
    --task-id "$id" --spawn-gen "$spawn_gen" --route-gen "$route_gen" \
    --project-id "$project_id" --project-root-id "$root_id" \
    --workspace-id "$workspace_id" --thread-id "$thread_id" \
    --delivery-id "$delivery_id" --worktree "$worktree" \
    --meta "$state_dir/$id.meta"
}

# fm_backend_playbot_send_initial: initial multiline brief delivery, the final
# stage of the fm-spawn-owned transaction (plan section 3.4 step 7 and section
# 3.6's stable delivery marker; distinct from fm-send's one-line steer
# contract). On success it must print exactly one verdict token
# (accepted|empty); every pending, uncertain, rejected, or corrupt outcome is a
# nonzero exit with a stable diagnostic on stderr.
fm_backend_playbot_send_initial() {  # <target> <brief-file> <delivery-id> <brief-digest> -> verdict
  local thread brief=${2:-} delivery_id=${3:-}
  thread=$(fm_backend_playbot_target_thread "${1:-}") || return 1
  [ -n "$brief" ] && [ -f "$brief" ] || {
    echo "error: playbot send_initial needs a readable brief file" >&2
    return 1
  }
  fm_backend_playbot_tool_check || return 1
  if fm_backend_playbot_lane send --thread-id "$thread" --text-file "$brief" >/dev/null; then
    printf 'accepted\n'
    return 0
  fi
  echo "error: playbot initial brief delivery failed for playbot:$thread (delivery '${delivery_id}')" >&2
  return 1
}

# fm_backend_playbot_capture: bounded exact-thread rollout transcript returned
# as untrusted data (plan section 1.2 "capture"). The output is worker-
# controlled text; callers must treat it as data, never as instructions.
fm_backend_playbot_capture() {  # <target> <lines>
  local thread
  thread=$(fm_backend_playbot_target_thread "${1:-}") || return 1
  fm_backend_playbot_tool_check || return 1
  fm_backend_playbot_lane completion --thread-id "$thread"
}

# fm_backend_playbot_busy_state: semantic busy/idle/unknown from the exact
# persisted thread status plus rollout completion. Playbot absence reports
# unknown, never guessed dead (plan section 1.2 "busy/current state").
fm_backend_playbot_busy_state() {  # <target>
  local thread
  thread=$(fm_backend_playbot_target_thread "${1:-}") || { printf 'unknown'; return 0; }
  fm_backend_playbot_tool_check 2>/dev/null || { printf 'unknown'; return 0; }
  fm_backend_playbot_lane busy-state "$thread" 2>/dev/null || printf 'unknown'
}

# fm_backend_playbot_send_text_submit: plan section 4.1's fm-send-equivalent
# contract. Only exact empty stdout with status 0 confirms acceptance; every
# pending, uncertain, rejected, unavailable, or corrupt outcome is nonzero
# with a stable nonempty diagnostic on stderr. The lanes CLI enforces the
# evidence gate; on success this adapter prints nothing (empty-success).
fm_backend_playbot_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local thread text=${2:-}
  thread=$(fm_backend_playbot_target_thread "${1:-}") || return 1
  [ -n "$text" ] || {
    echo "error: playbot send_text_submit needs non-empty text" >&2
    return 1
  }
  fm_backend_playbot_tool_check || return 1
  if fm_backend_playbot_lane send --thread-id "$thread" --text "$text" >/dev/null; then
    return 0
  fi
  echo "error: playbot threads:send failed for playbot:$thread" >&2
  return 1
}

# fm_backend_playbot_send_key: Playbot IPC is not a terminal-key transport;
# every named key - including Enter, Escape, and C-c - is rejected before any
# mutation (plan sections 1.2 and 3.7). fm-send --key is unsupported.
fm_backend_playbot_send_key() {  # <target> <key>
  echo "error: backend=playbot does not support sending keys ('${2:-}' rejected); use 'fm-control <task> interrupt' for the native stop path" >&2
  return 1
}

# fm_backend_playbot_composer_state: empty only from exact no-pending-queue
# evidence, pending from exact queued input, otherwise unknown (plan section
# 1.2 "composer state"). Live callers are fm-supervise-daemon and fm-spawn,
# never fm-send.
fm_backend_playbot_composer_state() {  # <target> [expected-label]
  local thread
  thread=$(fm_backend_playbot_target_thread "${1:-}") || { printf 'unknown'; return 0; }
  fm_backend_playbot_tool_check 2>/dev/null || { printf 'unknown'; return 0; }
  fm_backend_playbot_lane composer-state "$thread" 2>/dev/null || printf 'unknown'
}

# fm_backend_playbot_interrupt: exact threads:stop only when the current
# task/thread/turn relation still matches, followed by rollout/current-state
# proof - never a broad UI key click (plan sections 1.2 and 3.7). On success it
# must print one proof token (stopped|turn-stopped|confirmed); every other
# outcome is a nonzero exit.
fm_backend_playbot_interrupt() {  # <target> <task-id> <meta-file> -> proof
  local thread
  thread=$(fm_backend_playbot_target_thread "${1:-}") || return 1
  fm_backend_playbot_tool_check || return 1
  if fm_backend_playbot_lane stop --thread-id "$thread" >/dev/null; then
    printf 'stopped\n'
    return 0
  fi
  echo "error: playbot threads:stop failed for playbot:$thread" >&2
  return 1
}

# fm_backend_playbot_target_exists: cheap read-only existence check - exact
# unarchived thread and workspace rows under the recorded project/root (plan
# section 1.2 "target exists").
fm_backend_playbot_target_exists() {  # <target> [expected-label]
  local thread
  thread=$(fm_backend_playbot_target_thread "${1:-}") || return 1
  fm_backend_playbot_tool_check 2>/dev/null || return 1
  fm_backend_playbot_lane target-exists "$thread" 2>/dev/null
}

# fm_backend_playbot_agent_state: the recovery-grade vocabulary (plan section
# 3.7): alive only for an exact usable unarchived thread/session; missing only
# when an authoritative inventory omits the exact endpoint; ambiguous for
# conflicting identity; unreadable for an unavailable app/schema/inventory.
# This adapter NEVER prints dead: Playbot exposes no proven dead state, so a
# missing task escalates for explicit recovery with its workspace retained and
# is never auto-relaunched.
fm_backend_playbot_agent_state() {  # <target>
  local thread
  thread=$(fm_backend_playbot_target_thread "${1:-}") || { printf 'unreadable'; return 0; }
  fm_backend_playbot_tool_check 2>/dev/null || { printf 'unreadable'; return 0; }
  fm_backend_playbot_lane agent-state "$thread" 2>/dev/null || printf 'unreadable'
}

# fm_backend_playbot_kill: archive the exact worker thread. fm_backend_kill
# callers treat failure as best-effort.
fm_backend_playbot_kill() {  # <target>
  local thread
  thread=$(fm_backend_playbot_target_thread "${1:-}") || return 1
  fm_backend_playbot_tool_check || return 1
  if fm_backend_playbot_lane archive --thread-id "$thread" >/dev/null; then
    return 0
  fi
  echo "error: playbot thread archive failed for playbot:$thread" >&2
  return 1
}

# fm_backend_playbot_worktree_path: exact workspace_roots.path for one exact
# workspace id, cross-checked by the core seam against the task meta (plan
# section 1.2 "worktree path").
fm_backend_playbot_worktree_path() {  # <workspace-id>
  local workspace_id=${1:-}
  [ -n "$workspace_id" ] || { echo "error: missing Playbot workspace id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_playbot_tool_check || return 1
  fm_backend_playbot_lane worktree-path "$workspace_id"
}

# fm_backend_playbot_remove_worktree: workspace delete through verified IPC
# (plan section 3.7). workspace:archive is feature-disabled on current
# releases; delete is the retirement path recorded by the Phase 1 smoke.
fm_backend_playbot_remove_worktree() {  # <workspace-id>
  local workspace_id=${1:-}
  [ -n "$workspace_id" ] || {
    echo "error: playbot remove_worktree needs a workspace id" >&2
    return 1
  }
  fm_backend_playbot_tool_check || return 1
  if fm_backend_playbot_lane delete --workspace-id "$workspace_id" >/dev/null; then
    return 0
  fi
  echo "error: playbot workspace delete failed for workspace '$workspace_id'" >&2
  return 1
}

# fm_backend_playbot_endpoint_confirmed_gone: read-only proof that the exact
# task endpoint is gone - the authoritative inventory omits the exact thread
# (plan section 3.7). alive, ambiguous, and unreadable are all NOT gone.
fm_backend_playbot_endpoint_confirmed_gone() {  # <target>
  local thread state
  thread=$(fm_backend_playbot_target_thread "${1:-}") || return 1
  fm_backend_playbot_tool_check 2>/dev/null || return 1
  state=$(fm_backend_playbot_lane agent-state "$thread" 2>/dev/null) || return 1
  [ "$state" = missing ]
}

# fm_backend_playbot_teardown: teardown-authority endpoint retirement (plan
# section 3.7), printing exactly one proof token: retired | retained:<reason> |
# refuse:<reason>. Turn stop, thread archive, and workspace removal are all
# Phase-1-gated mutations, so a live or uncertain endpoint refuses and
# fm-teardown preserves every durable record. An endpoint already gone from the
# authoritative inventory leaves only the gated workspace removal, reported as
# retained:<reason>; the seam then confirms the endpoint is gone through
# fm_backend_playbot_endpoint_confirmed_gone before retiring records with an
# orphan/retention receipt. The adapter never touches meta, routes, outboxes,
# or txn records itself.
fm_backend_playbot_teardown() {  # <meta-file> <task-id> <target> <worktree> <workspace-id> <thread-id> -> proof
  local meta=${1:-} id=${2:-} target=${3:-} worktree=${4:-} workspace_id=${5:-} thread_id=${6:-}
  [ -n "$meta" ] && [ -n "$id" ] && [ -n "$target" ] && [ -n "$workspace_id" ] && [ -n "$thread_id" ] || {
    printf 'refuse:incomplete-task-identity'
    return 1
  }
  [ "$target" = "playbot:$thread_id" ] || { printf 'refuse:target-thread-mismatch'; return 1; }
  fm_backend_playbot_tool_check || { printf 'refuse:adapter-tools-missing'; return 1; }
  local state
  state=$(fm_backend_playbot_lane agent-state "$thread_id" 2>/dev/null) || state=unreadable
  case "$state" in
    missing)
      if fm_backend_playbot_remove_worktree "$workspace_id" >/dev/null 2>&1; then
        printf 'retired'
        return 0
      fi
      printf 'retained:workspace-removal-failed-after-thread-gone'
      return 0
      ;;
    alive|ambiguous)
      if ! fm_backend_playbot_lane stop --thread-id "$thread_id" >/dev/null 2>&1; then
        # stop may fail if already idle; continue to archive
        :
      fi
      if ! fm_backend_playbot_lane archive --thread-id "$thread_id" >/dev/null 2>&1; then
        echo "error: playbot teardown could not archive playbot:$thread_id ($state)" >&2
        printf 'refuse:thread-archive-failed'
        return 1
      fi
      if ! fm_backend_playbot_remove_worktree "$workspace_id" >/dev/null 2>&1; then
        printf 'retained:thread-archived-workspace-removal-failed'
        return 0
      fi
      printf 'retired'
      return 0
      ;;
    *)
      echo "error: playbot teardown refuses unreadable endpoint playbot:$thread_id ($state)" >&2
      printf 'refuse:endpoint-%s-not-confirmed-gone' "$state"
      return 1
      ;;
  esac
}
