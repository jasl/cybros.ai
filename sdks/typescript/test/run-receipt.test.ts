import { expect, test } from 'vitest';
import { readFileSync } from 'node:fs';
import { Client, Steps } from '../src/index.js';
const run = JSON.parse(readFileSync(new URL('../../../contracts/nexus/v1/runs.json', import.meta.url), 'utf8')).valid_request_run_fixture.run;
test('Run creation retains seed receipt and HTTP metadata for fresh and replayed acceptance', async () => {
  for (const replayed of [false, true]) {
    const receipt = { accepted_task_keys: ['question'], steps: [], deliverable_task_key: 'question', revision: 1, resolution_tokens: { question: 'fixture-resolution-token' }, replayed: false };
    const client = new Client({ baseURL: 'http://nexus.example', credential: 'member', fetch: async () => Response.json({ run, receipt, replayed }, { status: replayed ? 200 : 201, headers: { 'X-Request-Id': 'fixture-request' } }) });
    const accepted = await client.workspace('workspace').runs.create({ steps: [Steps.ask({ key: 'question', prompt: 'Count?', indefinite: true })], approval_mode: 'bypass' }, { idempotencyKey: 'fixture-key' });
    expect(accepted.receipt.resolution_tokens.question).toBe('fixture-resolution-token');
    expect(accepted).toMatchObject({ run: { public_id: run.public_id }, receipt, status: replayed ? 200 : 201, replayed, requestId: 'fixture-request' });
  }
});
