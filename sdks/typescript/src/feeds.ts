import { BufferOverflow, CancelledError, MalformedResponse, RealtimeDisconnected, RetentionGap } from './errors.js';
import type { RequestOptions } from './http.js';
export interface EventPosition { cursor: string | null; sequence: number; }
export interface DurableEvent { public_id: string; sequence: number; cursor: string; }
export interface ReplayPage<E> { items: E[]; next_after: string | null; watermark: number; }
export interface EventSubscription<E> extends AsyncIterable<E> { close(): void | Promise<void>; }
export interface FeedOptions<E extends DurableEvent = import('./models.js').Event> {
  position?: EventPosition;
  subscribe?: (options: RequestOptions) => Promise<EventSubscription<E>>;
  signal?: AbortSignal;
  onRetentionGap?: (gap: RetentionGap) => void | Promise<void>;
  maxReconnects?: number;
}
export interface FeedConfiguration<E extends DurableEvent> extends FeedOptions<E> {
  replay(after: string | undefined, options: RequestOptions): Promise<ReplayPage<E>>;
}
/** Ordered at-least-once delivery. Advancing the iterator acknowledges its previous item. */
export class DurableFeed<E extends DurableEvent = import('./models.js').Event> implements AsyncIterable<E> {
  #position: EventPosition;
  #active = false;
  #stopped = false;
  #controller = new AbortController();
  #subscription: EventSubscription<E> | undefined;
  constructor(private readonly configuration: FeedConfiguration<E>) {
    this.#position = { ...(configuration.position ?? { cursor: null, sequence: 0 }) };
    if (!Number.isSafeInteger(this.#position.sequence) || this.#position.sequence < 0 || this.#position.sequence > 0 && !this.#position.cursor) throw new TypeError('A saved feed position requires its sequence and opaque cursor');
    if (configuration.maxReconnects !== undefined && (!Number.isSafeInteger(configuration.maxReconnects) || configuration.maxReconnects < 0)) throw new TypeError('maxReconnects must be a nonnegative integer');
  }
  get position(): EventPosition { return { ...this.#position }; }
  async close(): Promise<void> { this.#stopped = true; this.#controller.abort(); await this.#subscription?.close(); }
  async consume(handler: (event: E) => void | Promise<void>): Promise<void> {
    const iterator = this[Symbol.asyncIterator]();
    try { while (true) { const item = await iterator.next(); if (item.done) break; await handler(item.value); } }
    finally { await iterator.return?.(undefined); }
  }
  async *[Symbol.asyncIterator](): AsyncGenerator<E> {
    if (this.#active) throw new TypeError('A feed has one consumer');
    this.#active = true;
    const signal = this.configuration.signal ? AbortSignal.any([this.#controller.signal, this.configuration.signal]) : this.#controller.signal;
    const options: RequestOptions = { signal };
    const acknowledge = (event: E) => { this.#position = { cursor: event.cursor, sequence: event.sequence }; };
    try {
      for await (const event of this.drain(options)) { yield event; acknowledge(event); }
      let reconnects = 0;
      while (!this.#stopped && this.configuration.subscribe) {
        signal.throwIfAborted();
        let lost = false;
        try {
          this.#subscription = await this.configuration.subscribe(options);
          if (this.#stopped) break;
          for await (const event of this.drain(options)) { yield event; acknowledge(event); }
          for await (const event of this.#subscription) {
            if (this.#stopped) break;
            signal.throwIfAborted();
            if (event.sequence <= this.#position.sequence) continue;
            if (event.sequence > this.#position.sequence + 1) {
              for await (const replayed of this.drain(options)) { yield replayed; acknowledge(replayed); }
              if (event.sequence <= this.#position.sequence) continue;
              if (event.sequence > this.#position.sequence + 1) throw new RealtimeDisconnected('Live event gap requires replay');
            }
            yield event; acknowledge(event);
          }
        } catch (error) {
          if (!(error instanceof RealtimeDisconnected) && !(error instanceof BufferOverflow)) throw error;
          lost = true;
          if (++reconnects > (this.configuration.maxReconnects ?? 8)) throw error;
        } finally { await this.#subscription?.close(); this.#subscription = undefined; }
        if (!lost) break;
        for await (const event of this.drain(options)) { yield event; acknowledge(event); }
      }
    } catch (error) { if (!this.#stopped) throw error; }
    finally { this.#active = false; await this.#subscription?.close(); this.#subscription = undefined; }
  }
  private async *drain(options: RequestOptions): AsyncGenerator<E> {
    let head: number | undefined;
    while (!this.#stopped) {
      const page = await this.configuration.replay(this.#position.cursor ?? undefined, options);
      head ??= page.watermark;
      if (!Number.isSafeInteger(head) || head < 0) throw new MalformedResponse('Invalid event watermark');
      let delivered = false;
      for (const event of page.items) {
        if (event.sequence > head) break;
        if (event.sequence <= this.#position.sequence) continue;
        if (event.sequence !== this.#position.sequence + 1) await this.retentionGap(head);
        delivered = true;
        yield event;
      }
      if (this.#position.sequence >= head) return;
      if (!delivered) await this.retentionGap(head);
    }
  }
  private async retentionGap(head: number): Promise<never> {
    const error = new RetentionGap(head, this.#position.sequence);
    await this.configuration.onRetentionGap?.(error);
    throw error;
  }
}
/** Bounded queue used by realtime adapters. Overflow signals replay, never silent loss. */
export class AsyncQueue<T> implements AsyncIterable<T> {
  #items: T[] = [];
  #waiter: { resolve: (value: IteratorResult<T>) => void; reject: (error: unknown) => void } | undefined;
  #closed = false;
  #error: unknown;
  constructor(private readonly capacity = 256) { if (!Number.isInteger(capacity) || capacity < 1) throw new TypeError('capacity must be positive'); }
  push(item: T) {
    if (this.#closed) return;
    if (this.#waiter) { const waiter = this.#waiter; this.#waiter = undefined; waiter.resolve({ value: item, done: false }); }
    else if (this.#items.length >= this.capacity) this.close(new BufferOverflow('Realtime buffer exceeded capacity'));
    else this.#items.push(item);
  }
  close(error?: unknown) {
    this.#closed = true; this.#error = error;
    if (error !== undefined) this.#items = [];
    if (this.#waiter) { const waiter = this.#waiter; this.#waiter = undefined; error === undefined ? waiter.resolve({ value: undefined, done: true }) : waiter.reject(error); }
  }
  async next(): Promise<IteratorResult<T>> {
    if (this.#error !== undefined) throw this.#error;
    const item = this.#items.shift();
    if (item !== undefined) return { value: item, done: false };
    if (this.#closed) return { value: undefined, done: true };
    if (this.#waiter) throw new TypeError('Queue has one consumer');
    return new Promise((resolve, reject) => { this.#waiter = { resolve, reject }; });
  }
  [Symbol.asyncIterator](): AsyncIterator<T> { return { next: () => this.next(), return: async () => { this.close(); return { value: undefined, done: true }; } }; }
}
export function delay(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) return Promise.reject(new CancelledError('Waiting cancelled'));
  return new Promise((resolve, reject) => {
    const abort = () => { clearTimeout(timer); reject(new CancelledError('Waiting cancelled')); };
    const timer = setTimeout(() => { signal?.removeEventListener('abort', abort); resolve(); }, ms);
    signal?.addEventListener('abort', abort, { once: true });
  });
}
