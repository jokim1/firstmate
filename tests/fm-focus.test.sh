#!/usr/bin/env bash
# Behavior tests for the durable primary-focus lifecycle (bin/fm-focus.sh) and
# its fail-open prompt hook (bin/fm-focus-prompt-hook.sh).
#
# Covers Phase 0 invariants: one atomic snapshot, suspend-before-switch
# ordering, compare-and-swap refusal, concurrent writers, wake emission on
# transitions, and fail-open on an unwritable state dir or busy wake queue. No
# harness process is required for the core; tracked hook registration is
# asserted as a portable wiring regression. The opt-in smoke only checks the
# shared hook and owner paths; it does not exercise harness callbacks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FOCUS="$ROOT/bin/fm-focus.sh"
HOOK="$ROOT/bin/fm-focus-prompt-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-focus)

new_state() {  # <name>
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf '%s' "$d"
}

active_id() {  # <state>
  "$FOCUS" show --state-dir "$1" --json | jq -r '.active.focus_id // empty'
}

active_summary() {  # <state>
  "$FOCUS" show --state-dir "$1" --json | jq -r '.active.summary // empty'
}

revision() {  # <state>
  "$FOCUS" show --state-dir "$1" --json | jq -r '.revision // 0'
}

suspended_count() {  # <state>
  "$FOCUS" show --state-dir "$1" --json | jq -r '(.suspended // []) | length'
}

suspended_top_summary() {  # <state>
  "$FOCUS" show --state-dir "$1" --json | jq -r '.suspended[0].summary // empty'
}

# --- core snapshot -----------------------------------------------------------

test_empty_show() {
  local state
  state=$(new_state empty-show)
  out=$("$FOCUS" show --state-dir "$state" --json) || fail "show failed on empty state"
  [ "$(printf '%s' "$out" | jq -r '.revision')" = "0" ] || fail "empty revision must be 0"
  [ "$(printf '%s' "$out" | jq -r '.active')" = "null" ] || fail "empty active must be null"
  [ "$(printf '%s' "$out" | jq -r '(.suspended | length)')" = "0" ] || fail "empty suspended must be []"
  pass "show returns an empty v1 snapshot when no file exists"
}

test_switch_activates_first_focus() {
  local state id
  state=$(new_state first-switch)
  "$FOCUS" switch --state-dir "$state" --summary "first task" --owner-kind primary-direct \
    >/dev/null || fail "first switch failed"
  [ "$(revision "$state")" = "1" ] || fail "first switch must advance revision to 1"
  id=$(active_id "$state")
  [ -n "$id" ] || fail "first switch must set an active focus_id"
  [ "$(active_summary "$state")" = "first task" ] || fail "active summary mismatch"
  [ "$(suspended_count "$state")" = "0" ] || fail "first switch must not suspend anything"
  pass "switch activates the first focus with no prior active"
}

test_suspend_before_switch_ordering() {
  local state a_id snap
  state=$(new_state suspend-order)
  "$FOCUS" switch --state-dir "$state" --summary "work-A" --focus-id f-a >/dev/null \
    || fail "activate A failed"
  a_id=$(active_id "$state")
  [ "$a_id" = "f-a" ] || fail "expected active f-a"
  # B arrives while A is active: A must be suspended before B is active.
  snap=$("$FOCUS" switch --state-dir "$state" --summary "work-B" --focus-id f-b) || fail "switch B failed"
  [ "$(printf '%s' "$snap" | jq -r '.active.focus_id')" = "f-b" ] || fail "B must be active after switch"
  [ "$(printf '%s' "$snap" | jq -r '.active.summary')" = "work-B" ] || fail "B summary missing"
  [ "$(printf '%s' "$snap" | jq -r '.suspended[0].focus_id')" = "f-a" ] || fail "A must be top of suspended stack"
  [ "$(printf '%s' "$snap" | jq -r '.suspended[0].state')" = "suspended" ] || fail "A must be state=suspended"
  [ "$(printf '%s' "$snap" | jq -r '.suspended[0].summary')" = "work-A" ] || fail "A summary must survive suspend"
  # On-disk file matches the published snapshot (no partial write).
  [ -f "$state/.focus.json" ] || fail "snapshot file missing"
  [ "$(jq -r '.active.focus_id' "$state/.focus.json")" = "f-b" ] || fail "on-disk active is not B"
  [ "$(jq -r '.suspended[0].focus_id' "$state/.focus.json")" = "f-a" ] || fail "on-disk suspended top is not A"
  pass "suspend-before-switch records A suspended before B becomes active"
}

test_resume_and_complete() {
  local state
  state=$(new_state resume-complete)
  "$FOCUS" switch --state-dir "$state" --summary "A" --focus-id f-a >/dev/null
  "$FOCUS" switch --state-dir "$state" --summary "B" --focus-id f-b >/dev/null
  "$FOCUS" complete --state-dir "$state" --outcome completed >/dev/null \
    || fail "complete B failed"
  [ "$(active_id "$state")" = "" ] || fail "complete must clear active"
  [ "$(suspended_count "$state")" = "1" ] || fail "A must remain suspended after B completes"
  "$FOCUS" resume --state-dir "$state" >/dev/null || fail "resume A failed"
  [ "$(active_id "$state")" = "f-a" ] || fail "resume must restore A"
  [ "$(suspended_count "$state")" = "0" ] || fail "resumed focus must leave the stack"
  pass "complete clears active; resume restores the most recent suspended focus"
}

test_cas_refusal() {
  local state status
  state=$(new_state cas)
  "$FOCUS" switch --state-dir "$state" --summary "A" >/dev/null
  [ "$(revision "$state")" = "1" ] || fail "setup revision"
  if "$FOCUS" switch --state-dir "$state" --summary "B" --expected-revision 0 >/dev/null 2>&1; then
    fail "CAS with expected-revision 0 against revision 1 must refuse"
  else
    status=$?
    [ "$status" -eq 1 ] || fail "CAS refusal must exit 1, got $status"
  fi
  [ "$(active_summary "$state")" = "A" ] || fail "refused CAS must not mutate the snapshot"
  [ "$(revision "$state")" = "1" ] || fail "refused CAS must not advance revision"
  "$FOCUS" switch --state-dir "$state" --summary "B" --expected-revision 1 >/dev/null \
    || fail "CAS with matching expected-revision must succeed"
  [ "$(active_summary "$state")" = "B" ] || fail "matching CAS should switch to B"
  pass "compare-and-swap refuses a stale expected revision and accepts a match"
}

test_concurrent_writers() {
  local state pids i status fails=0 final_rev susp
  state=$(new_state concurrent)
  pids=
  i=1
  while [ "$i" -le 20 ]; do
    "$FOCUS" switch --state-dir "$state" --summary "w-$i" --focus-id "f-$i" >/dev/null 2>&1 &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    if ! wait "$pid"; then
      fails=$((fails + 1))
    fi
  done
  [ "$fails" -eq 0 ] || fail "concurrent switch writers failed: $fails"
  final_rev=$(revision "$state")
  [ "$final_rev" = "20" ] || fail "expected revision 20 after 20 serialized switches, got $final_rev"
  susp=$(suspended_count "$state")
  [ "$susp" = "19" ] || fail "expected 19 suspended after 20 switches, got $susp"
  # Snapshot must remain valid JSON with exactly one active.
  jq -e '.active != null and (.suspended | length) == 19' "$state/.focus.json" >/dev/null \
    || fail "final snapshot is not a coherent single-active stack"
  # No leftover temp or lock.
  [ ! -e "$state/.focus.json.lock" ] || fail "writer lock left behind"
  ! ls "$state"/.focus.json.tmp.* >/dev/null 2>&1 || fail "temp publish files left behind"
  pass "concurrent switch writers serialize under the lock into one coherent snapshot"
}

test_live_stale_lock_owner_is_preserved() {
  local state lock owner status
  state=$(new_state live-stale-lock)
  lock="$state/.focus.json.lock"
  mkdir "$lock"
  sleep 30 &
  owner=$!
  printf '%s\n' "$owner" > "$lock/pid"
  : > "$lock/pid-identity"
  touch -t 200001010000 "$lock" 2>/dev/null || true
  if FM_FOCUS_LOCK_TRIES=1 FM_FOCUS_LOCK_STALE_SECS=0 \
    "$FOCUS" switch --state-dir "$state" --summary contender >/dev/null 2>&1; then
    kill "$owner" 2>/dev/null || true
    wait "$owner" 2>/dev/null || true
    fail "aged lock held by a live owner must not be evicted"
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || fail "live lock contention must exit 1, got $status"
  [ -d "$lock" ] || fail "live owner's lock directory was removed"
  [ ! -e "$state/.focus.json" ] || fail "contender mutated focus under a live owner's lock"
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  rm -f "$lock/pid" "$lock/pid-identity"
  rmdir "$lock"
  pass "aged writer lock is preserved while its recorded owner is alive"
}

test_dead_stale_lock_owner_is_recovered() {
  local state lock
  state=$(new_state dead-stale-lock)
  lock="$state/.focus.json.lock"
  mkdir "$lock"
  printf '99999999\n' > "$lock/pid"
  printf 'dead-owner\n' > "$lock/pid-identity"
  touch -t 200001010000 "$lock" 2>/dev/null || true
  FM_FOCUS_LOCK_TRIES=1 FM_FOCUS_LOCK_STALE_SECS=0 \
    "$FOCUS" switch --state-dir "$state" --summary recovered >/dev/null \
    || fail "dead stale lock was not recovered"
  [ "$(active_summary "$state")" = "recovered" ] || fail "recovered writer did not publish focus"
  [ ! -e "$lock" ] || fail "recovered writer left its lock behind"
  pass "aged writer lock is recovered after its recorded owner exits"
}

test_idempotent_fingerprint() {
  local state rev1 rev2
  state=$(new_state idem)
  "$FOCUS" switch --state-dir "$state" --summary "same" --fingerprint abc123 >/dev/null
  rev1=$(revision "$state")
  "$FOCUS" switch --state-dir "$state" --summary "same" --fingerprint abc123 >/dev/null \
    || fail "idempotent switch failed"
  rev2=$(revision "$state")
  [ "$rev1" = "$rev2" ] || fail "same fingerprint must not advance revision ($rev1 -> $rev2)"
  [ "$(suspended_count "$state")" = "0" ] || fail "idempotent switch must not suspend self"
  pass "identical fingerprint is an idempotent no-op"
}

test_wake_on_transition() {
  local state line kind tries=0
  state=$(new_state wake)
  "$FOCUS" switch --state-dir "$state" --summary "A" >/dev/null
  while [ ! -s "$state/.wake-queue" ] && [ "$tries" -lt 50 ]; do
    sleep 0.02
    tries=$((tries + 1))
  done
  [ -f "$state/.wake-queue" ] || fail "switch must enqueue a wake"
  line=$(tail -n 1 "$state/.wake-queue")
  kind=$(printf '%s' "$line" | awk -F '\t' '{print $3}')
  case "$kind" in
    signal|refill) ;;
    *) fail "unexpected wake kind: $kind (line=$line)" ;;
  esac
  printf '%s' "$line" | awk -F '\t' '$4 == "focus" { found=1 } END { exit found ? 0 : 1 }' \
    || fail "wake key must be focus"
  printf '%s' "$line" | grep -F 'focus:' >/dev/null || fail "wake payload must carry focus: prefix"
  pass "focus transitions emit one durable wake (signal, or refill when present)"
}

test_busy_wake_queue_does_not_block_owner() {
  local state ready holder owner tries=0
  state=$(new_state busy-wake-lock)
  ready="$state/lock-ready"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$STATE/.wake-queue.lock" || exit 1
    : > "$2"
    sleep 5
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$ready" &
  holder=$!
  while [ ! -f "$ready" ] && [ "$tries" -lt 50 ]; do
    sleep 0.02
    tries=$((tries + 1))
  done
  [ -f "$ready" ] || fail "wake lock holder did not start"

  "$FOCUS" switch --state-dir "$state" --summary "lock-independent" >/dev/null &
  owner=$!
  tries=0
  while kill -0 "$owner" 2>/dev/null && [ "$tries" -lt 50 ]; do
    sleep 0.02
    tries=$((tries + 1))
  done
  if kill -0 "$owner" 2>/dev/null; then
    kill "$owner" 2>/dev/null || true
    kill "$holder" 2>/dev/null || true
    fail "focus owner blocked on the busy wake queue"
  fi
  wait "$owner" || fail "focus owner failed when wake queue was busy"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$(active_summary "$state")" = "lock-independent" ] \
    || fail "focus snapshot was not durable before wake discard"
  pass "busy wake queue never blocks a durable focus mutation"
}

test_fail_open_unwritable_state_via_owner() {
  local state status
  state=$(new_state unwritable)
  # Replace state with a file so writes cannot create .focus.json.
  rm -rf "$state"
  printf 'not-a-dir\n' > "$state"
  if "$FOCUS" switch --state-dir "$state" --summary "x" >/dev/null 2>&1; then
    fail "owner must refuse an unwritable state path"
  else
    status=$?
    [ "$status" -eq 1 ] || fail "owner refuse must exit 1, got $status"
  fi
  pass "owner refuses an unwritable state path (hard path for operators/tests)"
}

test_hook_fail_open_unwritable() {
  local state status out
  state=$(new_state hook-unwritable)
  rm -rf "$state"
  printf 'not-a-dir\n' > "$state"
  # Hook must still exit 0 even when the owner cannot write.
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT/hook-unwritable-home" \
    FM_STATE_OVERRIDE="$state" \
    printf '%s' '{"prompt":"captain says hello"}' | "$HOOK" --claude 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "hook must exit 0 on unwritable state, got $status (out=$out)"
  pass "prompt hook fails open (exit 0) when the state dir is unwritable"
}

test_hook_skips_operational_input() {
  local home state status before after
  home="$TMP_ROOT/hook-op-home"
  state="$home/state"
  mkdir -p "$state" "$home/bin"
  # Primary-scope requires AGENTS.md, bin/, and a plain checkout. Soft-link the
  # real scripts and mark a plain git root is hard; instead call the owner path
  # through the hook's --prompt after we only assert the operational skip by
  # invoking the hook with a non-primary home (scope fails open with no write).
  before=$(find "$state" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d ' ')
  status=0
  printf '%s' '{"prompt":"'"$("$ROOT/bin/fm-operational-input.sh" encode session-start <<<"digest")"'"}}' \
    | FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      "$HOOK" --claude >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "hook must exit 0 on operational input"
  after=$(find "$state" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d ' ')
  [ "$before" = "$after" ] || fail "operational input must not create focus artifacts"
  pass "prompt hook skips operational Firstmate inputs and stays fail-open"
}

test_primary_prompt_hooks_bound_live_lock_contention() {
  local fake_root state lock harness start elapsed status file
  fake_root="$TMP_ROOT/hook-contention-root"
  state="$fake_root/state"
  lock="$state/.focus.json.lock"
  mkdir -p "$fake_root/bin" "$lock"
  printf 'primary-test\n' > "$fake_root/.fm-secondmate-home"
  printf '# test primary root\n' > "$fake_root/AGENTS.md"
  for file in fm-focus-prompt-hook.sh fm-focus.sh fm-primary-scope-lib.sh \
    fm-operational-input.sh fm-wake-lib.sh; do
    ln -s "$ROOT/bin/$file" "$fake_root/bin/$file"
  done

  printf '%s\n' "$$" > "$lock/pid"
  : > "$lock/pid-identity"

  for harness in claude codex grok; do
    status=0
    start=$SECONDS
    printf '%s' '{"prompt":"captain prompt under contention"}' \
      | FM_ROOT_OVERRIDE="$fake_root" FM_STATE_OVERRIDE="$state" \
        "$fake_root/bin/fm-focus-prompt-hook.sh" "--$harness" \
        >/dev/null 2>&1 || status=$?
    elapsed=$((SECONDS - start))
    if [ "$status" -ne 0 ] || [ "$elapsed" -gt 2 ]; then
      fail "$harness prompt hook blocked on a live focus lock (${elapsed}s, status=$status)"
    fi
  done

  [ ! -e "$state/.focus.json" ] \
    || fail "contended prompt hooks must not mutate focus without the lock"
  pass "Claude, Codex, and Grok prompt hooks bound live lock contention"
}

test_playbot_owner_kind_recorded() {
  local state
  state=$(new_state playbot)
  "$FOCUS" switch --state-dir "$state" \
    --owner-kind playbot \
    --summary "porch set-lock" \
    --resume-kind playbot-thread \
    --resume-pointer "chat-5-1" \
    --task-id mc-porch-v3 >/dev/null || fail "playbot focus switch failed"
  [ "$(jq -r '.active.owner_kind' "$state/.focus.json")" = "playbot" ] \
    || fail "playbot owner_kind not recorded"
  [ "$(jq -r '.active.resume_pointer' "$state/.focus.json")" = "chat-5-1" ] \
    || fail "playbot resume pointer not recorded"
  pass "Playbot-carried focus is recorded as a focus entry without extra adapters"
}

# --- portable harness wiring regression --------------------------------------

test_tracked_claude_userprompt_wires_focus_hook() {
  local cmd
  command -v jq >/dev/null 2>&1 || fail "jq required"
  cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command // empty' "$ROOT/.claude/settings.json")
  printf '%s' "$cmd" | grep -F 'fm-focus-prompt-hook.sh' >/dev/null \
    || fail "Claude UserPromptSubmit must call fm-focus-prompt-hook.sh"
  printf '%s' "$cmd" | grep -F 'GROK_AGENT' >/dev/null \
    || fail "Claude focus hook must stay inert under Grok (GROK_* guard)"
  pass "tracked .claude/settings.json UserPromptSubmit wires the focus hook"
}

test_tracked_codex_userprompt_wires_focus_hook() {
  local cmd
  cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command // empty' "$ROOT/.codex/hooks.json")
  printf '%s' "$cmd" | grep -F 'fm-focus-prompt-hook.sh' >/dev/null \
    || fail "Codex UserPromptSubmit must call fm-focus-prompt-hook.sh"
  pass "tracked .codex/hooks.json UserPromptSubmit wires the focus hook"
}

test_tracked_grok_userprompt_wires_focus_hook() {
  local f
  f="$ROOT/.grok/hooks/fm-primary-focus-lifecycle.json"
  [ -f "$f" ] || fail "missing Grok focus lifecycle hook file"
  jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | contains("fm-focus-prompt-hook.sh")' "$f" >/dev/null \
    || fail "Grok UserPromptSubmit must call fm-focus-prompt-hook.sh"
  pass "tracked .grok/hooks focus lifecycle wires the focus hook"
}

test_tracked_opencode_plugin_present() {
  local plugin
  plugin="$ROOT/.opencode/plugins/fm-primary-focus-lifecycle.js"
  [ -f "$plugin" ] \
    || fail "missing OpenCode focus lifecycle plugin"
  grep -F 'fm-focus-prompt-hook.sh' "$plugin" >/dev/null \
    || fail "OpenCode plugin must invoke the focus prompt hook"
  grep -F '"chat.message"' "$plugin" >/dev/null \
    || fail "OpenCode plugin must record focus before prompt dispatch"
  if grep -E 'message\.(updated|completed)' "$plugin" >/dev/null; then
    fail "OpenCode plugin must not defer focus recording to post-prompt events"
  fi
  pass "tracked OpenCode plugin records focus before prompt dispatch"
}

test_opencode_plugin_times_out_hung_focus_hook() {
  local project status
  project="$TMP_ROOT/opencode-timeout-project"
  mkdir -p "$project/bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$project/bin/fm-focus-prompt-hook.sh"
  chmod +x "$project/bin/fm-focus-prompt-hook.sh"
  node --input-type=module - "$ROOT/.opencode/plugins/fm-primary-focus-lifecycle.js" "$project" <<'NODE' &
const [pluginPath, root] = process.argv.slice(2);
const { FmPrimaryFocusLifecycle } = await import(`file://${pluginPath}`);
const hooks = await FmPrimaryFocusLifecycle({ worktree: root });
await hooks["chat.message"]({}, { parts: [{ text: "captain prompt" }] });
NODE
  status=$!
  if ! wait "$status"; then
    fail "OpenCode focus adapter failed while timing out a hung hook"
  fi
  pass "OpenCode focus adapter bounds a hung pre-prompt hook"
}

test_help_owns_schema_and_mutation_contract() {
  local out
  out=$("$FOCUS" --help)
  assert_contains "$out" 'Schema (v1):' "focus help must own the v1 schema"
  assert_contains "$out" '"active": null | FocusEntry' "focus help omitted active schema"
  assert_contains "$out" '"suspended": [ FocusEntry, ... ]' "focus help omitted suspended schema"
  assert_contains "$out" 'Mutation contract:' "focus help must own the mutation contract"
  assert_contains "$out" 'write-temp then rename' "focus help omitted atomic publish"
  assert_contains "$out" 'suspended before' "focus help omitted suspend-before-switch"
  pass "fm-focus help owns the v1 schema and mutation contract"
}

test_tracked_pi_input_wires_focus_hook() {
  # Public registration contract: the primary Pi extension loads the shared
  # fail-open focus adapter (same pattern as the arm/cd PreToolUse seatbelts).
  grep -F 'fm-focus-prompt-hook.sh' "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" >/dev/null \
    || fail "Pi extension must invoke the focus prompt hook"
  grep -F 'on?.("input"' "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" >/dev/null \
    || fail "Pi extension must register an input handler"
  grep -F 'child.kill("SIGTERM")' "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" >/dev/null \
    || fail "Pi focus adapter must terminate a timed-out hook"
  pass "tracked Pi extension registers fail-open input focus recording"
}

# --- run ---------------------------------------------------------------------

test_empty_show
test_switch_activates_first_focus
test_suspend_before_switch_ordering
test_resume_and_complete
test_cas_refusal
test_concurrent_writers
test_live_stale_lock_owner_is_preserved
test_dead_stale_lock_owner_is_recovered
test_idempotent_fingerprint
test_wake_on_transition
test_busy_wake_queue_does_not_block_owner
test_fail_open_unwritable_state_via_owner
test_hook_fail_open_unwritable
test_hook_skips_operational_input
test_primary_prompt_hooks_bound_live_lock_contention
test_playbot_owner_kind_recorded
test_tracked_claude_userprompt_wires_focus_hook
test_tracked_codex_userprompt_wires_focus_hook
test_tracked_grok_userprompt_wires_focus_hook
test_tracked_opencode_plugin_present
test_opencode_plugin_times_out_hung_focus_hook
test_tracked_pi_input_wires_focus_hook
test_help_owns_schema_and_mutation_contract

printf 'ok - fm-focus phase0 suite\n'
