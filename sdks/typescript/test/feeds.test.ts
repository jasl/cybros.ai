import { expect, test } from 'vitest';
import { BufferOverflow, DurableFeed, RealtimeDisconnected, RetentionGap } from '../src/index.js';
import { AsyncQueue } from '../src/feeds.js';
import type { DurableEvent, EventSubscription } from '../src/index.js';
const event = (sequence: number): DurableEvent => ({ public_id: `id-${sequence}`, cursor: `cursor-${sequence}`, sequence });
const position = (sequence: number) => ({ cursor: `cursor-${sequence}`, sequence });
test('replay freezes the first watermark and acknowledges only successful consumption', async () => {
  const afters: (string | undefined)[] = []; let calls = 0;
  const feed = new DurableFeed({ replay: async after => { afters.push(after); return ++calls === 1 ? { items: [event(1)], next_after: 'cursor-1', watermark: 2 } : { items: [event(2), event(3)], next_after: null, watermark: 3 }; } });
  const seen: number[] = []; await feed.consume(row => { expect(feed.position.sequence).toBe(row.sequence - 1); seen.push(row.sequence); });
  expect(seen).toEqual([1, 2]); expect(afters).toEqual([undefined, 'cursor-1']); expect(feed.position).toEqual(position(2));
});
test('handler failure and early iterator return leave the last item unacknowledged', async () => {
  const replay = async () => ({ items: [event(1), event(2)], next_after: null, watermark: 2 });
  const feed = new DurableFeed({ replay });
  await expect(feed.consume(row => { if (row.sequence === 2) throw new Error('persist failed'); })).rejects.toThrow('persist failed');
  expect(feed.position).toEqual(position(1));
  const early = new DurableFeed({ replay }); for await (const row of early) { expect(row.sequence).toBe(1); break; }
  expect(early.position).toEqual({ cursor: null, sequence: 0 });
});
test('retention gaps call recovery without fabricating a consumed cursor', async () => {
  let recovered = 0;
  const feed = new DurableFeed({ position: position(1), replay: async () => ({ items: [event(4)], next_after: null, watermark: 4 }), onRetentionGap: gap => { expect(gap.sequence).toBe(1); recovered++; } });
  await expect(feed.consume(() => {})).rejects.toBeInstanceOf(RetentionGap);
  expect(feed.position).toEqual(position(1)); expect(recovered).toBe(1);
});
test('subscription confirmation closes the replay race and duplicate live events are ignored', async () => {
  let head = 1; const queue = new AsyncQueue<DurableEvent>(); let closed = 0;
  const feed = new DurableFeed({ replay: async after => { const start = after ? Number(after.split('-')[1]) : 0; return { items: Array.from({ length: Math.max(0, head - start) }, (_, index) => event(start + index + 1)), next_after: null, watermark: head }; }, subscribe: async () => { head = 2; queue.push(event(2)); queue.push(event(3)); queue.close(); return { close() { closed++; }, [Symbol.asyncIterator]: () => queue[Symbol.asyncIterator]() }; } });
  const seen: number[] = []; await feed.consume(row => { seen.push(row.sequence); });
  expect(seen).toEqual([1, 2, 3]); expect(feed.position).toEqual(position(3)); expect(closed).toBe(1);
});
test('disconnect and buffer overflow both reconnect through replay with the acknowledged position', async () => {
  for (const failure of [new RealtimeDisconnected('lost'), new BufferOverflow('overflow')]) {
    let head = 0, subscriptions = 0; const replayed: (string | undefined)[] = [];
    const feed = new DurableFeed({ replay: async after => { replayed.push(after); return { items: head === 1 && !after ? [event(1)] : [], next_after: null, watermark: head }; }, subscribe: async (): Promise<EventSubscription<DurableEvent>> => {
      subscriptions++; const index = subscriptions;
      return { close() {}, async *[Symbol.asyncIterator]() { if (index === 1) { head = 1; throw failure; } yield event(2); } };
    } });
    const seen: number[] = []; await feed.consume(row => { seen.push(row.sequence); });
    expect(seen).toEqual([1, 2]); expect(subscriptions).toBe(2); expect(replayed).toContain('cursor-1');
  }
});
test('closing a local feed closes its live subscription and does not request server mutation', async () => {
  const queue = new AsyncQueue<DurableEvent>(); let subscribed!: () => void, closed = 0;
  const ready = new Promise<void>(resolve => { subscribed = resolve; });
  const feed = new DurableFeed({ replay: async () => ({ items: [], next_after: null, watermark: 0 }), subscribe: async () => { subscribed(); return { close() { closed++; queue.close(); }, [Symbol.asyncIterator]: () => queue[Symbol.asyncIterator]() }; } });
  const consuming = feed.consume(() => {}); await ready; await feed.close(); await consuming; expect(closed).toBeGreaterThan(0);
});
test('bounded queues fail loudly instead of silently dropping durable events', async () => {
  const queue = new AsyncQueue<number>(1); queue.push(1); queue.push(2);
  await expect(queue.next()).rejects.toBeInstanceOf(BufferOverflow);
});
