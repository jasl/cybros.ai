import { readFileSync } from 'node:fs';
import { expect, test } from 'vitest';
import { Client, Conflict } from '../src/index.js';
import type { CreateConversationLink } from '../src/requests.js';

type Example = { name: string; operation: string; status: number; headers: Record<string, string>; body: Record<string, any> };
const pack = JSON.parse(readFileSync(new URL('../../../contracts/nexus/v1/communication.json', import.meta.url), 'utf8')) as {
  link_request: CreateConversationLink; link_public_id: string; cases: Example[];
};
for (const example of pack.cases) test(`communication: ${example.name}`, async () => {
  const calls: { url: string; init: RequestInit | undefined }[] = [];
  const client = new Client({ baseURL: 'http://nexus.example', credential: 'member', fetch: async (url, init) => {
    calls.push({ url: String(url), init });
    return new Response(JSON.stringify(example.body), { status: example.status, headers: { 'Content-Type': 'application/json', ...example.headers } });
  } });
  const scope = client.workspace('workspace').conversation('conversation');
  const body = example.body;
  switch (example.operation) {
    case 'link_create': {
      const pending = scope.links.create(pack.link_request, { idempotencyKey: 'communication-key' });
      if (example.status === 409) {
        await expect(pending).rejects.toBeInstanceOf(Conflict);
      } else {
        const receipt = await pending;
        expect(receipt.link).toEqual(body.link);
        expect(receipt.replayed).toBe(example.headers['Idempotency-Replayed'] === 'true');
      }
      expect(JSON.parse(String(calls[0]!.init?.body))).toEqual({ link: pack.link_request });
      expect(new Headers(calls[0]!.init?.headers).get('Idempotency-Key')).toBe('communication-key');
      break;
    }
    case 'link_read': expect(await scope.links.fetch(pack.link_public_id)).toEqual(body.link); break;
    case 'link_close': expect(await scope.links.close(pack.link_public_id)).toEqual(body.link); expect(calls[0]!.init?.method).toBe('POST'); break;
    case 'link_list': expect(await scope.links.list({ state: 'all', after: 'previous', limit: 1 })).toEqual({ items: body.links, next_after: body.next_after }); break;
    case 'inputs': expect((await scope.inputs.list()).items).toMatchObject(body.inputs); break;
    case 'turn': expect(await scope.turns.fetch('turn')).toMatchObject(body.turn); break;
    case 'events': {
      const event = (await scope.events()).items[0]!;
      expect(event.type).toBe('input_deleted');
      expect(event.payload).toEqual(body.events[0].payload);
      break;
    }
    case 'task': {
      const detail = await client.workspace('workspace').run('original-run').task('original-task').fetch();
      expect(detail.structured_content).toEqual(body.task.structured_content ?? null);
      expect(detail.task.status).toBe(body.task.status);
      expect(detail.output).toEqual(body.task.output);
      break;
    }
    default: throw new Error(`Unhandled communication case ${example.operation}`);
  }
});
