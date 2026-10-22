import { Client, DeviceFlow, ExecutorClient, OAuthCredentials, Steps } from '@cybros/agent';
import type { CredentialDocument, CredentialStore, Download, InboxTask, JsonObject, TaskDetail } from '@cybros/agent';
import { mkdir, open, readFile, rename, rm, stat } from 'node:fs/promises';
import type { FileHandle } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { setTimeout as pause } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { createGunzip } from 'node:zlib';

const toolName = 'capture_text';
const textLimit = 16_384;
const description = 'Capture the supplied text as a UTF-8 attachment.';
const inputSchema = { type: 'object' as const, properties: { text: { type: 'string', maxLength: textLimit } }, required: ['text'], additionalProperties: false };
const effectProfile = { kind: 'pure' as const, destructive: false, effect_scope: 'closed' as const, idempotency: 'intrinsic' as const, reconciliation: 'none' as const };
const emit = (event: string, fields: object = {}) => process.stdout.write(JSON.stringify({ event, ...fields }) + '\n');

export const usage = `Usage: pnpm exec tsx examples/standalone-agent.ts COMMAND [OPTIONS]

Every command requires --url URL --credentials PATH; --timeout-ms N defaults to 300000.
  connect --agent-identifier ID
  start --model ID --text TEXT --output-dir DIR
  start --model ID --text TEXT --submit-only
  resume --workspace ID --conversation ID --input ID --output-dir DIR

Use a private directory for credentials. A command owns PATH.lock until shutdown.
After a hard crash, remove that lock only after confirming the process is stopped.
The example recovers accepted Inputs, but does not recover an interrupted tool claim.
`;

interface CommonOptions { url: string; credentials: string; timeoutMs: number; }
type Options = CommonOptions & (
  { command: 'connect'; agentIdentifier: string } |
  { command: 'start'; model: string; text: string; submitOnly: boolean; outputDir: string | null } |
  { command: 'resume'; workspaceId: string; conversationId: string; inputId: string; outputDir: string }
);
interface Accepted { workspace_public_id: string; conversation_public_id: string; input_public_id: string; }

export function parseOptions(argv: string[]): Options {
  const [command, ...args] = argv;
  if (command !== 'connect' && command !== 'start' && command !== 'resume') throw new Error('Choose connect, start or resume; see --help.');
  const extra = command === 'connect' ? ['agent-identifier'] : command === 'start' ? ['model', 'text', 'output-dir'] : ['workspace', 'conversation', 'input', 'output-dir'];
  const options = Object.fromEntries(['url', 'credentials', 'timeout-ms', ...extra].map(name => [name, { type: 'string' as const }]));
  const parsed = parseArgs({ args, strict: true, allowPositionals: false, options: { ...options, ...(command === 'start' ? { 'submit-only': { type: 'boolean' as const } } : {}) } });
  const values: Record<string, string | boolean | undefined> = parsed.values;
  const required = (name: string): string => {
    const value = values[name];
    if (typeof value !== 'string' || !value.trim()) throw new Error(`--${name} is required.`);
    return value;
  };
  const timeoutMs = Number(values['timeout-ms'] ?? 300_000);
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 2_147_483_647) throw new Error('--timeout-ms must be a positive integer no greater than 2147483647.');
  const common = { url: required('url'), credentials: resolve(required('credentials')), timeoutMs };
  if (command === 'connect') return { ...common, command, agentIdentifier: required('agent-identifier') };
  if (command === 'resume') return { ...common, command, workspaceId: required('workspace'), conversationId: required('conversation'), inputId: required('input'), outputDir: resolve(required('output-dir')) };
  const text = required('text');
  if (text.length > textLimit) throw new Error(`--text exceeds ${textLimit} characters.`);
  const submitOnly = values['submit-only'] === true;
  return { ...common, command, model: required('model'), text, submitOnly, outputDir: submitOnly && values['output-dir'] === undefined ? null : resolve(required('output-dir')) };
}

/** Application-owned storage; the SDK has no filesystem or process policy. */
export class FileCredentialStore implements CredentialStore {
  #queue: Promise<void> = Promise.resolve();
  private constructor(readonly path: string, private readonly lock: FileHandle) {}

  static async acquire(path: string): Promise<FileCredentialStore> {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    await privatePath(dirname(path));
    let lock: FileHandle;
    try { lock = await open(path + '.lock', 'wx', 0o600); }
    catch (error) {
      if (errorCode(error) === 'EEXIST') throw new Error(`Credential path is locked: ${path}.lock. After a hard crash, remove it only after confirming the process is stopped.`);
      throw error;
    }
    return new FileCredentialStore(path, lock);
  }

  async read(): Promise<unknown | null> {
    try { await privatePath(this.path); }
    catch (error) { if (errorCode(error) === 'ENOENT') return null; throw error; }
    const text = await readFile(this.path, 'utf8');
    try { return JSON.parse(text) as unknown; }
    catch { throw new Error('Credential file is not valid JSON.'); }
  }

  async write(document: CredentialDocument): Promise<void> {
    try { await privatePath(this.path); }
    catch (error) { if (errorCode(error) !== 'ENOENT') throw error; }
    const temporary = this.path + '.' + crypto.randomUUID() + '.tmp';
    const file = await open(temporary, 'wx', 0o600);
    try {
      try { await file.writeFile(JSON.stringify(document) + '\n', 'utf8'); await file.sync(); }
      finally { await file.close(); }
      // Atomic publication is sufficient here; this example promises no power-loss durability.
      await rename(temporary, this.path);
    } finally { await rm(temporary, { force: true }); }
  }

  async delete(): Promise<void> { await rm(this.path, { force: true }); }

  withLock<T>(operation: () => Promise<T>): Promise<T> {
    const pending = this.#queue.then(operation);
    this.#queue = pending.then(() => {}, () => {});
    return pending;
  }

  async release(): Promise<void> {
    await this.#queue;
    await this.lock.close();
    await rm(this.path + '.lock');
  }
}

async function privatePath(path: string): Promise<void> {
  const info = await stat(path);
  if (info.mode & 0o077 || process.getuid && info.uid !== process.getuid()) throw new Error(`Credential storage must be private and owned by the current user: ${path}`);
}

function errorCode(error: unknown): string | undefined {
  return error instanceof Error && 'code' in error ? String(error.code) : undefined;
}

/** Consume a caller-owned download, publishing only a completely received file. */
export async function saveDownload(download: Download, path: string, signal: AbortSignal, validate?: (path: string) => Promise<void>): Promise<void> {
  if (download.status !== 200 || !download.body) {
    await download.body?.cancel();
    throw new Error('Expected a complete download.');
  }
  const reader = download.body.getReader();
  const temporary = path + '.' + crypto.randomUUID() + '.tmp';
  let file: FileHandle | undefined;
  try {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    file = await open(temporary, 'wx', 0o600);
    while (true) {
      signal.throwIfAborted();
      const chunk = await reader.read();
      if (chunk.done) break;
      await file.writeFile(chunk.value);
    }
    signal.throwIfAborted();
    await file.close(); file = undefined;
    await validate?.(temporary);
    await rename(temporary, path);
  } finally {
    await reader.cancel().catch(() => {}); reader.releaseLock();
    await file?.close();
    await rm(temporary, { force: true });
  }
}

/** HTTP EOF alone cannot prove the exporter reached its completion record. */
export async function validateExport(path: string, signal: AbortSignal): Promise<void> {
  let first: string | undefined, last: string | undefined, pending = '';
  const decoder = new TextDecoder('utf-8', { fatal: true });
  await pipeline(createReadStream(path), createGunzip(), async source => {
    for await (const chunk of source) {
      pending += decoder.decode(chunk as Uint8Array, { stream: true });
      let boundary;
      while ((boundary = pending.indexOf('\n')) !== -1) {
        const line = pending.slice(0, boundary); pending = pending.slice(boundary + 1);
        first ??= line; last = line;
      }
    }
    pending += decoder.decode();
  }, { signal });
  try {
    if (pending || first === undefined || last === undefined || (JSON.parse(first) as { type?: unknown })?.type !== 'export' || (JSON.parse(last) as { type?: unknown })?.type !== 'end') throw new Error();
  } catch { throw new Error('The diagnostic export has no complete opening and ending records.'); }
}

async function connect(options: Extract<Options, { command: 'connect' }>, authority: DeviceFlow, store: FileCredentialStore, signal: AbortSignal): Promise<OAuthCredentials> {
  if (await store.read() !== null) throw new Error('Credentials already exist; use start or resume, or choose a new private credential path.');
  signal.throwIfAborted();
  const authorization = await authority.requestAuthorization({ agent_identifier: options.agentIdentifier, agent_display_name: 'Standalone SDK Agent', executor_display_name: 'Standalone SDK Agent' });
  emit('authorization', { verification_uri_complete: authorization.verification_uri_complete, user_code: authorization.user_code });
  let bundle;
  try { bundle = await authority.awaitCredentials(authorization, { signal }); }
  catch (error) {
    if (!signal.aborted) throw error;
    let canceled = false;
    try { canceled = await authority.cancelAuthorization(authorization) === 'cancelled'; }
    catch { /* An unknown cancellation result cannot prove no credentials were issued. */ }
    if (canceled) { await authority.drain(); throw error; }
    // Consume may have won: finish and save the owned result before honoring interruption.
    bundle = await authority.awaitCredentials(authorization);
  }
  return OAuthCredentials.issue({ credentials: bundle, authority, store });
}

async function prepare(member: Client, executor: ExecutorClient, options: Extract<Options, { command: 'start' }>, signal: AbortSignal): Promise<Accepted> {
  await member.profile.declareConfiguration({
    configuration: { prompt_mechanism: 'default', approval_mode: 'bypass', tool_definitions: [{ type: 'function', function: { name: toolName, description, parameters: inputSchema }, effect_profile: effectProfile }] },
    prompt_documents: { system_prompt: { content: 'Reply concisely to the user. A separate application step captures the submitted text as an attachment.' } },
  }, { signal });
  await announce(executor, signal);
  const { workspace } = await member.workspaces.create({ name: 'Standalone SDK Agent' }, { idempotencyKey: crypto.randomUUID(), signal });
  const { conversation } = await member.workspace(workspace.public_id).conversations.create({ title: 'Standalone SDK Agent' }, { idempotencyKey: crypto.randomUUID(), signal });
  const { input } = await member.workspace(workspace.public_id).conversation(conversation.public_id).inputs.create({ kind: 'direct_reply', text: options.text, model: { model: options.model }, approval_mode: 'bypass', steps: [Steps.tool({ key: toolName, name: toolName, input: { text: options.text }, timeout_ms: 300_000 })] }, { idempotencyKey: crypto.randomUUID(), signal });
  return { workspace_public_id: workspace.public_id, conversation_public_id: conversation.public_id, input_public_id: input.public_id };
}

async function announce(executor: ExecutorClient, signal: AbortSignal): Promise<void> {
  await executor.announce({ services: { agent: { tools: [{ name: toolName, description, input_schema: inputSchema, effect_profile: effectProfile, timeout_ms: 300_000 }] } } }, { signal });
}

export function captureText(input: JsonObject): string {
  if (Object.keys(input).length !== 1 || typeof input.text !== 'string' || input.text.length > textLimit) throw new Error('capture_text requires only a text string of at most 16384 characters.');
  return input.text;
}

export function selectedTask(task: Pick<InboxTask, 'kind' | 'tool_name' | 'run_public_id' | 'workspace_public_id' | 'conversation_public_id'>, accepted: Accepted, runId: string): boolean {
  return task.kind === 'tool_call' && task.tool_name === toolName && task.run_public_id === runId && task.workspace_public_id === accepted.workspace_public_id && task.conversation_public_id === accepted.conversation_public_id;
}

async function serve(executor: ExecutorClient, accepted: Accepted, runId: string, signal: AbortSignal): Promise<void> {
  let after: string | undefined;
  do {
    const page = await executor.inbox.list(after === undefined ? {} : { after }, { signal });
    for (const row of page.items) {
      if (!selectedTask(row, accepted, runId)) continue;
      if (row.claimed) throw new Error('The selected tool is already claimed; this example cannot recover a previous process claim.');
      const task = executor.inboxTask(runId, row.task_key);
      const claim = await task.claim({ signal });
      if (!selectedTask(claim.task, accepted, runId) || claim.task.task_key !== row.task_key) throw new Error('Claim did not identify the selected application tool.');
      const text = captureText(claim.task.tool_input);
      const upload = await executor.uploads.create(new Blob([text], { type: 'text/plain' }), 'capture.txt', { signal });
      await task.commit({ claim_token: claim.claim_token, outcome: 'completed', is_error: false, structured_content: { text }, content: [{ type: 'text', text }, { type: 'resource_link', uri: `nexus://uploads/${upload.public_id}`, name: 'capture.txt', mimeType: 'text/plain', size: upload.byte_size }] }, { signal });
      emit('tool_completed', { run_public_id: runId, task_key: row.task_key, upload_public_id: upload.public_id });
    }
    after = page.next_after ?? undefined;
  } while (after !== undefined);
}

function captureUpload(detail: TaskDetail): string {
  if (detail.task.status !== 'completed' || detail.task.tool_name !== toolName || !Array.isArray(detail.content)) throw new Error('The capture task has no completed attachment.');
  const links = detail.content.filter((value): value is JsonObject => value !== null && typeof value === 'object' && !Array.isArray(value) && value.type === 'resource_link' && value.name === 'capture.txt');
  const uri = links[0]?.uri;
  if (links.length !== 1 || typeof uri !== 'string') throw new Error('The committed capture attachment is missing.');
  const url = new URL(uri);
  if (url.protocol !== 'nexus:' || url.host !== 'uploads' || !/^\/[0-9a-f-]+$/i.test(url.pathname) || url.search || url.hash) throw new Error('The committed capture attachment has an invalid upload URI.');
  return url.pathname.slice(1);
}

async function observe(member: Client, executor: ExecutorClient, accepted: Accepted, outputDir: string, signal: AbortSignal): Promise<void> {
  const workspace = member.workspace(accepted.workspace_public_id);
  const chat = workspace.conversation(accepted.conversation_public_id);
  const execution = chat.inputExecution(accepted.input_public_id);
  let reportedRun: string | null = null;
  while (true) {
    signal.throwIfAborted();
    const snapshot = await execution.recover({ signal });
    if (execution.blocked_reason) throw new Error(`Input is blocked: ${execution.blocked_reason}`);
    const runId = snapshot?.execution.run_public_id;
    if (snapshot && runId) {
      if (reportedRun !== runId) { emit('execution', { ...accepted, ...snapshot.execution }); reportedRun = runId; }
      if (snapshot.needs_attention) throw new Error(`Run needs attention: ${snapshot.attention?.reason ?? 'inspect the Run'}`);
      if (snapshot.run_status === 'paused') throw new Error('Run is paused; resume it through the public Run API before observing again.');
      if (snapshot.terminal && (snapshot.run_status === 'completed' || snapshot.run_status === 'canceled')) {
        if (snapshot.status !== 'completed' || snapshot.run_status !== 'completed') throw new Error(`Execution ended with ${snapshot.status}; Run is ${snapshot.run_status}.`);
        const detail = await workspace.run(runId).task(toolName).fetch({ signal });
        const uploadId = captureUpload(detail);
        const capturePath = join(outputDir, 'capture.txt'), exportPath = join(outputDir, 'conversation.jsonl.gz');
        await saveDownload(await member.uploads.bytes(uploadId, { signal }), capturePath, signal);
        await saveDownload(await chat.export({ signal }), exportPath, signal, path => validateExport(path, signal));
        emit('completed', { ...accepted, ...snapshot.execution, task_key: toolName, upload_public_id: uploadId, capture_path: capturePath, export_path: exportPath, text: snapshot.content });
        return;
      }
      await serve(executor, accepted, runId, signal);
    }
    await pause(200, undefined, { signal });
  }
}

export async function main(argv: string[]): Promise<void> {
  if (argv.includes('--help')) { process.stdout.write(usage); return; }
  const options = parseOptions(argv);
  const authority = new DeviceFlow({ baseURL: options.url, timeoutMs: 30_000 });
  const store = await FileCredentialStore.acquire(options.credentials);
  const interruption = new AbortController();
  const stop = () => interruption.abort(new Error('Command interrupted.'));
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
  const signal = AbortSignal.any([interruption.signal, AbortSignal.timeout(options.timeoutMs)]);
  let credentials: OAuthCredentials | null = null;
  try {
    credentials = options.command === 'connect' ? await connect(options, authority, store, signal) : await OAuthCredentials.load({ authority, store });
    if (!credentials) throw new Error('Credentials are missing; run connect first.');
    const member = new Client({ baseURL: options.url, credentialProvider: credentials.provider('member') });
    const executor = new ExecutorClient({ baseURL: options.url, credentialProvider: credentials.provider('executor') });
    if (options.command === 'connect') {
      // These reads also prove both saved credential planes belong to the same Agent.
      const profile = await member.profile.fetch();
      const address = await executor.executor();
      if (address.executor.kind !== 'agent' || address.executor.agent_public_id !== profile.member.public_id) throw new Error('Saved credentials do not describe one Agent.');
      emit('connected', { agent_public_id: profile.member.public_id, executor_public_id: address.executor.public_id });
      signal.throwIfAborted();
    } else if (options.command === 'start') {
      const accepted = await prepare(member, executor, options, signal);
      emit('accepted', accepted);
      if (!options.submitOnly) await observe(member, executor, accepted, options.outputDir!, signal);
    } else {
      await announce(executor, signal);
      await observe(member, executor, { workspace_public_id: options.workspaceId, conversation_public_id: options.conversationId, input_public_id: options.inputId }, options.outputDir, signal);
    }
  } finally {
    try { await credentials?.drain(); await authority.drain(); await store.release(); }
    finally { process.removeListener('SIGINT', stop); process.removeListener('SIGTERM', stop); }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { await main(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`${error instanceof Error ? error.message : 'Standalone Agent failed.'}\n`); process.exitCode = 1; }
}
