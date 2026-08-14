#!/usr/bin/env node
// tests/playbot-fixtures/mcp-client.mjs <server-arg...> - drive one stdio MCP
// session against bin/fm-playbot-lanes.mjs mcp-serve and print every response
// as one JSON line, so shell tests can assert on them. Fixed scenario:
// initialize, tools/list, health, identify_controller, get_task_status,
// read_task_result, and one unknown method.
import { spawn } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const server = resolve(HERE, '../../bin/fm-playbot-lanes.mjs');

const child = spawn(process.execPath, [server, 'mcp-serve', ...process.argv.slice(2)], {
  stdio: ['pipe', 'pipe', 'inherit'],
  env: process.env
});

const requests = [
  { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'fixture', version: '0' } } },
  { jsonrpc: '2.0', method: 'notifications/initialized' },
  { jsonrpc: '2.0', id: 2, method: 'tools/list' },
  { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'health', arguments: {} } },
  { jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'identify_controller', arguments: {} } },
  { jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'get_task_status', arguments: { taskId: 'fixture-task' } } },
  { jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'read_task_result', arguments: { taskId: 'fixture-task', turnId: 'turn-1' } } },
  { jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'dispatch', arguments: {} } },
  { jsonrpc: '2.0', id: 8, method: 'bogus/method' }
];

let buffer = '';
const responses = [];
child.stdout.on('data', (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    if (!line.trim()) continue;
    responses.push(JSON.parse(line));
    if (responses.length >= 8) {
      for (const response of responses) process.stdout.write(`${JSON.stringify(response)}\n`);
      child.kill('SIGKILL');
      process.exit(0);
    }
  }
});
child.on('exit', (code) => {
  process.stderr.write(`mcp-client: server exited early (code ${code}) after ${responses.length} responses\n`);
  process.exit(1);
});

for (const request of requests) {
  child.stdin.write(`${JSON.stringify(request)}\n`);
}
setTimeout(() => {
  process.stderr.write(`mcp-client: timeout after ${responses.length} responses\n`);
  child.kill('SIGKILL');
  process.exit(1);
}, 10_000);
