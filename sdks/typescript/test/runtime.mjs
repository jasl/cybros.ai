import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { gzipSync, gunzipSync } from 'node:zlib';
import { WebSocketServer } from 'ws';
import { Client, ExecutorClient, DeviceFlow, PlatformClient, RedirectError, TimeoutError, CancelledError, ServerError, MalformedResponse, NotFound } from '@cybros/agent';
import { RealtimeClient } from '@cybros/agent/realtime';
const profile = { member: { public_id: 'agent', handle: 'agent', kind: 'agent', role: 'member', display_name: null, agent_identifier: 'program.instance' }, credential: { plane: 'member', expires_at: null }, configuration: null, measured_at: '2026-10-15T00:00:00Z' };
const upload = { upload: { public_id: 'upload', filename: 'file.txt', content_type: 'text/plain', byte_size: 3, created_at: '2026-10-15T00:00:00Z' } };
async function server(handler) {
  const http = createServer(handler); http.listen(0, '127.0.0.1'); await once(http, 'listening');
  return { http, url: `http://127.0.0.1:${http.address().port}`, async close() { http.closeAllConnections(); await new Promise(resolve => http.close(resolve)); } };
}
test('native fetch uses the supplied bearer once and parses the public profile', async () => {
  let providers = 0, requests = 0;
  const host = await server((request, response) => { requests++; assert.equal(request.headers.authorization, 'Bearer native-test'); response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify(profile)); });
  try { const client = new Client({ baseURL: host.url, credentialProvider: async () => { providers++; return 'native-test'; } }); assert.equal((await client.profile.fetch()).member.public_id, 'agent'); assert.equal(providers, 1); assert.equal(requests, 1); }
  finally { await host.close(); }
});
test('native empty acknowledgements preserve progress, cancellation and OAuth semantics', async () => {
  const requests = [];
  const host = await server((request, response) => { requests.push(request.url); response.writeHead(request.url.startsWith('/oauth/') ? 200 : 202); response.end(); });
  try {
    await new ExecutorClient({ baseURL: host.url, credential: 'executor' }).reportProgress({ run_public_id: 'run', task_key: 'task', claim_token: 'claim', text_tail: 'Working' });
    await new Client({ baseURL: host.url, credential: 'member' }).workspace('workspace').conversation('conversation').cancel();
    assert.equal(await new DeviceFlow({ baseURL: host.url }).cancelAuthorization({ device_code: 'device' }), 'cancelled');
    assert.equal(requests.length, 3);
  } finally { await host.close(); }
});
test('native redirect response is rejected without a second request', async () => {
  let destinations = 0;
  const target = await server((_request, response) => { destinations++; response.end('{}'); });
  const host = await server((_request, response) => { response.writeHead(307, { Location: target.url }); response.end(); });
  try { await assert.rejects(new Client({ baseURL: host.url, credential: 'secret' }).profile.fetch(), RedirectError); assert.equal(destinations, 0); }
  finally { await host.close(); await target.close(); }
});
test('native deadlines and cancellation cover body consumption', async () => {
  const host = await server((_request, response) => { response.writeHead(200, { 'Content-Type': 'application/json' }); response.write('{'); const timer = setTimeout(() => response.end('}'), 500); response.on('close', () => clearTimeout(timer)); });
  try {
    const client = new Client({ baseURL: host.url, credential: 'secret', timeoutMs: 30 });
    await assert.rejects(client.profile.fetch(), TimeoutError);
    const controller = new AbortController(); const pending = client.profile.fetch({ timeoutMs: 1000, signal: controller.signal }); setTimeout(() => controller.abort(), 15); await assert.rejects(pending, CancelledError);
  } finally { await host.close(); }
});
test('native downloads retain range, etag, stream ownership and body deadline', async () => {
  let count = 0;
  const host = await server((request, response) => {
    count++;
    if (request.headers['if-none-match'] === '"same"') { response.writeHead(304, { ETag: '"same"' }); response.end(); return; }
    if (request.headers.range) { assert.equal(request.headers.range, 'bytes=1-2'); response.writeHead(206, { ETag: '"range"', 'Content-Range': 'bytes 1-2/3' }); response.end('bc'); return; }
    response.writeHead(200); response.write('a'); const timer = setTimeout(() => response.end('bc'), 500); response.on('close', () => clearTimeout(timer));
  });
  try {
    const client = new Client({ baseURL: host.url, credential: 'secret' });
    const partial = await client.uploads.bytes('id', { range: 'bytes=1-2' }); assert.equal(partial.status, 206); assert.equal(partial.etag, '"range"'); assert.equal(await new Response(partial.body).text(), 'bc');
    const fresh = await client.uploads.bytes('id', { ifNoneMatch: '"same"' }); assert.equal(fresh.status, 304); assert.equal(fresh.body, null);
    const slow = await client.uploads.bytes('id', { timeoutMs: 25 }); await assert.rejects(new Response(slow.body).text(), TimeoutError); assert.equal(count, 3);
  } finally { await host.close(); }
});
test('conversation export retains gzip bytes and caller-owned stream behavior', async () => {
  const text = '{"type":"export"}\n{"type":"end"}\n', compressed = gzipSync(text);
  let count = 0;
  const host = await server((request, response) => {
    count++;
    assert.equal(request.url, '/agent_api/v1/workspaces/workspace/conversations/conversation/export');
    assert.equal(request.headers.authorization, 'Bearer member');
    assert.equal(request.headers.range, undefined); assert.equal(request.headers['if-none-match'], undefined);
    if (count === 2) { response.writeHead(404, { 'Content-Type': 'application/json' }); response.end('{"error":{"code":"not_found","message":"Not found"}}'); return; }
    response.writeHead(200, { 'Content-Type': 'application/gzip' });
    if (count === 1) { response.end(compressed); return; }
    response.write(compressed.subarray(0, 10));
    const timer = setTimeout(() => response.end(compressed.subarray(10)), 500); response.on('close', () => clearTimeout(timer));
  });
  try {
    const chat = new Client({ baseURL: host.url, credential: 'member' }).workspace('workspace').conversation('conversation');
    const exported = await chat.export(); assert.equal(exported.status, 200); assert.equal(exported.contentType, 'application/gzip'); assert.equal(exported.etag, null);
    const bytes = Buffer.from(await new Response(exported.body).arrayBuffer()); assert.deepEqual(bytes, compressed); assert.equal(gunzipSync(bytes).toString(), text);
    await assert.rejects(chat.export(), error => error instanceof NotFound && error.code === 'not_found');
    const timed = await chat.export({ timeoutMs: 25 }); await assert.rejects(new Response(timed.body).arrayBuffer(), TimeoutError);
    const canceled = await chat.export(); await canceled.body.cancel();
    assert.equal(count, 4);
  } finally { await host.close(); }
});
test('native multipart uploads use caller bytes and public part name', async () => {
  const host = await server(async (request, response) => { let body = ''; for await (const chunk of request) body += chunk.toString(); assert.match(request.headers['content-type'], /^multipart\/form-data; boundary=/); assert.match(body, /name="upload\[file\]"; filename="file.txt"/); assert.match(body, /abc/); response.writeHead(201, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(upload)); });
  try { const created = await new Client({ baseURL: host.url, credential: 'secret' }).uploads.create(new Blob(['abc']), 'file.txt'); assert.equal(created.public_id, 'upload'); }
  finally { await host.close(); }
});
test('native non-JSON server failure differs from malformed success', async () => {
  let count = 0;
  const host = await server((_request, response) => { response.writeHead(++count === 1 ? 502 : 200, { 'Content-Type': 'text/html' }); response.end('<h1>gateway</h1>'); });
  try { const client = new Client({ baseURL: host.url, credential: 'secret' }); await assert.rejects(client.profile.fetch(), ServerError); await assert.rejects(client.profile.fetch(), MalformedResponse); assert.equal(count, 2); }
  finally { await host.close(); }
});
test('native ActionCable handshake, confirmation, bearer and unknown event', async () => {
  const host = await server((_request, response) => { response.writeHead(404); response.end(); });
  const wss = new WebSocketServer({ server: host.http, handleProtocols: protocols => protocols.has('actioncable-v1-json') ? 'actioncable-v1-json' : false });
  let connected = 0;
  let acknowledgeUnsubscribe; const unsubscribed = new Promise(resolve => { acknowledgeUnsubscribe = resolve; });
  wss.on('connection', (socket, request) => {
    connected++; assert.equal(request.headers.authorization, 'Bearer cable-secret'); assert.equal(request.headers.origin, host.url); assert.equal(request.url, '/agent_api/v1/cable');
    socket.send(JSON.stringify({ type: 'welcome' }));
    socket.on('message', bytes => {
      const frame = JSON.parse(bytes.toString());
      if (frame.command === 'unsubscribe') { acknowledgeUnsubscribe(); return; }
      if (frame.command !== 'subscribe') return;
      const identity = JSON.parse(frame.identifier); assert.equal(identity.channel, 'AgentAPI::V1::ConversationEventsChannel'); assert.ok(identity._cybros_sdk_subscription_id);
      socket.send(JSON.stringify({ identifier: frame.identifier, type: 'confirm_subscription' }));
      socket.send(JSON.stringify({ identifier: frame.identifier, message: { event: { public_id: 'event', sequence: 1, cursor: 'opaque', type: 'future_event', resource: { type: 'conversation', public_id: 'conversation' }, occurred_at: '2026-10-15T00:00:00Z', payload: { nested_snake_case: 'kept' } } } }));
    });
  });
  const realtime = new RealtimeClient({ baseURL: host.url, credential: 'cable-secret' });
  try {
    const sub = await realtime.conversationEvents('workspace', 'conversation');
    for await (const event of sub) { assert.equal(event.type, 'future_event'); assert.deepEqual(event.payload, { nested_snake_case: 'kept' }); break; }
    await Promise.race([unsubscribed, new Promise((_resolve, reject) => setTimeout(() => reject(new Error("unsubscribe not received")), 1000))]);
    await realtime.close(); assert.equal(connected, 1);
  } finally { await realtime.close(); await new Promise(resolve => wss.close(resolve)); await host.close(); }
});
test('native deployment SSE preserves opaque cursor and unknown event payload', async () => {
  let requests = 0;
  const host = await server((request, response) => {
    requests++; assert.equal(request.headers.accept, 'text/event-stream'); assert.equal(request.headers['last-event-id'], 'previous'); assert.equal(new URL(request.url, 'http://localhost').searchParams.get('cursor'), 'opaque');
    response.writeHead(200, { 'Content-Type': 'text/event-stream' }); response.write('event: deployment.future.v1\r'); response.end('\nid: next\r\ndata: {"progress":1}\r\n\r\n');
  });
  try { const rows = []; for await (const event of new PlatformClient({ baseURL: host.url, credential: 'secret' }).deployment.operation('upgrade').stream({ cursor: 'opaque', lastEventId: 'previous' })) rows.push(event); assert.equal(rows.length, 1); assert.equal(rows[0].id, 'next'); assert.deepEqual(rows[0].data, { progress: 1 }); assert.equal(requests, 1); }
  finally { await host.close(); }
});

test('credential resolution is bounded even when the provider never settles', async () => {
  const client = new Client({ baseURL: 'http://nexus.example', credentialProvider: () => new Promise(() => {}), timeoutMs: 15 });
  await assert.rejects(client.profile.fetch(), TimeoutError);
});
test('non-JSON errors retain a bounded diagnostic body', async () => {
  const host = await server((_request, response) => { response.writeHead(502, { 'Content-Type': 'text/plain' }); response.end('upstream unavailable\n' + 'x'.repeat(5000)); });
  try { await assert.rejects(new Client({ baseURL: host.url, credential: 'secret' }).profile.fetch(), error => error instanceof ServerError && error.responseBody.startsWith('upstream unavailable\n') && error.responseBody.length === 4096); }
  finally { await host.close(); }
});
