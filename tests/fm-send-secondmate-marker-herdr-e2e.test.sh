#!/usr/bin/env bash
# Real Pi/Herdr regression for exact-id secondmate marker delivery.
#
# This is opt-in because it launches a real interactive Pi process and a real
# isolated Herdr lab session.
# It exercises the end-user command shape against metadata written by a real
# fm-spawn.sh --secondmate launch, captures Pi's submitted input bytes,
# and proves both sides of the routing boundary:
#   - exact task id through explicit FM_HOME receives exactly one marker;
#   - direct terminal input remains unmarked;
#   - fm-control exit stops the same idle agent without removing its endpoint.
#
# Every Herdr call, including calls made inside the production backend adapter,
# is routed through bin/fm-herdr-lab.sh. The PATH shim strips only the adapter's
# already-validated trailing --session pair, then delegates to the lab helper,
# which appends its own required trailing --session before invoking real Herdr.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

fm_live_gate opt-in FM_SEND_MARKER_HERDR_E2E git herdr jq pi

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-send-secondmate-marker-v7)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-send-marker-herdr-e2e.XXXXXX")
SENDER_HOME="$TMP_ROOT/sender-home"
SECOND_HOME="$TMP_ROOT/secondmate-home"
CAPTURE="$TMP_ROOT/pi-input.jsonl"
FAKEBIN="$TMP_ROOT/fakebin"
ORIGINAL_PATH=$PATH
REAL_PI=$(command -v pi)
ID='marker-pi-sm'
REQUEST='FM_MARKER_HERDR_E2E exact-id request'
DIRECT='FM_MARKER_HERDR_DIRECT captain input'

cleanup() {
  local rc=$?
  trap - EXIT
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$SENDER_HOME/state" "$SENDER_HOME/data" "$SENDER_HOME/config" "$SENDER_HOME/projects" "$FAKEBIN"

# Route production adapter invocations through the same guarded helper as every
# explicit E2E probe. The helper itself runs with the original PATH, preventing
# recursion into this shim.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
  for arg in "\${args[@]}"; do
    case "\$arg" in
      --session|--session=*) echo "wrapper refused non-trailing session flag" >&2; exit 99 ;;
    esac
  done
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

git clone -q --no-hardlinks "$ROOT" "$SECOND_HOME"
git -C "$SECOND_HOME" checkout -q --detach HEAD
mkdir -p "$SECOND_HOME/state" "$SECOND_HOME/data" "$SECOND_HOME/config" "$SECOND_HOME/projects"
printf '%s\n' "$ID" > "$SECOND_HOME/.fm-secondmate-home"
cat > "$SECOND_HOME/data/charter.md" <<'EOF'
# Isolated marker capture secondmate

You are a task-local secondmate used only for the marker transport regression.
Stay idle and do not initiate work.
EOF

# A separate explicit Pi extension grants session-only project trust, records
# input bytes, and handles them before any provider request.
# The PATH wrapper adds only that test resource while preserving the production
# secondmate launch and its own extension arguments unchanged.
CAPTURE_JSON=$(printf '%s' "$CAPTURE" | jq -Rs .)
CAPTURE_EXTENSION="$TMP_ROOT/fm-send-marker-capture.ts"
cat > "$CAPTURE_EXTENSION" <<EOF
import { appendFileSync } from "node:fs";
const capturePath = $CAPTURE_JSON;
export default function (pi: any) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("input", (event) => {
    appendFileSync(capturePath, \`\${JSON.stringify({ prompt: event.text, hex: Buffer.from(event.text, "utf8").toString("hex") })}\\n\`);
    if (event.text === "/quit") return { action: "continue" };
    return { action: "handled" };
  });
}
EOF
printf '#!/usr/bin/env bash\nexec %q -e %q "$@"\n' "$REAL_PI" "$CAPTURE_EXTENSION" > "$FAKEBIN/pi"
chmod +x "$FAKEBIN/pi"

"$LAB_HELPER" provision "$SESSION"
PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$SECOND_HOME" --secondmate --harness pi --backend herdr >/dev/null

META="$SENDER_HOME/state/$ID.meta"
[ -f "$META" ] || fail "real secondmate spawn did not write exact-id metadata"
[ "$(fm_meta_get "$META" kind)" = secondmate ] || fail "real secondmate metadata did not record kind=secondmate"
TARGET=$(fm_backend_target_of_meta "$META")
PANE=${TARGET#*:}
case "$TARGET" in
  "$SESSION":w*:p*) : ;;
  *) fail "real secondmate metadata recorded an unexpected Herdr target: $TARGET" ;;
esac

wait_for_prompt() { # <needle>
  local needle=$1 _
  for _ in $(seq 1 240); do
    if [ -s "$CAPTURE" ] && jq -e --arg needle "$needle" 'select(.prompt | contains($needle))' "$CAPTURE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_idle() {
  local status composer _ stable=0
  for _ in $(seq 1 240); do
    status=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null \
      | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in
      idle|done)
        composer=$(PATH="$FAKEBIN:$ORIGINAL_PATH" \
          fm_backend_composer_state herdr "$TARGET" 2>/dev/null || true)
        if [ "$composer" = empty ]; then
          stable=$((stable + 1))
          [ "$stable" -ge 4 ] && return 0
        else
          stable=0
        fi
        ;;
      *) stable=0 ;;
    esac
    sleep 0.25
  done
  return 1
}

# The startup charter proves the CLI extension loaded. Wait until the handled
# input has remained idle long enough for the Pi composer to fully settle
# before exercising it. A single native idle sample can precede Pi's final redraw.
wait_for_prompt 'Isolated marker capture secondmate' \
  || fail "real Pi input capture did not load for the startup charter"
wait_for_idle || fail "real Pi did not become idle after the startup capture"

PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" \
  "$ROOT/bin/fm-send.sh" "$ID" "$REQUEST" >/dev/null
if ! wait_for_prompt 'Firstmate instruction waiting:'; then
  printf '%s\n' '--- Pi capture ---' >&2
  sed -n '1,20p' "$CAPTURE" >&2
  printf '%s\n' '--- Herdr pane tail ---' >&2
  "$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200 2>&1 \
    | tail -n 30 >&2
  fail "real Pi did not receive the exact-id fm-send doorbell"
fi
RECORD=$(find "$SENDER_HOME/state/$ID.inbox" -maxdepth 1 -type f -name '*.msg' -print | head -1)
[ -n "$RECORD" ] || fail "exact-id fm-send did not write a durable inbox record"
GOT=$(fm_task_inbox_body "$RECORD") \
  || fail "exact-id fm-send record had no body"
fm_message_from_firstmate "$GOT" \
  || fail "real Pi exact-id record did not begin with the terminal-safe marker"
ROUTED=''
fm_operational_input_body "$GOT" ROUTED \
  || fail "real Pi exact-id record marker could not be parsed"
printf '%s\n' "$ROUTED" | grep -Eq "^corr=[a-f0-9]{16} ${REQUEST}$" \
  || fail "real Pi exact-id record did not contain one correlation plus the exact request"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$GOT" | od -An -tx1)"
case "$ROUTED" in
  *"$FM_FROMFIRST_MARK"*) fail "real Pi exact-id record repeated the terminal-safe marker" ;;
esac
printf 'evidence: exact-id record-body-hex=%s\n' "$(printf '%s' "$GOT" | od -An -tx1 | tr -d ' \n')"
pass "real Pi/Herdr: exact-id FM_HOME send delivers its atomic doorbell and records exactly one from-firstmate marker"
wait_for_idle || fail "real Pi did not become idle after the exact-id doorbell capture"

# Direct terminal input bypasses fm-send's metadata-routed transformation and
# therefore remains conversational captain input.
"$LAB_HELPER" run "$SESSION" pane run "$PANE" "$DIRECT" >/dev/null
wait_for_prompt "$DIRECT" || fail "real Pi did not receive direct terminal input"
GOT=$(jq -r --arg needle "$DIRECT" 'select(.prompt | contains($needle)) | .prompt' "$CAPTURE" | tail -1)
[ "$GOT" = "$DIRECT" ] || fail "direct captain input was changed or marked"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$GOT" | od -An -tx1)"
if fm_message_from_firstmate "$GOT"; then
  fail "direct captain input was classified as from-firstmate"
fi
printf 'evidence: direct-input received-hex=%s\n' "$(printf '%s' "$GOT" | od -An -tx1 | tr -d ' \n')"
pass "real Pi/Herdr: direct captain terminal input stays unmarked"

CONTROL_OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 \
  FM_HOME="$SENDER_HOME" FM_CONTROL_POLL=0.25 FM_CONTROL_EXIT_WAIT=30 \
  "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1) \
  || fail "real Pi lifecycle exit did not stop the idle agent: $CONTROL_OUT"
case "$CONTROL_OUT" in
  *"stopped $ID harness=pi backend=herdr"*) : ;;
  *) fail "real Pi lifecycle exit did not report its verified stopped postcondition: $CONTROL_OUT" ;;
esac
pass "real Pi/Herdr: fm-control submits /quit atomically and verifies the idle agent stopped"
