#!/usr/bin/env node
// bin/fm-playbot-reconcile.mjs - durable completion reconciliation for
// Playbot lane tasks (plan v3 section 3.5, data/lanemcp-impl-plan/report.md).
//
// Sole trigger: the registered per-task custom check (state/<id>.check.sh,
// hash-bound through bin/fm-check-register.sh) invokes `check <id>` and may
// print at most one static pointer line. The watcher - never this program -
// converts nonempty check output into the durable wake. This program never
// appends to the wake queue and never writes worker text into printed output.
//
// Commands:
//   check <id> [--check-key-queued 0|1]   bound-route validation, strict
//                                         per-line JSONL rollout derivation,
//                                         outbox state machine, turn-ended
//                                         touch (amendment 1A), one static line
//   ack <id> <event-id>                   lock-owner-only outbox acknowledgement
//   write-check <id>                      emit state/<id>.check.sh (mode 0700)
//                                         for the caller to hash-bind with
//                                         bin/fm-check-register.sh
//
// Outbox state machine: pending -> acknowledged. A crash at any point is
// replay-safe: pending without a queued check key prints the same static
// pointer again; pending with a queued key stays silent; only the lock-owning
// session may acknowledge, revalidating the PID-only lock plus the process
// identity captured when the event went pending. No MCP tool, worker, check,
// or controller cockpit can acknowledge.

import { createHash } from 'node:crypto';
import {
  readFileSync,
  writeFileSync,
  lstatSync,
  realpathSync,
  utimesSync,
  existsSync,
  mkdirSync,
  copyFileSync,
  statSync
} from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  COMPATIBILITY_MANIFEST,
  fmHome,
  fmStateDir,
  playbotPaths,
  parseMetaFile,
  validateEndpoint,
  mappedRollout,
  writePrivateJsonAtomic,
  capturePidIdentity,
  pidAlive,
  REPO_ROOT
} from './fm-playbot-lanes.mjs';

const LIMITS = COMPATIBILITY_MANIFEST.v1Limits;
const COURIER_VERBS = new Set(['working', 'needs-decision', 'blocked', 'paused', 'done', 'failed']);
const TXN_DEADLINE_SECS = Number(process.env.FM_PLAYBOT_TXN_DEADLINE_SECS ?? 600);

class ReconcileDeadline extends Error {
  constructor() {
    super('reconcile exceeded its 3-second deadline');
    this.name = 'ReconcileDeadline';
  }
}

function makeDeadline(ms) {
  const end = Date.now() + ms;
  return () => {
    if (Date.now() > end) throw new ReconcileDeadline();
  };
}

// --- outbox ----------------------------------------------------------------

function outboxPathFor(stateDir, taskId) {
  return resolve(stateDir, `${taskId}.playbot-outbox.json`);
}

function readOutbox(stateDir, taskId) {
  const path = outboxPathFor(stateDir, taskId);
  try {
    const stat = lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('outbox is not a regular file');
    if ((stat.mode & 0o777) !== 0o600) throw new Error('outbox must be mode 0600');
    const parsed = JSON.parse(readFileSync(realpathSync(path), 'utf8'));
    if (parsed.schema !== 'firstmate.playbot.outbox.v1') throw new Error('outbox schema mismatch');
    if (parsed.taskId !== taskId) throw new Error('outbox task id mismatch');
    return parsed;
  } catch (error) {
    if (error.code === 'ENOENT') {
      return {
        schema: 'firstmate.playbot.outbox.v1',
        taskId,
        events: [],
        knownTurnIds: [],
        lastObservedStatus: null,
        lastReconcileAt: null,
        lastFailure: null
      };
    }
    // Corrupt or unverifiable records are a visible failure, never silently
    // filtered (plan section 3.5).
    throw error;
  }
}

function eventKey(parts) {
  return createHash('sha256')
    .update([parts.taskId, parts.spawnGen, parts.workerThreadId, parts.turnId, parts.kind].join(' '))
    .digest('hex')
    .slice(0, 24);
}

// Bounded untrusted worker-result record (plan section 2.1): at most 32 KiB
// of final-response text, with the full-source hash and truncated=true when
// larger. The record lives in its own mode-0600 file; the outbox references
// it by state-relative path plus hash, and the wake carries only routing data.
function writeResultRecord(stateDir, taskId, event, messageText) {
  const sourceSha256 = createHash('sha256').update(messageText ?? '').digest('hex');
  const cap = LIMITS.outboxTextCopyCapBytes;
  let text = messageText ?? '';
  let truncated = false;
  if (Buffer.byteLength(text, 'utf8') > cap) {
    // Cut on a codepoint boundary within the byte cap.
    text = Buffer.from(text, 'utf8').subarray(0, cap).toString('utf8');
    truncated = true;
  }
  const record = {
    schema: 'firstmate.playbot.worker-result.v1',
    trust: 'untrusted-worker-data',
    taskId,
    workerThreadId: event.workerThreadId,
    turnId: event.turnId,
    sha256: sourceSha256,
    truncated,
    text
  };
  const relative = `${taskId}.playbot-result-${event.id}.json`;
  writePrivateJsonAtomic(resolve(stateDir, relative), record);
  return {
    record: relative,
    recordSha256: createHash('sha256').update(JSON.stringify(record, null, 2) + '\n').digest('hex')
  };
}

// The courier's fixed status verbs, read from the workspace-local
// .fm/status.log. Absent or nonstandard final lines mean the turn is reported
// only as worker-turn-ended, never guessed to be success (plan section 3.5).
function readWorkspaceTerminalVerb(worktreePath) {
  try {
    const statusLog = resolve(worktreePath, '.fm', 'status.log');
    const stat = lstatSync(statusLog);
    if (!stat.isFile() || stat.isSymbolicLink()) return null;
    const lines = readFileSync(statusLog, 'utf8').split('\n').filter((line) => line.trim());
    const last = lines.at(-1) ?? '';
    const verb = last.split(':')[0].trim();
    return COURIER_VERBS.has(verb) ? verb : null;
  } catch {
    return null;
  }
}

// Scout report copy (amendment 4A): a report over 1 MiB leaves the workspace
// retained and produces a loud static failure event - the authoritative
// report is never silently truncated.
function copyScoutReport(options) {
  const reportPath = resolve(options.worktreePath, '.fm', 'report.md');
  let stat;
  try {
    stat = lstatSync(reportPath);
    if (!stat.isFile() || stat.isSymbolicLink()) return { copied: false, reason: 'no workspace report' };
  } catch {
    return { copied: false, reason: 'no workspace report' };
  }
  if (stat.size > LIMITS.scoutReportCopyCapBytes) {
    return {
      copied: false,
      oversized: true,
      sizeBytes: stat.size,
      reason: `scout report is ${stat.size} bytes, over the ${LIMITS.scoutReportCopyCapBytes}-byte cap; workspace retained, no truncated copy made`
    };
  }
  const dataDir = resolve(fmHome(options.env), 'data', options.taskId);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  copyFileSync(realpathSync(reportPath), resolve(dataDir, 'report.md'));
  return { copied: true, sizeBytes: stat.size };
}

// --- check -----------------------------------------------------------------

export function reconcileCheck(taskId, options = {}) {
  const env = options.env ?? process.env;
  const stateDir = options.stateDir ?? fmStateDir(env);
  const paths = options.paths ?? playbotPaths(env);
  const checkKeyQueued = options.checkKeyQueued === true;
  const checkDeadline = makeDeadline(options.deadlineMs ?? LIMITS.reconcileDeadlineMs);
  const printed = [];

  // A corrupt or unverifiable outbox is a visible failure, never silently
  // filtered (plan section 3.5): print one static failure line every sweep
  // until the record is repaired.
  let outbox;
  try {
    outbox = readOutbox(stateDir, taskId);
  } catch (error) {
    printed.push(`playbot-reconcile-failure task=${taskId} stage=outbox`);
    return { printed, outbox: null, exitCode: 1, error: error.message };
  }
  const failOnce = (stage, message) => {
    const signature = `${stage}: ${message}`;
    outbox.lastReconcileAt = new Date().toISOString();
    if (outbox.lastFailure?.signature === signature && outbox.lastFailure?.printed) {
      writePrivateJsonAtomic(outboxPathFor(stateDir, taskId), outbox);
      return { printed, outbox, exitCode: 1 };
    }
    outbox.lastFailure = { signature, stage, at: new Date().toISOString(), printed: true };
    writePrivateJsonAtomic(outboxPathFor(stateDir, taskId), outbox);
    printed.push(`playbot-reconcile-failure task=${taskId} stage=${stage}`);
    return { printed, outbox, exitCode: 1 };
  };

  // Stage 1: meta, bound route, project binding, endpoint relationship.
  const metaPath = resolve(stateDir, `${taskId}.meta`);
  let meta;
  try {
    meta = parseMetaFile(metaPath);
  } catch (error) {
    return failOnce('meta', error.message);
  }
  if (meta.fields.get('backend') !== 'playbot') {
    return failOnce('meta', 'task meta backend is not playbot');
  }
  checkDeadline();
  const verdict = validateEndpoint({ metaPath, homeDir: fmHome(env), paths });
  if (!verdict.ok) {
    return failOnce('endpoint', verdict.failures.join('; '));
  }
  const threadId = verdict.threadId;
  const worktree = meta.fields.get('worktree');
  checkDeadline();

  // Post-meta dispatch-transaction supervision (V2SIM-4): a transaction that
  // never reached worker-started past its deadline is one static failure
  // pointer, not a silently idle worker.
  const txnPath = resolve(stateDir, '.playbot-dispatch', `${taskId}.txn`);
  if (existsSync(txnPath)) {
    try {
      const txn = JSON.parse(readFileSync(txnPath, 'utf8'));
      const ageSecs = (Date.now() - statSync(txnPath).mtimeMs) / 1_000;
      if (txn.state && txn.state !== 'worker-started' && ageSecs > TXN_DEADLINE_SECS) {
        return failOnce('dispatch-transaction', `txn-state ${txn.state} is ${Math.round(ageSecs)}s old, past the ${TXN_DEADLINE_SECS}s deadline`);
      }
    } catch (error) {
      return failOnce('dispatch-transaction', `unreadable transaction: ${error.message}`);
    }
  }
  checkDeadline();

  // Stage 2-3: exact worker row plus bounded rollout tail, strict JSONL
  // structural parsing only (V2SIM-3).
  let mapped;
  try {
    mapped = mappedRollout(paths.applicationDb, paths.codexDb, threadId, { includeMessage: true });
  } catch (error) {
    return failOnce('playbot-read', error.message);
  }
  checkDeadline();

  const spawnGen = meta.fields.get('spawn_gen') ?? '';
  const known = new Set(outbox.knownTurnIds);
  const newTurns = mapped.rollout.completions.filter((completion) => !known.has(completion.turnId));
  const observedStatus = mapped.appThread.agent_status ?? null;
  const pendingInputSpec = COMPATIBILITY_MANIFEST.releases['0.90.0'].rollout.pendingInputAgentStatus;

  // Stage 4: dedupe against the outbox, then atomically record new pending
  // events before any output.
  let lockPid = null;
  let lockIdentity = null;
  if (newTurns.length > 0 || (observedStatus === pendingInputSpec && outbox.lastObservedStatus !== pendingInputSpec)) {
    try {
      lockPid = readFileSync(resolve(stateDir, '.lock'), 'utf8').trim();
      lockIdentity = capturePidIdentity(lockPid, env);
    } catch {
      lockPid = null;
      lockIdentity = null;
    }
  }

  const newEvents = [];
  for (const turn of newTurns) {
    const verb = worktree ? readWorkspaceTerminalVerb(worktree) : null;
    const kind = verb ? `completed:${verb}` : 'worker-turn-ended';
    const event = {
      id: eventKey({ taskId, spawnGen, workerThreadId: threadId, turnId: turn.turnId, kind }),
      kind,
      turnId: turn.turnId,
      workerThreadId: threadId,
      state: 'pending',
      createdAt: new Date().toISOString(),
      lockPid: lockPid ? Number(lockPid) : null,
      lockPidIdentity: lockIdentity
    };
    const recordRef = writeResultRecord(stateDir, taskId, event, turn.lastAgentMessage ?? '');
    Object.assign(event, recordRef);
    if (verb === 'done' && meta.fields.get('kind') === 'scout' && worktree) {
      const copy = copyScoutReport({ worktreePath: worktree, taskId, env });
      event.scoutReport = copy;
      if (copy.oversized) {
        event.kind = 'scout-report-oversized';
        event.failure = copy.reason;
      }
    }
    newEvents.push(event);
    outbox.knownTurnIds.push(turn.turnId);
  }

  if (observedStatus === pendingInputSpec && outbox.lastObservedStatus !== pendingInputSpec) {
    const basisTurn = mapped.rollout.latestCompletion?.turnId ?? 'none';
    const kind = 'input-request';
    const id = eventKey({ taskId, spawnGen, workerThreadId: threadId, turnId: basisTurn, kind });
    if (!outbox.events.some((event) => event.id === id)) {
      newEvents.push({
        id,
        kind,
        turnId: basisTurn,
        workerThreadId: threadId,
        state: 'pending',
        createdAt: new Date().toISOString(),
        lockPid: lockPid ? Number(lockPid) : null,
        lockPidIdentity: lockIdentity
      });
    }
  }
  outbox.lastObservedStatus = observedStatus;

  // Keep the cursor bounded: rotated tails far in the past are not load-bearing.
  if (outbox.knownTurnIds.length > 64) {
    outbox.knownTurnIds = outbox.knownTurnIds.slice(-64);
  }

  // Stage 5 (amendment 1A): Playbot workers run no Firstmate turn-end hooks,
  // so the reconciler alone touches state/<id>.turn-ended for each newly
  // observed completed turn; without it the watcher's busy_turn_over_age
  // wedge-escalates every long-running Playbot task forever.
  if (newTurns.length > 0) {
    const turnEndedPath = resolve(stateDir, `${taskId}.turn-ended`);
    if (!existsSync(turnEndedPath)) writeFileSync(turnEndedPath, '', { mode: 0o600 });
    const now = new Date();
    utimesSync(turnEndedPath, now, now);
  }

  outbox.events.push(...newEvents);
  outbox.lastReconcileAt = new Date().toISOString();
  outbox.lastFailure = null;
  writePrivateJsonAtomic(outboxPathFor(stateDir, taskId), outbox);
  checkDeadline();

  // Stage 6: at most one static pointer line, and only when the durable queue
  // does not already hold this check's key (the boolean is computed by the
  // hash-bound shell wrapper through fm_wake_queued_keys; this program never
  // parses the wake queue itself).
  const pendingEvents = outbox.events.filter((event) => event.state === 'pending');
  if (pendingEvents.length > 0 && !checkKeyQueued) {
    printed.push(`playbot-event task=${taskId} event=${pendingEvents[0].id} record=state/${taskId}.playbot-outbox.json`);
  }
  return { printed, outbox, exitCode: 0, newEvents: newEvents.map((event) => event.id) };
}

// --- ack -------------------------------------------------------------------

export function reconcileAck(taskId, eventId, options = {}) {
  const env = options.env ?? process.env;
  const stateDir = options.stateDir ?? fmStateDir(env);
  const outbox = readOutbox(stateDir, taskId);
  const event = outbox.events.find((candidate) => candidate.id === eventId);
  if (!event) throw new Error(`no outbox event ${eventId} for task ${taskId}`);
  if (event.state === 'acknowledged') return { acknowledged: true, already: true };

  // Only the lock-owning outside-Playbot session may acknowledge: the live
  // PID-only lock must still name the same pid, that pid must be alive, and
  // its re-captured process identity must equal the identity captured when
  // the event went pending (plan section 3.5, Claude-3).
  const lockPath = resolve(stateDir, '.lock');
  let lockPid;
  try {
    const stat = lstatSync(lockPath);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('session lock is not a regular file');
    lockPid = readFileSync(lockPath, 'utf8').trim();
  } catch (error) {
    throw new Error(`ack refused: ${error.message}`);
  }
  if (!/^\d+$/.test(lockPid)) throw new Error('ack refused: session lock does not hold a numeric pid');
  if (event.lockPid === null || !event.lockPidIdentity) {
    throw new Error('ack refused: the event recorded no lock-owner identity at pending time');
  }
  if (Number(lockPid) !== event.lockPid) {
    throw new Error('ack refused: the session lock owner changed since the event went pending');
  }
  if (!pidAlive(lockPid)) throw new Error('ack refused: the lock-owner process is not live');
  const liveIdentity = capturePidIdentity(lockPid, env);
  if (liveIdentity !== event.lockPidIdentity) {
    throw new Error('ack refused: the lock-owner process identity changed since the event went pending');
  }
  event.state = 'acknowledged';
  event.acknowledgedAt = new Date().toISOString();
  writePrivateJsonAtomic(outboxPathFor(stateDir, taskId), outbox);
  return { acknowledged: true, already: false };
}

// --- write-check -----------------------------------------------------------
//
// The generated wrapper keeps the custom-check contract from AGENTS.md: an
// ordinary mode-0700 file that prints one line only when firstmate should
// wake and finishes well before FM_CHECK_TIMEOUT. It queries the sanctioned
// fm_wake_queued_keys helper and greps for its own exact full path - the
// watcher's append key for a custom check (V2SIM-6) - then passes only the
// resulting boolean to the reconciler. After writing, the caller hash-binds
// the wrapper with bin/fm-check-register.sh <id>.
export function writeCheckWrapper(taskId, options = {}) {
  const env = options.env ?? process.env;
  const stateDir = options.stateDir ?? fmStateDir(env);
  const root = options.repoRoot ?? REPO_ROOT;
  const checkPath = resolve(stateDir, `${taskId}.check.sh`);
  const content = `#!/usr/bin/env bash
# state/${taskId}.check.sh - generated by bin/fm-playbot-reconcile.mjs write-check.
# Playbot reconcile wrapper: prints at most one static pointer line when a
# pending outbox event has no queued wake. The watcher alone appends the wake.
set -u
FM_HOME="\${FM_HOME:-${root}}"
STATE="\${FM_STATE_OVERRIDE:-\$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "${root}/bin/fm-wake-lib.sh"
# The reconcile runs under a per-task lock so concurrent checks collapse
# (plan section 3.5): a second concurrent run exits quietly.
fm_lock_try_acquire "\$STATE/.playbot-reconcile-${taskId}.lock" || exit 0
trap 'fm_lock_release "\$STATE/.playbot-reconcile-${taskId}.lock"' EXIT
queued=0
if fm_wake_queued_keys check 2>/dev/null | grep -Fqx "\$STATE/${taskId}.check.sh"; then
  queued=1
fi
node "${root}/bin/fm-playbot-reconcile.mjs" check "${taskId}" --check-key-queued "\$queued"
`;
  writeFileSync(checkPath, content, { mode: 0o700 });
  return checkPath;
}

// --- CLI -------------------------------------------------------------------

function parseArgs(argv) {
  const result = { _: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (!value.startsWith('--')) {
      result._.push(value);
      continue;
    }
    const key = value.slice(2);
    const next = argv[index + 1];
    if (next === undefined || next.startsWith('--')) throw new Error(`missing value for --${key}`);
    index += 1;
    result[key] = next;
  }
  return result;
}

const USAGE = `fm-playbot-reconcile.mjs - durable Playbot completion reconciliation (plan section 3.5)

  check <task-id> [--check-key-queued 0|1]   reconcile one bound route; prints at most one static line
  ack <task-id> <event-id>                   lock-owner-only outbox acknowledgement
  write-check <task-id>                      emit state/<task-id>.check.sh (then run bin/fm-check-register.sh)
`;

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);
  switch (command) {
    case 'check': {
      const taskId = args._[0];
      if (!taskId) throw new Error('check needs an exact task id');
      const result = reconcileCheck(taskId, {
        checkKeyQueued: args['check-key-queued'] === '1'
      });
      for (const line of result.printed) process.stdout.write(`${line}\n`);
      process.exitCode = result.exitCode;
      return;
    }
    case 'ack': {
      const [taskId, eventId] = args._;
      if (!taskId || !eventId) throw new Error('ack needs an exact task id and event id');
      const result = reconcileAck(taskId, eventId);
      process.stdout.write(`${result.acknowledged ? 'acknowledged' : 'refused'}: ${eventId}${result.already ? ' (already)' : ''}\n`);
      return;
    }
    case 'write-check': {
      const taskId = args._[0];
      if (!taskId) throw new Error('write-check needs an exact task id');
      const path = writeCheckWrapper(taskId);
      process.stdout.write(`wrote ${path}; bind it with bin/fm-check-register.sh ${taskId}\n`);
      return;
    }
    case undefined:
    case 'help':
    case '--help':
      process.stdout.write(USAGE);
      return;
    default:
      process.stdout.write(USAGE);
      throw new Error(`unknown command: ${command ?? '<missing>'}`);
  }
}

const invokedAsScript = (() => {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(resolve(process.argv[1]));
  } catch {
    return false;
  }
})();

if (invokedAsScript) {
  main().catch((error) => {
    process.stderr.write(`fm-playbot-reconcile: ${error.message}\n`);
    process.exitCode = 64;
  });
}

