import WebSocket from 'ws';
import { withinSignal } from './http.js';
import { AsyncQueue } from './feeds.js';
import { BufferOverflow, CancelledError, MalformedResponse, RealtimeDisconnected, SDKError, TimeoutError } from './errors.js';
import { nonempty, object } from './json.js';
import { shape } from './decode.js';
import type { ClientOptions, RequestOptions } from './http.js';
import type { EventSubscription } from './feeds.js';
import type { JsonObject } from './json.js';
export class SubscriptionRejected extends SDKError {}
export interface RealtimeOptions extends Pick<RequestOptions, 'timeoutMs'> { maxBuffer?: number; heartbeatTimeoutMs?: number; }
interface PendingSubscription {
  queue: AsyncQueue<unknown>; confirmed: boolean; decode(value: unknown): unknown;
  ready(): void; fail(error: unknown): void; close(): void;
}
export interface ExecutorWakeup { type: string; [key: string]: unknown; }
/** Optional server WebSocket adapter. Importing the HTTP entry point does not load ws. */
export class RealtimeClient {
  readonly #origin: string;
  readonly #credential: () => string | Promise<string>;
  readonly #options: RealtimeOptions;
  #socket: WebSocket | undefined;
  #connecting: Promise<void> | undefined;
  #subscriptions = new Map<string, PendingSubscription>();
  #heartbeat: ReturnType<typeof setInterval> | undefined;
  #lastPing = 0;
  #generation = 0;
  constructor(options: ClientOptions & RealtimeOptions) {
    const origin = new URL(options.baseURL);
    if (!['http:', 'https:'].includes(origin.protocol) || origin.username || origin.password || origin.search || origin.hash || origin.pathname !== '/') throw new TypeError('baseURL must be an HTTP(S) origin');
    if ((options.credential === undefined) === (options.credentialProvider === undefined)) throw new TypeError('Provide one credential source');
    for (const value of [options.timeoutMs, options.heartbeatTimeoutMs]) if (value !== undefined && (!Number.isFinite(value) || value <= 0)) throw new TypeError('Realtime timeouts must be finite and positive');
    this.#origin = origin.origin; this.#credential = options.credentialProvider ?? (() => options.credential!); this.#options = options;
  }
  conversationEvents(workspaceId: string, conversationId: string, options: RequestOptions = {}) { return this.subscribe('AgentAPI::V1::ConversationEventsChannel', { workspace_id: workspaceId, conversation_id: conversationId }, message => shape('Event', message, 'event'), options); }
  runEvents(workspaceId: string, runId: string, options: RequestOptions = {}) { return this.subscribe('AgentAPI::V1::RunEventsChannel', { workspace_id: workspaceId, run_id: runId }, message => shape('Event', message, 'event'), options); }
  inferenceEvents(workspaceId: string, requestId: string, options: RequestOptions = {}) { return this.subscribe('AgentAPI::V1::InferenceRequestEventsChannel', { workspace_id: workspaceId, inference_request_id: requestId }, message => shape('InferenceRequestEvent', message, 'event'), options); }
  conversationTranscript(workspaceId: string, conversationId: string, options: RequestOptions = {}) { return this.subscribe('AgentAPI::V1::ConversationEventsChannel', { workspace_id: workspaceId, conversation_id: conversationId, items: 'transcript' }, message => shape('TranscriptItem', message, 'event'), options); }
  runTranscript(workspaceId: string, runId: string, options: RequestOptions = {}) { return this.subscribe('AgentAPI::V1::RunEventsChannel', { workspace_id: workspaceId, run_id: runId, items: 'transcript' }, message => shape('TranscriptItem', message, 'event'), options); }
  conversationProgress(workspaceId: string, conversationId: string, options: RequestOptions = {}) { return this.subscribe('AgentAPI::V1::ConversationEventsChannel', { workspace_id: workspaceId, conversation_id: conversationId, items: 'progress' }, message => shape('ProgressFrame', message, 'frame'), options); }
  runProgress(workspaceId: string, runId: string, options: RequestOptions = {}) { return this.subscribe('AgentAPI::V1::RunEventsChannel', { workspace_id: workspaceId, run_id: runId, items: 'progress' }, message => shape('ProgressFrame', message, 'frame'), options); }
  executorInbox(options: RequestOptions = {}) { return this.subscribe('AgentAPI::V1::ExecutorInboxChannel', {}, message => object(message) as ExecutorWakeup, options); }
  async close(): Promise<void> {
    this.#generation++;
    const socket = this.#socket; this.#socket = undefined;
    this.#connecting = undefined;
    if (this.#heartbeat) clearInterval(this.#heartbeat);
    for (const sub of [...this.#subscriptions.values()]) sub.close();
    if (!socket) return;
    if (socket.readyState === WebSocket.CLOSED) return;
    await new Promise<void>(resolve => {
      const timer = setTimeout(() => { socket.terminate(); resolve(); }, 1000);
      socket.once('close', () => { clearTimeout(timer); resolve(); }); socket.close();
    });
  }
  /** Ends existing sockets; the next subscription resolves the credential provider again. */
  async reconnect(): Promise<void> { await this.close(); }
  private async subscribe<T>(channel: string, params: JsonObject, decode: (message: unknown) => T, options: RequestOptions): Promise<EventSubscription<T>> {
    if (options.signal?.aborted) throw new CancelledError('Subscription cancelled');
    const connecting = this.connect();
    await (options.signal ? withinSignal(connecting, options.signal).catch(error => { if (options.signal?.aborted) throw new CancelledError('Subscription cancelled'); throw error; }) : connecting);
    const socket = this.#socket!;
    const identifier = JSON.stringify({ channel, ...params, _cybros_sdk_subscription_id: crypto.randomUUID() });
    const queue = new AsyncQueue<T>(this.#options.maxBuffer ?? 256);
    let timer: ReturnType<typeof setTimeout>;
    let resolveReady: () => void = () => {};
    let rejectReady: (error: unknown) => void = () => {};
    const ready = new Promise<void>((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
    const cleanup = () => { clearTimeout(timer); options.signal?.removeEventListener('abort', abort); this.#subscriptions.delete(identifier); };
    const close = () => { cleanup(); queue.close(); rejectReady(new CancelledError('Subscription closed')); if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ command: 'unsubscribe', identifier })); };
    const abort = () => { fail(new CancelledError('Subscription cancelled')); };
    const fail = (error: unknown) => { cleanup(); queue.close(error); rejectReady(error); if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ command: 'unsubscribe', identifier })); };
    const subscription: PendingSubscription = { queue: queue as AsyncQueue<unknown>, confirmed: false, decode, ready: () => { clearTimeout(timer); subscription.confirmed = true; resolveReady(); }, fail, close };
    timer = setTimeout(() => fail(new TimeoutError('Subscription confirmation timed out')), options.timeoutMs ?? this.#options.timeoutMs ?? 10_000);
    this.#subscriptions.set(identifier, subscription);
    options.signal?.addEventListener('abort', abort, { once: true });
    socket.send(JSON.stringify({ command: 'subscribe', identifier }));
    await ready;
    return { close, [Symbol.asyncIterator]: () => {
      const iterator = queue[Symbol.asyncIterator]();
      return { next: () => iterator.next(), return: async () => { close(); return { value: undefined, done: true }; } };
    } };
  }
  private connect(): Promise<void> {
    if (this.#connecting) return this.#connecting;
    if (this.#socket?.readyState === WebSocket.OPEN) return Promise.resolve();
    const generation = this.#generation;
    const connecting = (async () => {
      const controller = new AbortController();
      const credentialTimer = setTimeout(() => controller.abort(new TimeoutError('Credential resolution timed out')), this.#options.timeoutMs ?? 10_000);
      let credential: string;
      try { credential = nonempty(await withinSignal(Promise.resolve().then(this.#credential), controller.signal), 'credential'); } finally { clearTimeout(credentialTimer); }
      if (generation !== this.#generation) throw new CancelledError('Connection closed');
      const url = new URL('/agent_api/v1/cable', this.#origin); url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
      const socket = new WebSocket(url, ['actioncable-v1-json', 'actioncable-unsupported'], { headers: { Authorization: `Bearer ${credential}`, Origin: this.#origin }, followRedirects: false, handshakeTimeout: this.#options.timeoutMs ?? 10_000 });
      this.#socket = socket;
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => { socket.terminate(); reject(new TimeoutError('ActionCable welcome timed out')); }, this.#options.timeoutMs ?? 10_000);
        let welcomed = false;
        const fail = (error: Error) => {
          clearTimeout(timer);
          if (this.#socket === socket) {
            this.#socket = undefined;
            if (this.#heartbeat) clearInterval(this.#heartbeat);
            for (const sub of [...this.#subscriptions.values()]) sub.fail(error);
          }
          if (!welcomed) reject(error);
        };
        socket.on('error', () => fail(new RealtimeDisconnected('WebSocket transport failed')));
        socket.on('unexpected-response', (_request, response) => { response.resume(); socket.terminate(); fail(new RealtimeDisconnected(`WebSocket upgrade refused (${response.statusCode})`)); });
        socket.on('close', () => fail(new RealtimeDisconnected('WebSocket disconnected')));
        socket.on('message', data => {
          if (this.#socket !== socket) return;
          let frame: Record<string, unknown>;
          try { frame = object(JSON.parse(data.toString())); } catch { return; }
          if (frame.type === 'welcome') {
            if (socket.protocol !== 'actioncable-v1-json') { socket.terminate(); fail(new RealtimeDisconnected('Unsupported ActionCable protocol')); return; }
            welcomed = true; clearTimeout(timer); this.#lastPing = Date.now();
            const staleMs = this.#options.heartbeatTimeoutMs ?? 30_000;
            this.#heartbeat = setInterval(() => { if (Date.now() - this.#lastPing > staleMs) { socket.terminate(); fail(new RealtimeDisconnected('ActionCable heartbeat timed out')); } }, Math.max(100, staleMs / 2));
            resolve(); return;
          }
          if (frame.type === 'ping') {
            this.#lastPing = Date.now();
            for (const [id, sub] of this.#subscriptions) if (sub.confirmed && JSON.parse(id).channel === 'AgentAPI::V1::ExecutorInboxChannel') socket.send(JSON.stringify({ command: 'message', identifier: id, data: JSON.stringify({ action: 'pong' }) }));
            return;
          }
          if (frame.type === 'disconnect') { socket.close(); fail(new RealtimeDisconnected('ActionCable disconnected')); return; }
          if (typeof frame.identifier !== 'string') return;
          const sub = this.#subscriptions.get(frame.identifier); if (!sub) return;
          if (frame.type === 'confirm_subscription') sub.ready();
          else if (frame.type === 'reject_subscription') sub.fail(new SubscriptionRejected('ActionCable subscription rejected'));
          else if ('message' in frame && sub.confirmed) {
            try { sub.queue.push(sub.decode(frame.message)); } catch (error) { sub.fail(error); }
          }
        });
      });
    })();
    this.#connecting = connecting;
    void connecting.finally(() => { if (this.#connecting === connecting) this.#connecting = undefined; }).catch(() => {});
    return connecting;
  }
}
