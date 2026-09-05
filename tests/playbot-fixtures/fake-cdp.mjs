#!/usr/bin/env node
// tests/playbot-fixtures/fake-cdp.mjs <scenario> - a fake loopback CDP server
// for the hermetic transport tests (plan section 8.1). Prints the bound port
// on stdout, one line, once listening. Scenarios:
//   ok                      /json/version + /json/list with one live page target
//   malformed-version       /json/version returns non-JSON
//   missing-websocket       /json/version lacks webSocketDebuggerUrl
//   malformed-targets       /json/list returns a non-array
//   dead-first-target       a dead target precedes the live one
//   ws-close-after-open     WS accepts then closes without answering
//   ws-stall                WS accepts and never answers
//   ws-ok                   WS answers Runtime.evaluate with a JSON value
//   ws-launch               WS answers a threads:launch invoke with the result
//                           selected by destination kind from the JSON map in
//                           FAKE_CDP_LAUNCH_RESULTS ({ "new-workspace": ...,
//                           "existing-workspace": ... })
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { createServer as createTcpServer } from 'node:net';

const scenario = process.argv[2];
if (!scenario) {
  process.stderr.write('usage: fake-cdp.mjs <scenario>\n');
  process.exit(64);
}

const versionBody = (withWs, port) => JSON.stringify({
  Browser: 'Chrome/150.0.0.0',
  'Protocol-Version': '1.3',
  ...(withWs ? { webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/browser/fake` } : {})
});

// A minimal WebSocket server: handshake plus text-frame encode/decode for
// small (<126 byte and 16-bit) frames. Hermetic tests only; not a general
// WebSocket implementation.
function attachWebSocket(server, onMessage, { closeAfterOpen = false, stall = false } = {}) {
  server.on('upgrade', (request, socket) => {
    const key = request.headers['sec-websocket-key'];
    const accept = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n'
      + 'Upgrade: websocket\r\n'
      + 'Connection: Upgrade\r\n'
      + `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
    );
    if (closeAfterOpen) {
      setTimeout(() => socket.destroy(), 50);
      return;
    }
    if (stall) return; // never answer; the client's own timer must fire
    let buffer = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 2) {
        const opcode = buffer[0] & 0x0f;
        const length = buffer[1] & 0x7f;
        const headerSize = 2 + (length === 126 ? 2 : 0) + 4; // client frames are masked
        const frameSize = headerSize + (length === 126 ? buffer.readUInt16BE(2) : length);
        if (buffer.length < frameSize) return;
        const mask = buffer.subarray(headerSize - 4, headerSize);
        const payloadLength = length === 126 ? buffer.readUInt16BE(2) : length;
        const payload = Buffer.alloc(payloadLength);
        for (let index = 0; index < payloadLength; index += 1) {
          payload[index] = buffer[headerSize + index] ^ mask[index % 4];
        }
        buffer = buffer.subarray(frameSize);
        if (opcode === 0x8) { // answer the client's close frame so its socket can finish
          socket.end(Buffer.from([0x88, 0x00]));
          return;
        }
        if (opcode !== 0x1) continue; // ignore ping/pong control frames
        const reply = onMessage(payload.toString('utf8'));
        if (reply === null) continue;
        const body = Buffer.from(reply);
        let header;
        if (body.length < 126) {
          header = Buffer.from([0x81, body.length]);
        } else {
          header = Buffer.alloc(4);
          header[0] = 0x81;
          header[1] = 126;
          header.writeUInt16BE(body.length, 2);
        }
        socket.write(Buffer.concat([header, body]));
      }
    });
  });
}

const server = createServer((request, response) => {
  const port = server.address().port;
  if (request.url === '/json/version') {
    if (scenario === 'malformed-version') {
      response.end('this is not json');
      return;
    }
    response.end(versionBody(scenario !== 'missing-websocket', port));
    return;
  }
  if (request.url === '/json/list') {
    if (scenario === 'malformed-targets') {
      response.end('{"not":"an array"}');
      return;
    }
    const live = { id: 'live-page', type: 'page', url: 'file:///Applications/Playbot.app/index.html', webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/live` };
    const targets = scenario === 'dead-first-target'
      ? [{ id: 'dead' }, { type: 'service_worker', id: 'worker' }, live]
      : [live];
    response.end(JSON.stringify(targets));
    return;
  }
  response.statusCode = 404;
  response.end('not found');
});

if (scenario === 'ws-close-after-open') attachWebSocket(server, () => null, { closeAfterOpen: true });
if (scenario === 'ws-stall') attachWebSocket(server, () => null, { stall: true });
if (scenario === 'ws-ok') {
  attachWebSocket(server, (text) => {
    const message = JSON.parse(text);
    return JSON.stringify({ id: message.id, result: { result: { type: 'string', value: '{"ok":true}' } } });
  });
}

if (scenario === 'ws-launch') {
  const results = JSON.parse(process.env.FAKE_CDP_LAUNCH_RESULTS ?? '{}');
  attachWebSocket(server, (text) => {
    const message = JSON.parse(text);
    const expression = String(message.params?.expression ?? '');
    const kind = /"kind":"(new-workspace|existing-workspace)"/.exec(expression)?.[1] ?? null;
    const envelope = kind && results[kind]
      ? { ok: true, channel: 'threads:launch', request: null, resultWasUndefined: false, resultType: 'object', result: results[kind], rendererAppRunId: null }
      : { ok: false, channel: 'threads:launch', request: null, error: `fake launch has no result for destination ${kind}` };
    return JSON.stringify({ id: message.id, result: { result: { type: 'object', value: envelope } } });
  });
}

server.listen(0, '127.0.0.1', () => {
  process.stdout.write(`${server.address().port}\n`);
});
