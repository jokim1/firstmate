#!/usr/bin/env bash
# bin/backends/playbot.sh - the Playbot session-provider adapter (EXPERIMENTAL,
# NOT yet spawn-capable).
#
# Contract owner: plan v3 (data/lanemcp-impl-plan/report.md) section 1.2's
# adapter table and section 4.1's send semantics. Function names follow the
# existing bin/backends/*.sh convention (fm_backend_playbot_*); this file IS
# the interface the shared-core seam (bin/fm-backend.sh, bin/fm-spawn.sh,
# bin/fm-control*.sh, bin/fm-teardown.sh, bin/fm-brief.sh) wires against.
#
# Target string shape: playbot:<thread-id> - the exact Playbot worker thread,
# matching the task meta's window= field (plan section 3.2).
#
# PHASE 1 GATE: the live mutation result shapes (workspace:create result,
# native thread minting, threads:send acceptance evidence, threads:stop proof)
# are not yet proven - the Phase 1 disposable smoke is pending. Every
# mutation-capable function here therefore refuses with a
# PHASE1-EVIDENCE-REQUIRED diagnostic BEFORE any mutation, driven by the
# compatibility manifest's mutationEvidence table in bin/fm-playbot-lanes.mjs.
# Read-only functions (capture, busy state, composer state, target exists,
# recovery-grade agent state, worktree path, endpoint validation) work today
# against the exact persisted Playbot state.

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
  [ -f "$FM_PLAYBOT_LANES" ] || { echo "error: backend=playbot but $FM_PLAYBOT_LANES is missing" >&2; return 1; }
}

# fm_backend_playbot_runtime_check: runtime/compatibility gate for spawn
# intake. Native dispatch requires the manifest's Phase 1 mutation evidence,
# which does not exist yet, so this refuses today with the phase marker; the
# read-only compatibility dimensions stay available through `doctor`.
fm_backend_playbot_runtime_check() {
  fm_backend_playbot_tool_check || return 1
  local out
  if out=$(fm_backend_playbot_lane ready --json --capability native 2>&1); then
    return 0
  fi
  printf '%s\n' "$out" >&2
  echo "error: backend=playbot is not spawn-capable: PHASE1-EVIDENCE-REQUIRED (native dispatch awaits the Phase 1 disposable smoke)" >&2
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

# fm_backend_playbot_create: the native workspace/thread/delivery transaction.
# Playbot owns the task worktree; treehouse allocation must never run for this
# backend. Refused until Phase 1 evidence exists.
fm_backend_playbot_create() {  # <task-id> <project-path>
  echo "error: PHASE1-EVIDENCE-REQUIRED: playbot workspace:create/thread minting awaits the Phase 1 disposable smoke; no workspace was created" >&2
  return 1
}

# fm_backend_playbot_send_initial: initial multiline brief delivery, the final
# stage of the fm-spawn-owned transaction (plan section 3.4 step 7; distinct
# from fm-send's one-line steer contract). Refused until Phase 1.
fm_backend_playbot_send_initial() {  # <task-id> <brief-file>
  echo "error: PHASE1-EVIDENCE-REQUIRED: playbot initial brief delivery awaits the Phase 1 disposable smoke; nothing was sent" >&2
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
# with a stable nonempty diagnostic on stderr. Until Phase 1 proves send
# acceptance evidence, every call refuses BEFORE mutation: a refusal is a
# nonzero exit, which fm-send's enforcement (bin/fm-send.sh:603-619) already
# treats as a loud send failure.
fm_backend_playbot_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local thread
  thread=$(fm_backend_playbot_target_thread "${1:-}") || return 1
  fm_backend_playbot_tool_check || return 1
  echo "error: PHASE1-EVIDENCE-REQUIRED: playbot threads:send acceptance evidence awaits the Phase 1 disposable smoke; text not sent to playbot:$thread" >&2
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

# fm_backend_playbot_interrupt: exact threads:stop only when the current turn
# and route still match, followed by rollout/current-state proof - never a
# broad UI key click (plan sections 1.2 and 3.7). Refused until Phase 1.
fm_backend_playbot_interrupt() {  # <target>
  local thread
  thread=$(fm_backend_playbot_target_thread "${1:-}") || return 1
  echo "error: PHASE1-EVIDENCE-REQUIRED: playbot threads:stop awaits the Phase 1 disposable smoke; no stop was issued to playbot:$thread" >&2
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

# fm_backend_playbot_kill: endpoint retirement is archive-based and
# Phase-1-gated. fm_backend_kill callers treat failure as best-effort, so the
# refusal is reported on stderr for the supervisor while returning nonzero.
fm_backend_playbot_kill() {  # <target>
  local thread
  thread=$(fm_backend_playbot_target_thread "${1:-}") || return 1
  echo "error: PHASE1-EVIDENCE-REQUIRED: playbot thread/workspace archive awaits the Phase 1 disposable smoke; playbot:$thread was not archived" >&2
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

# fm_backend_playbot_remove_worktree: workspace archive/delete is a separately
# verified Playbot IPC operation; until Phase 1 proves it, removal refuses and
# cleanup must retain an explicit orphan/retention receipt (plan section 3.7).
fm_backend_playbot_remove_worktree() {  # <workspace-id>
  echo "error: PHASE1-EVIDENCE-REQUIRED: playbot workspace archive/delete awaits the Phase 1 disposable smoke; workspace '${1:-}' was not removed" >&2
  return 1
}
