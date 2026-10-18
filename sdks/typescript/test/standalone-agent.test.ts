import { afterEach, expect, test } from 'vitest';
import { chmod, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gzipSync } from 'node:zlib';
import type { CredentialDocument, Download } from '@cybros/agent';
import { captureText, FileCredentialStore, main, parseOptions, saveDownload, selectedTask, validateExport } from '../examples/standalone-agent.js';

const directories: string[] = [];
async function directory() { const path = await mkdtemp(join(tmpdir(), 'standalone-agent-')); directories.push(path); return path; }
afterEach(async () => { for (const path of directories.splice(0)) await rm(path, { recursive: true, force: true }); });
const document: CredentialDocument = { version: 2, authentication_kind: 'oauth', connection: 'connection', rotation: 0, access_token: 'member-fixture', executor_access_token: 'executor-fixture', refresh_token: 'refresh-fixture', expires_at: '2100-01-01T00:00:00Z' };
const common = ['--url', 'http://127.0.0.1:3000', '--credentials', '/private/example/credentials.json'];

test('CLI requires explicit recovery identity, model, text and output intent', () => {
  expect(parseOptions(['start', ...common, '--model', 'example/model', '--text', 'hello', '--submit-only'])).toMatchObject({ command: 'start', submitOnly: true, outputDir: null });
  expect(parseOptions(['resume', ...common, '--workspace', 'workspace', '--conversation', 'chat', '--input', 'input', '--output-dir', '/private/output'])).toMatchObject({ command: 'resume', inputId: 'input' });
  expect(() => parseOptions(['start', ...common, '--model', 'example/model', '--text', 'hello'])).toThrow('--output-dir is required');
  expect(() => parseOptions(['resume', ...common, '--workspace', 'workspace', '--conversation', 'chat', '--output-dir', '/private/output'])).toThrow('--input is required');
  expect(() => parseOptions(['connect', ...common, '--agent-identifier', 'example', '--timeout-ms', '0'])).toThrow('--timeout-ms');
  expect(() => parseOptions(['connect', ...common, '--agent-identifier', 'example', '--submit-only'])).toThrow();
  expect(() => parseOptions(['start', ...common, '--model', 'example/model', '--text', 'x'.repeat(16_385), '--submit-only'])).toThrow('--text exceeds');
});

test('credential ownership excludes another command, serializes writes and releases after a failure', async () => {
  const root = await directory(), path = join(root, 'credentials.json');
  const store = await FileCredentialStore.acquire(path);
  try {
    await expect(FileCredentialStore.acquire(path)).rejects.toThrow('Credential path is locked');
    expect(await store.read()).toBeNull();
    const failed = store.withLock(async () => { await store.write(document); throw new Error('command failed'); });
    const next = store.withLock(async () => { expect(await store.read()).toEqual(document); await store.write({ ...document, rotation: 1 }); });
    await expect(failed).rejects.toThrow('command failed'); await next;
    expect(await store.read()).toEqual({ ...document, rotation: 1 });
    expect((await stat(path)).mode & 0o777).toBe(0o600);
    expect((await stat(path + '.lock')).mode & 0o777).toBe(0o600);
    expect((await readdir(root)).sort()).toEqual(['credentials.json', 'credentials.json.lock']);
  } finally { await store.release(); }
  const replacement = await FileCredentialStore.acquire(path);
  try { expect(await replacement.read()).toEqual({ ...document, rotation: 1 }); }
  finally { await replacement.release(); }
});

test('credential storage refuses widened permissions and never prints malformed file contents', async () => {
  const root = await directory(), path = join(root, 'credentials.json');
  const store = await FileCredentialStore.acquire(path);
  try {
    await store.write(document); await chmod(path, 0o640);
    await expect(store.read()).rejects.toThrow('must be private');
    await expect(store.write(document)).rejects.toThrow('must be private');
    await chmod(path, 0o400); expect(await store.read()).toEqual(document);
    await chmod(path, 0o600); await writeFile(path, '{do not show this raw value');
    await expect(store.read()).rejects.toThrow('Credential file is not valid JSON.');
  } finally { await store.release(); }
  await chmod(root, 0o755);
  await expect(FileCredentialStore.acquire(path)).rejects.toThrow('must be private');
});

test('connect preserves an existing connection and failed startup releases credential ownership', async () => {
  const root = await directory(), path = join(root, 'credentials.json');
  await writeFile(path, JSON.stringify(document), { mode: 0o600 });
  const args = ['--url', 'http://127.0.0.1:1', '--credentials', path];
  await expect(main(['connect', ...args, '--agent-identifier', 'example.instance'])).rejects.toThrow('Credentials already exist');
  expect(JSON.parse(await readFile(path, 'utf8'))).toEqual(document);
  expect(await readdir(root)).toEqual(['credentials.json']);
  await rm(path);
  await expect(main(['start', ...args, '--model', 'example/model', '--text', 'hello', '--submit-only'])).rejects.toThrow('Credentials are missing');
  expect(await readdir(root)).toEqual([]);
});

function download(body: ReadableStream<Uint8Array>): Download {
  return { status: 200, replayed: false, requestId: null, body, etag: null, contentType: 'application/octet-stream', contentRange: null, contentLength: null };
}
function bytes(value: Uint8Array): Download {
  return download(new ReadableStream({ start(controller) { controller.enqueue(value.subarray(0, 10)); controller.enqueue(value.subarray(10)); controller.close(); } }));
}

test('failed or canceled downloads preserve the prior file and discard temporary output', async () => {
  const root = await directory(), path = join(root, 'capture.txt');
  await writeFile(path, 'previous');
  let reads = 0;
  const broken = download(new ReadableStream({ pull(controller) { if (reads++ === 0) controller.enqueue(new TextEncoder().encode('partial')); else controller.error(new Error('broken body')); } }));
  await expect(saveDownload(broken, path, new AbortController().signal)).rejects.toThrow('broken body');
  expect(await readFile(path, 'utf8')).toBe('previous');
  let canceled = false;
  const idle = download(new ReadableStream({ cancel() { canceled = true; } }));
  await expect(saveDownload(idle, path, AbortSignal.abort(new Error('stop')))).rejects.toThrow('stop');
  expect(canceled).toBe(true);
  expect(await readdir(root)).toEqual(['capture.txt']);
});

test('export publication requires a valid gzip member and its end marker', async () => {
  const root = await directory(), path = join(root, 'conversation.jsonl.gz');
  const signal = new AbortController().signal;
  const complete = gzipSync('{"type":"export"}\n{"type":"turn","text":"你好"}\n{"type":"end"}\n');
  await saveDownload(bytes(complete), path, signal, temporary => validateExport(temporary, signal));
  expect(await readFile(path)).toEqual(complete);
  const incomplete = gzipSync('{"type":"export"}\n');
  await expect(saveDownload(bytes(incomplete), path, signal, temporary => validateExport(temporary, signal))).rejects.toThrow('complete opening and ending records');
  await expect(saveDownload(bytes(complete.subarray(0, complete.length - 8)), path, signal, temporary => validateExport(temporary, signal))).rejects.toThrow();
  expect(await readFile(path)).toEqual(complete);
  expect(await readdir(root)).toEqual(['conversation.jsonl.gz']);
});

test('only the exact Run and known application tool can be served', () => {
  const accepted = { workspace_public_id: 'workspace', conversation_public_id: 'conversation', input_public_id: 'input' };
  const task = { kind: 'tool_call', tool_name: 'capture_text', run_public_id: 'run', workspace_public_id: 'workspace', conversation_public_id: 'conversation' };
  expect(selectedTask(task, accepted, 'run')).toBe(true);
  for (const change of [{ run_public_id: 'other' }, { workspace_public_id: 'other' }, { conversation_public_id: 'other' }, { tool_name: 'unknown' }, { kind: 'approval' }]) expect(selectedTask({ ...task, ...change }, accepted, 'run')).toBe(false);
  expect(captureText({ text: '你好' })).toBe('你好');
  expect(() => captureText({ text: 'hello', command: 'unexpected' })).toThrow('requires only');
  expect(() => captureText({ text: false })).toThrow('requires only');
});
