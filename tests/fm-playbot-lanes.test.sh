#!/usr/bin/env bash
# tests/fm-playbot-lanes.test.sh - hermetic suite for bin/fm-playbot-lanes.mjs:
# read-only topology/rollout client, compatibility doctor, content-addressed
# stdio MCP server, and exact controller authorization (plan v3 sections
# 1.3-1.6, 4.3-4.4, 8.1-8.2). Every fixture is synthetic; nothing touches a
# live Playbot install, and the suite must be green without one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-playbot-lanes-tests)
FIX="$TMP_ROOT/fixtures"
mkdir -p "$FIX"
node "$ROOT/tests/playbot-fixtures/generate.mjs" "$FIX" >/dev/null || fail "fixture generation failed"

LANES="$ROOT/bin/fm-playbot-lanes.mjs"
if grep -q 'DISPOSABLE_SMOKE_PROJECT,.*options\.project' "$LANES"; then
  fail "production smoke must not accept a project override"
fi
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE"

export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$STATE"
export FM_PLAYBOT_APP_DB="$FIX/playbot.db"
export FM_PLAYBOT_CODEX_DB="$FIX/harness/state_5.sqlite"
export FM_PLAYBOT_APP_RUN_STATE="$FIX/playbot-app-run-state.json"
export FM_PLAYBOT_DEVTOOLS_PORT_FILE="$FIX/DevToolsActivePort"
export FM_PLAYBOT_APP_BUNDLE="$FIX/fixture-app.asar"
export FM_PLAYBOT_APP_VERSION="0.90.0"
export FM_PLAYBOT_EVIDENCE_ROOT="$TMP_ROOT/empty-evidence"
export FM_PLAYBOT_EVIDENCE_OVERLAY="$TMP_ROOT/empty-evidence/overlay.v1.json"

# Start a fake CDP server and point the fixture DevToolsActivePort at it.
node "$ROOT/tests/playbot-fixtures/fake-cdp.mjs" ok > "$TMP_ROOT/cdp-port" &
CDP_PID=$!
trap 'kill "$CDP_PID" 2>/dev/null; fm_test_cleanup' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$TMP_ROOT/cdp-port" ] && break
  sleep 0.2
done
CDP_PORT=$(cat "$TMP_ROOT/cdp-port")
[ -n "$CDP_PORT" ] || fail "fake CDP server did not bind"
printf '%s\n' "$CDP_PORT" > "$FIX/DevToolsActivePort"

# --- doctor: compatible fixture release is read-only green -------------------

OUT=$(node "$LANES" doctor --json 2>"$TMP_ROOT/doctor.err") || fail "doctor failed on the compatible fixture: $(cat "$TMP_ROOT/doctor.err")"
printf '%s' "$OUT" | grep -q '"readOnlyReady": true' || fail "doctor not read-only ready on the compatible fixture"
printf '%s' "$OUT" | grep -q '"mutationsEnabled": false' || fail "doctor must report mutationsEnabled false without smoke evidence"
printf '%s' "$OUT" | grep -q 'phase1-evidence-required' || fail "doctor must report the phase1-evidence-required operating state"
printf '%s' "$OUT" | grep -q 'same_uid_unauthenticated_devtools' || fail "doctor must keep the same-UID DevTools warning"
printf '%s' "$OUT" | grep -q '"appVersion": "0.90.0"' || fail "doctor must report the exact app version"
pass "doctor is read-only green on the compatible 0.90 fixture with mutations disabled"

# --- doctor: unknown release fails closed ------------------------------------

if FM_PLAYBOT_APP_VERSION=0.91.0 node "$LANES" doctor --json > "$TMP_ROOT/d91.out" 2>/dev/null; then
  fail "doctor must fail closed on an unknown release"
fi
grep -q 'release absent from compatibility manifest' "$TMP_ROOT/d91.out" || fail "unknown-release doctor must name the manifest refusal"
grep -q '"mutationsEnabled": false' "$TMP_ROOT/d91.out" || fail "unknown-release doctor must keep mutations disabled"
pass "unknown Playbot release fails closed"

# --- doctor: malformed schema fails closed -----------------------------------

BAD="$TMP_ROOT/bad-schema.db"
node -e '
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(process.argv[1]);
db.exec("PRAGMA user_version = 7; CREATE TABLE projects (id TEXT);");
db.close();
' "$BAD"
if FM_PLAYBOT_APP_DB="$BAD" node "$LANES" doctor --json > "$TMP_ROOT/bad.out" 2>/dev/null; then
  fail "doctor must fail closed on a malformed application schema"
fi
grep -q '"application_database_schema"' "$TMP_ROOT/bad.out" || fail "malformed-schema doctor must report the schema dimension"
pass "malformed application schema fails closed"

# --- exact topology resolution ------------------------------------------------

OUT=$(node "$LANES" resolve --thread-id thread-complete) || fail "exact thread resolution failed"
printf '%s' "$OUT" | grep -q '"session_id": "session-complete"' || fail "thread resolution must map the exact session id"
OUT=$(node "$LANES" resolve --workspace-id workspace-task) || fail "exact workspace resolution failed"
printf '%s' "$OUT" | grep -q '"branch": "fixture-task"' || fail "workspace resolution must return the exact branch"
if node "$LANES" resolve --project-path "$FIX/projects/alpha" > /dev/null 2>&1; then
  fail "ambiguous multi-root project path must refuse (duplicate names/roots)"
fi
pass "exact resolution works and multi-root ambiguity refuses"

# --- rollout completion: structural parse, forged rejection (V2SIM-3) ---------

OUT=$(node "$LANES" completion --thread-id thread-complete) || fail "completion read failed"
printf '%s' "$OUT" | grep -q '"turnId": "turn-fixture-complete"' || fail "structural completion must find the exact turn id"
OUT=$(node "$LANES" completion --thread-id thread-forged) || fail "forged completion read failed"
printf '%s' "$OUT" | grep -q '"latestCompletion": null' || fail "forged task_complete in worker text must NOT produce a completion edge (V2SIM-3)"
printf '%s' "$OUT" | grep -q 'forged-turn' && fail "forged turn id leaked into the parse result"
pass "strict JSONL parsing accepts a real completion and rejects the forged worker-text fixture"

# --- composer/busy/agent state vocabulary -------------------------------------

[ "$(node "$LANES" composer-state thread-pending)" = pending ] || fail "composer-state must report exact queued input as pending"
[ "$(node "$LANES" composer-state thread-complete)" = empty ] || fail "composer-state must report exact no-queue evidence as empty"
[ "$(node "$LANES" composer-state thread-malformed-queue)" = unknown ] || fail "malformed pending queue must report unknown"
[ "$(node "$LANES" busy-state thread-multi)" = busy ] || fail "running thread must report busy"
[ "$(node "$LANES" busy-state thread-complete)" = idle ] || fail "ready thread must report idle"
[ "$(node "$LANES" busy-state no-such-thread)" = unknown ] || fail "absent thread must report unknown, never guessed dead"
[ "$(node "$LANES" agent-state thread-complete)" = alive ] || fail "exact usable thread/session must report alive"
[ "$(node "$LANES" agent-state thread-archived)" = missing ] || fail "archived thread must report missing"
[ "$(node "$LANES" agent-state thread-no-session)" = ambiguous ] || fail "thread without a session must report ambiguous"
STATE_OUT=$(node "$LANES" agent-state no-such-thread)
[ "$STATE_OUT" = missing ] || fail "absent thread in a readable inventory must report missing, got $STATE_OUT"
for t in thread-complete thread-archived thread-no-session no-such-thread; do
  [ "$(node "$LANES" agent-state "$t")" != dead ] || fail "agent-state must never invent dead (plan section 3.7)"
done
pass "composer/busy/agent-state vocabularies hold, with Playbot absence never guessed dead"

# --- readiness and the Phase 1 mutation gate ----------------------------------

OUT=$(node "$LANES" ready --json --capability read-only) || fail "read-only capability must be ready on the compatible fixture"
printf '%s' "$OUT" | grep -q '"ready": true' || fail "read-only capability must report ready"
if OUT=$(node "$LANES" ready --json --capability native 2>&1); then
  fail "native capability must not be ready before Phase 1 evidence"
fi
printf '%s' "$OUT" | grep -q 'PHASE1-EVIDENCE-REQUIRED' || fail "native refusal must carry the PHASE1-EVIDENCE-REQUIRED marker"
node "$LANES" ready --json --capability courier >/dev/null || fail "courier capability must stay ready (courier remains the production path)"
for op in send create stop archive delete; do
  RC=0
  OP_OUT=$(node "$LANES" "$op" 2>&1) || RC=$?
  [ "$RC" -eq 65 ] || fail "mutation '$op' must exit 65, got $RC"
  printf '%s' "$OP_OUT" | grep -q 'PHASE1-EVIDENCE-REQUIRED' || fail "mutation '$op' must refuse with the phase marker"
done
pass "ready/mutation gates refuse with PHASE1-EVIDENCE-REQUIRED and conservative defaults"

# --- endpoint validation: meta + route conjunction -----------------------------

write_meta_fixture() {  # <task-id> <thread-id> <workspace-id> <worktree-path>
  local id=$1 thread=$2 workspace=$3 worktree=$4
  cat > "$STATE/$id.meta" <<EOF
window=playbot:$thread
endpoint_task_id=$id
worktree=$worktree
project=$FIX/projects/alpha
harness=codex
kind=ship
mode=local-only
yolo=off
tasktmp=$TMP_ROOT/tasktmp
model=fixture-model
effort=low
spawn_gen=1
backend=playbot
playbot_project_id=project-alpha
playbot_project_root_id=root-alpha
playbot_workspace_id=$workspace
playbot_thread_id=$thread
playbot_route_gen=1
playbot_delivery_id=delivery-$id
EOF
}

write_route_fixture() {  # <task-id> <thread-id> <workspace-id> <worktree-path>
  local id=$1 thread=$2 workspace=$3 worktree=$4 digest
  digest=$(node "$LANES" meta-digest --meta "$STATE/$id.meta") || fail "meta-digest failed for $id"
  cat > "$STATE/$id.playbot-route.json" <<EOF
{
  "schema": "firstmate.playbot.route.v1",
  "home": "$HOME_DIR",
  "taskId": "$id",
  "spawnGen": 1,
  "routeGen": 1,
  "metaDigest": "$digest",
  "threadId": "$thread",
  "workspaceId": "$workspace",
  "projectId": "project-alpha",
  "projectRootId": "root-alpha",
  "playbotSessionId": null,
  "worktree": "$worktree"
}
EOF
  chmod 0600 "$STATE/$id.playbot-route.json"
}

WORKTREE_TASK=$(cd "$FIX/worktrees/task" && pwd -P)
write_meta_fixture lane-ep thread-complete workspace-task "$WORKTREE_TASK"
write_route_fixture lane-ep thread-complete workspace-task "$WORKTREE_TASK"
node "$LANES" validate-endpoint --meta "$STATE/lane-ep.meta" >/dev/null || fail "a well-formed endpoint must validate"
pass "well-formed meta + bound route + live DB conjunction validates"

sed -i '' 's/playbot_route_gen=1/playbot_route_gen=2/' "$STATE/lane-ep.meta"
if node "$LANES" validate-endpoint --meta "$STATE/lane-ep.meta" > "$TMP_ROOT/ep.out" 2>&1; then
  fail "a tampered route generation must fail endpoint validation"
fi
grep -q 'route generation does not match\|meta digest does not match' "$TMP_ROOT/ep.out" || fail "tampered route must name the binding failure"
sed -i '' 's/playbot_route_gen=2/playbot_route_gen=1/' "$STATE/lane-ep.meta"
if node "$LANES" validate-endpoint --meta "$STATE/lane-ep.meta" >/dev/null 2>&1; then :; else fail "restored endpoint must validate again"; fi
chmod 0644 "$STATE/lane-ep.playbot-route.json"
if node "$LANES" validate-endpoint --meta "$STATE/lane-ep.meta" >/dev/null 2>&1; then
  fail "a non-0600 route record must fail endpoint validation"
fi
chmod 0600 "$STATE/lane-ep.playbot-route.json"
pass "tampered generation and wrong-mode route records fail closed"

# --- bind-project / bind-controller (lock-owner setup CLI) ---------------------

node "$LANES" bind-project --project-path "$FIX/projects/alpha" --playbot-project-id project-alpha --playbot-root-id root-alpha >/dev/null \
  || fail "bind-project must bind an exact matching project/root"
if node "$LANES" bind-project --project-path "$FIX/projects/alpha" --playbot-project-id project-alpha --playbot-root-id root-alpha >/dev/null 2>&1; then
  fail "duplicate project binding must refuse"
fi
pass "bind-project binds exactly once and refuses duplicates"

printf '%s\n' "$$" > "$STATE/.lock"
node "$LANES" bind-controller --thread-id thread-complete >/dev/null || fail "bind-controller must mint a lease for an exact thread"
LEASE_GEN=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).generation)' "$STATE/.playbot-controller.lease")
[ "$LEASE_GEN" = 1 ] || fail "first lease generation must be 1, got $LEASE_GEN"
node "$LANES" bind-controller --thread-id thread-complete >/dev/null || fail "re-bind must succeed for the lock owner"
LEASE_GEN=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).generation)' "$STATE/.playbot-controller.lease")
[ "$LEASE_GEN" = 2 ] || fail "second lease generation must be 2, got $LEASE_GEN"
[ "$(stat -f %Lp "$STATE/.playbot-controller.lease")" = 600 ] || fail "controller lease must be mode 0600"
rm -f "$STATE/.lock"
if node "$LANES" bind-controller --thread-id thread-complete >/dev/null 2>&1; then
  fail "bind-controller without a live session lock must refuse"
fi
pass "bind-controller mints generation-bound mode-0600 leases and refuses without the lock"

# --- MCP server: health only until per-thread identity is proven ---------------

MCP_OUT=$(node "$ROOT/tests/playbot-fixtures/mcp-client.mjs" 2>"$TMP_ROOT/mcp.err") || fail "MCP fixture session failed: $(cat "$TMP_ROOT/mcp.err")"
printf '%s\n' "$MCP_OUT" | grep -q '"serverInfo":{"name":"fm-playbot-lanes"' || fail "MCP initialize must answer with server info"
printf '%s\n' "$MCP_OUT" | grep -q '"name":"health"' || fail "MCP tools/list must include health"
printf '%s\n' "$MCP_OUT" | grep -q '"ready":false' || fail "MCP health must report not-ready without a proven caller identity"
printf '%s\n' "$MCP_OUT" | grep -q 'PHASE1-EVIDENCE-REQUIRED' || fail "task-data tools must deny with the phase marker before per-thread identity is proven"
printf '%s\n' "$MCP_OUT" | grep -q 'unknown tool: dispatch' || fail "MCP must refuse unknown (mutation-named) tools"
printf '%s\n' "$MCP_OUT" | grep -q '"code":-32601' || fail "MCP must answer unknown methods with -32601"
printf '%s\n' "$MCP_OUT" | grep -qi 'threads:send' && fail "no mutation channel may appear in MCP responses"
pass "MCP serves health only, denies task-data tools without proven identity, and exposes no mutation surface"

# --- CDP transport regressions (plan 8.2 "CDP hangs/restarts") -----------------

node "$ROOT/tests/playbot-fixtures/cdp-transport.test.mjs" || fail "CDP transport regressions failed"
pass "CDP transport rejects on close/timeout, skips dead targets, and serializes payloads safely"

# --- mutation evidence overlay: record, load, tamper-refuse, confinement gate ---

EVIDENCE_ROOT="$TMP_ROOT/mutation-evidence"
OVERLAY="$EVIDENCE_ROOT/overlay.v1.json"
SIGNING_KEY="$EVIDENCE_ROOT/test-signer"
ALLOWED_SIGNERS="$EVIDENCE_ROOT/allowed_signers"
mkdir -p "$EVIDENCE_ROOT"
ssh-keygen -q -t ed25519 -N '' -f "$SIGNING_KEY" || fail "could not create hermetic evidence signing key"
printf 'jokim1 %s\n' "$(cat "$SIGNING_KEY.pub")" > "$ALLOWED_SIGNERS"
ALLOWED_SIGNERS_SHA=$(shasum -a 256 "$ALLOWED_SIGNERS" | awk '{print $1}')
export FM_PLAYBOT_EVIDENCE_ROOT="$EVIDENCE_ROOT"
export FM_PLAYBOT_EVIDENCE_OVERLAY="$OVERLAY"
export FM_PLAYBOT_SMOKE_FIXTURE=1
node --input-type=module - "$ROOT/bin/fm-playbot-lanes.mjs" "$EVIDENCE_ROOT" "$OVERLAY" "$SIGNING_KEY" "$ALLOWED_SIGNERS" "$ALLOWED_SIGNERS_SHA" "$FIX/playbot.db" <<'NODE'
import { pathToFileURL } from 'node:url';
import { writeFileSync, readFileSync, chmodSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const lanesUrl = pathToFileURL(process.argv[2]).href;
const {
  loadCompatibilityManifest,
  mutationEvidenceState,
  assertMutationAllowed,
  nativeDispatchState,
  ready,
  writeEvidenceRecord,
  writeFixtureEvidenceOverlay,
  assertFixtureEvidencePaths,
  normalizeIpcEvaluateResult,
  validateWorkspaceCreateResult,
  validateThreadSendResult,
  mintNativeThreadId,
  buildMutationEvaluateExpression,
  buildConfinementProbeSpec,
  parseConfinementToolProof,
  assertProjectMutationTarget,
  assertThreadMutationTarget,
  assertWorkspaceMutationTarget,
  resolveWorkspaceIncludingArchived,
  verifyPlaybotRetirement
} = await import(lanesUrl);

const evidenceRoot = process.argv[3];
const overlayPath = process.argv[4];
const signingKey = process.argv[5];
const allowedSignersPath = process.argv[6];
const allowedSignersSha256 = process.argv[7];
const applicationDb = process.argv[8];
const attestation = { signingKey, allowedSignersPath, allowedSignersSha256 };
const env = { FM_PLAYBOT_EVIDENCE_ROOT: evidenceRoot, FM_PLAYBOT_EVIDENCE_OVERLAY: overlayPath, FM_PLAYBOT_SMOKE_FIXTURE: '1' };
const productionEvidenceRoot = resolve(dirname(process.argv[2]), '../docs/verification/playbot-mutation-evidence');
try {
  assertFixtureEvidencePaths(evidenceRoot, resolve(productionEvidenceRoot, 'overlay.v1.json'));
  throw new Error('fixture production overlay path must fail');
} catch (error) {
  if (!/production evidence root/.test(error.message)) throw error;
}
try {
  assertFixtureEvidencePaths(evidenceRoot, resolve(dirname(evidenceRoot), 'outside-fixture', 'overlay.v1.json'));
  throw new Error('fixture overlay outside evidence root must fail');
} catch (error) {
  if (!/within the fixture evidence root/.test(error.message)) throw error;
}
const publicationFiles = (pointerPath) => {
  const pointer = JSON.parse(readFileSync(pointerPath, 'utf8'));
  const overlay = resolve(dirname(pointerPath), pointer.publicationRelPath, 'overlay.v1.json');
  return { overlay, receipt: `${overlay}.receipt.json` };
};
const ops = [
  'workspace:create',
  'threads:openThread',
  'threads:send',
  'threads:stop',
  'threads:archiveThread',
  'workspace:delete',
  'confinement'
];
const pointers = {};
for (const operation of ops) {
  pointers[operation] = writeEvidenceRecord({
    schema: 'firstmate.playbot.mutation-evidence.v1',
    operation,
    appVersion: '0.92.0',
    smokeRunId: 'hermetic-fixture',
    recordedAt: new Date().toISOString(),
    probe: {
      readAttempted: true,
      writeAttempted: true,
      readOutcome: 'allowed',
      writeOutcome: 'denied'
    },
    rationalePointer: 'docs/playbot-lanes.md#confinement-gate-8-re-scope',
    note: 'hermetic fixture'
  }, { env, evidenceRoot });
}
const overlay = {
  schema: 'firstmate.playbot.mutation-evidence-overlay.v1',
  manifestVersion: 2,
  releases: {
    '0.92.0': {
      mutationEvidence: Object.fromEntries(ops.filter((op) => op !== 'confinement').map((op) => [op, pointers[op]])),
      confinement: pointers.confinement
    }
  }
};
try {
  writeFixtureEvidenceOverlay(overlay, {
    env,
    evidenceRoot,
    overlayPath: resolve(dirname(evidenceRoot), 'outside-fixture', 'overlay.v1.json'),
    smokeRunId: 'outside-fixture',
    appVersion: '0.92.0',
    ...attestation
  });
  throw new Error('fixture publisher must refuse an overlay outside its evidence root');
} catch (error) {
  if (!/within the fixture evidence root/.test(error.message)) throw error;
}
writeFixtureEvidenceOverlay(overlay, {
  env, evidenceRoot, overlayPath, smokeRunId: 'hermetic-fixture', appVersion: '0.92.0', ...attestation
});
const loaded = loadCompatibilityManifest({ env, evidenceRoot, overlayPath, ...attestation });
const native = nativeDispatchState(loaded.manifest, '0.92.0');
if (!native.allowed || native.operatingState !== 'native-enabled') {
  throw new Error(`expected native-enabled, got ${native.operatingState}: ${native.reason}`);
}
if (!mutationEvidenceState(loaded.manifest, '0.92.0', 'threads:send').allowed) {
  throw new Error('threads:send should be allowed with verified evidence');
}
if (mutationEvidenceState(loaded.manifest, '0.92.0', 'workspace:archive').allowed) {
  throw new Error('workspace:archive must stay gated without successful live evidence');
}
try {
  writeFixtureEvidenceOverlay(overlay, {
    env,
    evidenceRoot,
    overlayPath,
    smokeRunId: 'interrupted-fixture',
    appVersion: '0.92.0',
    publicationFailpoint: 'before-pointer',
    ...attestation
  });
  throw new Error('publication failpoint must interrupt before pointer replacement');
} catch (error) {
  if (!/fixture publication failpoint/.test(error.message)) throw error;
}
const afterInterruptedPublication = loadCompatibilityManifest({ env, evidenceRoot, overlayPath, ...attestation });
if (!nativeDispatchState(afterInterruptedPublication.manifest, '0.92.0').allowed) {
  throw new Error('interrupted publication must leave the prior pointer valid');
}
const fixtureRoot = dirname(applicationDb);
const deadPortFile = resolve(fixtureRoot, 'DeadDevToolsActivePort');
writeFileSync(deadPortFile, '1\n');
const unhealthyNative = await ready({
  appVersion: '0.92.0',
  manifest: loaded.manifest,
  stateDir: resolve(fixtureRoot, 'unhealthy-state'),
  paths: {
    appVersion: '0.92.0',
    applicationDb,
    codexDb: resolve(fixtureRoot, 'harness/state_5.sqlite'),
    appRunState: resolve(fixtureRoot, 'playbot-app-run-state.json'),
    devToolsPortFile: deadPortFile,
    appBundle: resolve(fixtureRoot, 'fixture-app.asar')
  }
});
if (unhealthyNative.ready || !/reachability/.test(unhealthyNative.reason)) {
  throw new Error('native readiness must require read-only runtime health');
}
// Tamper: rewrite evidence body without updating the overlay hash.
const sendPath = resolve(evidenceRoot, pointers['threads:send'].recordRelPath);
writeFileSync(sendPath, `${readFileSync(sendPath, 'utf8')} `);
const tampered = loadCompatibilityManifest({ env, evidenceRoot, overlayPath, ...attestation });
if (mutationEvidenceState(tampered.manifest, '0.92.0', 'threads:send').allowed) {
  throw new Error('tampered evidence must keep threads:send refused');
}
if (!tampered.integrity.refused.some((item) => item.scope.includes('threads:send'))) {
  throw new Error('tamper must appear in integrity.refused');
}
const editedBody = `${JSON.stringify({
  schema: 'firstmate.playbot.mutation-evidence.v1',
  operation: 'threads:send',
  appVersion: '0.92.0',
  smokeRunId: 'hand-edited',
  recordedAt: new Date().toISOString()
}, null, 2)}\n`;
writeFileSync(sendPath, editedBody);
overlay.releases['0.92.0'].mutationEvidence['threads:send'].contentSha256 = (await import('node:crypto')).createHash('sha256').update(editedBody).digest('hex');
writeFileSync(publicationFiles(overlayPath).overlay, `${JSON.stringify(overlay, null, 2)}\n`);
const coordinated = loadCompatibilityManifest({ env, evidenceRoot, overlayPath, ...attestation });
if (!coordinated.integrity.refused.some((item) => item.scope === 'overlay' && item.reason.includes('attestation'))) {
  throw new Error('coordinated overlay and record edits must fail attestation');
}
// Shape parsers (offline; no live Playbot).
const createEnv = normalizeIpcEvaluateResult(JSON.stringify({
  channel: 'workspace:create',
  request: {},
  resultWasUndefined: false,
  resultType: 'object',
  result: { id: 'ws_x', projectId: 'p', kind: 'worktree', archiveState: 'active' }
}));
validateWorkspaceCreateResult(createEnv.result);
validateThreadSendResult({ threadId: 'chat-1-1', phase: { kind: 'ready' } });
try {
  validateWorkspaceCreateResult(createEnv.result, 'wrong-project');
  throw new Error('workspace:create project mismatch must fail');
} catch (error) {
  if (!/expected wrong-project/.test(error.message)) throw error;
}
try {
  validateThreadSendResult({ threadId: 'chat-1-2' }, 'chat-1-1', 'threads:stop');
  throw new Error('thread result identity mismatch must fail');
} catch (error) {
  if (!/expected chat-1-1/.test(error.message)) throw error;
}
if (!/^chat-1-\d+$/.test(mintNativeThreadId(42))) throw new Error('native thread id format');
const expr = buildMutationEvaluateExpression('threads:stop', { threadId: 'chat-1-1' });
if (!expr.includes('"threads:stop"') || !expr.includes('"chat-1-1"')) throw new Error('IPC expression must JSON-serialize');
if (assertWorkspaceMutationTarget(applicationDb, 'workspace-task').kind !== 'worktree') throw new Error('worktree mutation target should pass');
if (assertProjectMutationTarget(applicationDb, 'project-alpha', 'root-alpha').project_root_id !== 'root-alpha') {
  throw new Error('exact project/root mutation target should pass');
}
if (assertThreadMutationTarget(applicationDb, 'thread-complete', 'threads:send').workspace.id !== 'workspace-task') {
  throw new Error('exact thread/workspace mutation target should pass');
}
try {
  assertWorkspaceMutationTarget(applicationDb, 'workspace-main', 'workspace:delete');
  throw new Error('MAIN workspace mutation must fail');
} catch (error) {
  if (!/MAIN\/local/.test(error.message)) throw error;
}
const fixtureDb = new DatabaseSync(applicationDb);
fixtureDb.exec("UPDATE workspaces SET archive_state = 'archived' WHERE id = 'workspace-task'");
if (resolveWorkspaceIncludingArchived(applicationDb, 'workspace-task').archive_state !== 'archived') {
  throw new Error('archived workspace must remain resolvable for guarded deletion');
}
if (assertWorkspaceMutationTarget(applicationDb, 'workspace-task', 'workspace:delete').kind !== 'worktree') {
  throw new Error('archived non-MAIN workspace delete target should pass');
}
fixtureDb.prepare(`
  INSERT INTO workspace_threads (id, workspace_id, session_id, pending_queue_json, agent_status, archived)
  VALUES (?, ?, ?, NULL, ?, 0)
`).run('thread-orphan', 'workspace-gone', 'session-orphan', 'ready');
fixtureDb.close();
const retirement = verifyPlaybotRetirement({ applicationDb }, {
  threadId: 'thread-orphan',
  workspaceId: 'workspace-gone',
  worktreePath: resolve(dirname(applicationDb), 'missing-worktree')
});
if (retirement.ok || !retirement.problems.some((problem) => problem.includes('thread-orphan'))) {
  throw new Error('independent cleanup verification must expose orphan threads');
}
const probeSpec = buildConfinementProbeSpec({
  smokeRunId: 'proof-fixture',
  canaryPath: '/tmp/canary fixture',
  writeAttemptPath: '/tmp/write fixture',
  worktreePath: '/tmp/worktree fixture'
});
const toolOutput = (callId, result) => ({
  callId,
  sourceFile: '/tmp/rollout.jsonl',
  text: `Script completed\nWall time 0.1 seconds\nOutput:\n${JSON.stringify(result)}\n`
});
const execInput = (variable, cmd) => `const ${variable} = await tools.exec_command(${JSON.stringify({ cmd })});\ntext(JSON.stringify({exit_code:${variable}.exit_code,output:${variable}.output}));\n`;
const proof = parseConfinementToolProof({
  toolCalls: [
    { callId: 'read-call', input: execInput('readResult', `cat -- '${probeSpec.canaryPath}'`), sourceFile: '/tmp/rollout.jsonl' },
    { callId: 'write-call', input: execInput('writeResult', `printf x > '${probeSpec.writeAttemptPath}'`), sourceFile: '/tmp/rollout.jsonl' }
  ],
  toolOutputs: [
    toolOutput('read-call', { exit_code: 0, output: `${probeSpec.readToken}\n` }),
    toolOutput('write-call', { exit_code: 1, output: 'operation not permitted\n' })
  ]
}, probeSpec);
if (!proof.readAttempted || !proof.writeAttempted || proof.writeOutcome !== 'denied') throw new Error('explicit confinement proof parser');
try {
  parseConfinementToolProof({
    toolCalls: [
      { callId: 'read-call', input: `const request = { cmd: ${JSON.stringify(`printf '%s' "cat -- '${probeSpec.canaryPath}'"`)} };`, sourceFile: '/tmp/rollout.jsonl' },
      { callId: 'write-call', input: execInput('writeResult', `printf x > '${probeSpec.writeAttemptPath}'`), sourceFile: '/tmp/rollout.jsonl' }
    ],
    toolOutputs: [
      toolOutput('read-call', { exit_code: 0, output: `${probeSpec.readToken}\n` }),
      toolOutput('write-call', { exit_code: 1, output: 'operation not permitted\n' })
    ]
  }, probeSpec);
  throw new Error('path-only read claim must fail');
} catch (error) {
  if (!/structured read tool call/.test(error.message)) throw error;
}
try {
  parseConfinementToolProof({
    toolCalls: [
      { callId: 'read-call', input: execInput('readResult', `cat -- '${probeSpec.canaryPath}'`), sourceFile: '/tmp/rollout.jsonl' },
      { callId: 'write-call', input: `const request = { cmd: ${JSON.stringify(`printf '%s' "printf x > '${probeSpec.writeAttemptPath}'"`)} };`, sourceFile: '/tmp/rollout.jsonl' }
    ],
    toolOutputs: [
      toolOutput('read-call', { exit_code: 0, output: `${probeSpec.readToken}\n` }),
      toolOutput('write-call', { exit_code: 1, output: 'EACCES\n' })
    ]
  }, probeSpec);
  throw new Error('path-only write denial claim must fail');
} catch (error) {
  if (!/structured write tool call/.test(error.message)) throw error;
}
try {
  parseConfinementToolProof({
    toolCalls: [
      { callId: 'read-call', input: `const readResult = await tools.exec_command(${JSON.stringify({ cmd: `cat -- '${probeSpec.canaryPath}'` })});\ntext(JSON.stringify({exit_code:0,output:${JSON.stringify(probeSpec.readToken)}}));\n`, sourceFile: '/tmp/rollout.jsonl' },
      { callId: 'write-call', input: execInput('writeResult', `printf x > '${probeSpec.writeAttemptPath}'`), sourceFile: '/tmp/rollout.jsonl' }
    ],
    toolOutputs: [
      toolOutput('read-call', { exit_code: 0, output: `${probeSpec.readToken}\n` }),
      toolOutput('write-call', { exit_code: 1, output: 'operation not permitted\n' })
    ]
  }, probeSpec);
  throw new Error('fabricated nested result binding must fail');
} catch (error) {
  if (!/structured read tool call/.test(error.message)) throw error;
}
try {
  parseConfinementToolProof({ toolCalls: [], toolOutputs: [] }, probeSpec);
  throw new Error('ambiguous confinement proof must fail');
} catch (error) {
  if (!/structured tool call/.test(error.message)) throw error;
}
try {
  parseConfinementToolProof({
    toolCalls: [
      { callId: 'read-call', input: execInput('readResult', `cat -- '${probeSpec.canaryPath}'`), sourceFile: '/tmp/rollout.jsonl' },
      { callId: 'write-call', input: execInput('writeResult', `printf x > '${probeSpec.writeAttemptPath}'`), sourceFile: '/tmp/rollout.jsonl' }
    ],
    toolOutputs: [
      toolOutput('read-call', { exit_code: 0, output: `${probeSpec.readToken}\n` }),
      toolOutput('write-call', { exit_code: 127, output: 'working directory missing\n' })
    ]
  }, probeSpec);
  throw new Error('generic write failure must remain ambiguous');
} catch (error) {
  if (!/failed ambiguously/.test(error.message)) throw error;
}
// Write-denial failure is courier-only-confinement even when mutations are present.
const denyRoot = resolve(evidenceRoot, 'write-deny');
const denyOverlay = resolve(denyRoot, 'overlay.v1.json');
const denyEnv = { FM_PLAYBOT_EVIDENCE_ROOT: denyRoot, FM_PLAYBOT_EVIDENCE_OVERLAY: denyOverlay, FM_PLAYBOT_SMOKE_FIXTURE: '1' };
const denyPointers = {};
for (const operation of ops) {
  denyPointers[operation] = writeEvidenceRecord({
    schema: 'firstmate.playbot.mutation-evidence.v1',
    operation,
    appVersion: '0.92.0',
    smokeRunId: 'write-deny-fixture',
    recordedAt: new Date().toISOString(),
    probe: {
      readAttempted: true,
      writeAttempted: true,
      readOutcome: 'allowed',
      writeOutcome: operation === 'confinement' ? 'allowed' : 'denied'
    },
    rationalePointer: 'docs/playbot-lanes.md#confinement-gate-8-re-scope'
  }, { env: denyEnv, evidenceRoot: denyRoot });
}
writeFixtureEvidenceOverlay({
  schema: 'firstmate.playbot.mutation-evidence-overlay.v1',
  manifestVersion: 2,
  releases: {
    '0.92.0': {
      mutationEvidence: Object.fromEntries(ops.filter((op) => op !== 'confinement').map((op) => [op, denyPointers[op]])),
      confinement: denyPointers.confinement
    }
  }
}, {
  env: denyEnv,
  evidenceRoot: denyRoot,
  overlayPath: denyOverlay,
  smokeRunId: 'write-deny-fixture',
  appVersion: '0.92.0',
  ...attestation
});
const denyLoaded = loadCompatibilityManifest({ env: denyEnv, evidenceRoot: denyRoot, overlayPath: denyOverlay, ...attestation });
const blocked = nativeDispatchState(denyLoaded.manifest, '0.92.0');
if (blocked.operatingState !== 'courier-only-confinement' || blocked.allowed) {
  throw new Error(`write-deny must be courier-only-confinement, got ${blocked.operatingState}`);
}
try {
  assertMutationAllowed('threads:send', { manifest: denyLoaded.manifest, appVersion: '0.92.0' });
  throw new Error('direct mutations must require confinement write denial');
} catch (error) {
  if (!/confinement write denial failed/.test(error.message)) throw error;
}
chmodSync(publicationFiles(denyOverlay).receipt, 0o666);
const wrongMode = loadCompatibilityManifest({ env: denyEnv, evidenceRoot: denyRoot, overlayPath: denyOverlay, ...attestation });
if (!wrongMode.integrity.refused.some((item) => item.scope === 'overlay' && item.reason.includes('group/world writable'))) {
  throw new Error('writable smoke receipt must be refused');
}
NODE
pass "mutation evidence records, hash integrity, shape parsers, and write-denial confinement gate hold offline"

printf 'fm-playbot-lanes: all tests passed\n'
