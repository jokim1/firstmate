#!/usr/bin/env node
// tests/playbot-fixtures/cdp-transport.test.mjs - hermetic transport
// regressions for the bounded CDP client in bin/fm-playbot-lanes.mjs (plan
// section 8.2 "CDP hangs/restarts"): every pending request rejects on
// close/error/timeout, dead targets are skipped, the enumeration deadline is
// enforced, and channel/payload cross only as JSON inside the fixed bridge
// expression. Exercises the module's exported public interface; run from
// tests/fm-playbot-lanes.test.sh.

import { spawn } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  cdpEnumerateTargets,
  cdpRuntimeEvaluate,
  buildInvokeExpression,
  probeCdpPort
} from '../../bin/fm-playbot-lanes.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FAKE = resolve(HERE, 'fake-cdp.mjs');

let failures = 0;
function ok(name) {
  process.stdout.write(`ok - ${name}\n`);
}
function fail(name, detail) {
  failures += 1;
  process.stdout.write(`not ok - ${name}: ${detail}\n`);
}

async function withFake(scenario, fn) {
  const child = spawn(process.execPath, [FAKE, scenario], { stdio: ['ignore', 'pipe', 'inherit'] });
  const port = await new Promise((resolvePort, rejectPort) => {
    let buffer = '';
    child.stdout.on('data', (chunk) => {
      buffer += chunk;
      const match = buffer.match(/^(\d+)/m);
      if (match) resolvePort(Number(match[1]));
    });
    child.on('exit', () => rejectPort(new Error('fake server exited before binding')));
    child.on('error', rejectPort);
    setTimeout(() => rejectPort(new Error('fake server bind timeout')), 5_000);
  });
  try {
    await fn(port);
  } finally {
    child.kill('SIGKILL');
  }
}

async function expectThrow(name, promise, pattern) {
  try {
    await promise;
    fail(name, 'expected a rejection, got success');
  } catch (error) {
    if (pattern.test(error.message)) ok(name);
    else fail(name, `unexpected error: ${error.message}`);
  }
}

// Connect refusal: nothing listens on the port.
{
  const probe = await probeCdpPort(1, { timeoutMs: 500 });
  if (!probe.ok && probe.error) ok('connect refusal reports not-ok with an error');
  else fail('connect refusal', 'expected a failed probe');
}

await withFake('malformed-version', async (port) => {
  const probe = await probeCdpPort(port, { timeoutMs: 500 });
  if (!probe.ok && /not JSON/.test(probe.error)) ok('malformed version response rejected');
  else fail('malformed version response', `probe=${JSON.stringify(probe)}`);
});

await withFake('missing-websocket', async (port) => {
  const probe = await probeCdpPort(port, { timeoutMs: 500 });
  if (!probe.ok && /webSocketDebuggerUrl/.test(probe.error)) ok('missing websocket identity rejected');
  else fail('missing websocket identity', `probe=${JSON.stringify(probe)}`);
});

await withFake('malformed-targets', async (port) => {
  const probe = await probeCdpPort(port, { timeoutMs: 500 });
  if (!probe.ok && /not an array/.test(probe.error)) ok('malformed target enumeration rejected');
  else fail('malformed target enumeration', `probe=${JSON.stringify(probe)}`);
});

await withFake('dead-first-target', async (port) => {
  const result = await cdpEnumerateTargets(port, { timeoutMs: 1_000, totalDeadlineMs: 2_000 });
  if (result.targets.length === 1 && result.targets[0].id === 'live-page') ok('dead target skipped, live second target selected');
  else fail('dead-first/live-second', `targets=${JSON.stringify(result.targets)}`);
});

await withFake('ws-ok', async (port) => {
  const { targets } = await cdpEnumerateTargets(port, { timeoutMs: 1_000 });
  const value = await cdpRuntimeEvaluate(targets[0].webSocketDebuggerUrl, buildInvokeExpression('threads:send', { text: 'fixture' }), { commandTimeoutMs: 1_000 });
  if (value === '{"ok":true}') ok('bounded Runtime.evaluate round trip returns the renderer value');
  else fail('ws round trip', `value=${JSON.stringify(value)}`);
});

await withFake('ws-close-after-open', async (port) => {
  const { targets } = await cdpEnumerateTargets(port, { timeoutMs: 1_000 });
  await expectThrow(
    'socket close after open rejects the pending command',
    cdpRuntimeEvaluate(targets[0].webSocketDebuggerUrl, '1+1', { commandTimeoutMs: 5_000 }),
    /closed|error|timeout/i
  );
});

await withFake('ws-stall', async (port) => {
  const { targets } = await cdpEnumerateTargets(port, { timeoutMs: 1_000 });
  const started = Date.now();
  await expectThrow(
    'stalled socket is bounded by its own command timer',
    cdpRuntimeEvaluate(targets[0].webSocketDebuggerUrl, '1+1', { commandTimeoutMs: 400 }),
    /timed out|closed|error/i
  );
  if (Date.now() - started < 2_000) ok('stall rejected fast, not at the 5s default');
  else fail('stall timing', 'rejection took longer than the configured timer allows');
});

// The fixed bridge expression never lets channel or payload bytes become
// JavaScript source: evaluate it against a capturing stub and require the
// hostile payload to round-trip as inert data.
{
  const hostile = 'evil");\nprocess.exit(1);\n// "';
  const expression = buildInvokeExpression('threads:send', { text: hostile });
  let captured = null;
  const window = { electronAPI: { invoke: (channel, payload) => { captured = { channel, payload }; } } };
  void window;
  eval(expression); // fixture-controlled expression against the capturing stub
  if (captured && captured.channel === 'threads:send' && captured.payload.text === hostile) {
    ok('invoke bridge JSON-serializes hostile payload bytes into inert data');
  } else {
    fail('bridge serialization', `captured=${JSON.stringify(captured)}`);
  }
  try {
    buildInvokeExpression('threads:send"; process.exit(1);//', {});
    fail('channel validation', 'malformed channel accepted');
  } catch {
    ok('malformed IPC channel refused before evaluation');
  }
}

if (failures > 0) {
  process.stdout.write(`cdp-transport: ${failures} failure(s)\n`);
  process.exit(1);
}
process.stdout.write('cdp-transport: all scenarios passed\n');
