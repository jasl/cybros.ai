import { expect, test } from 'vitest';
import { readFileSync } from 'node:fs';
import { Client, ThreadAccumulator, TimeoutError, TranscriptAccumulator } from '../src/index.js';
import { shape } from '../src/decode.js';
import type { Fetch, RunnerEffects } from '../src/index.js';
const fixture = (family: string, key: string) => JSON.parse(readFileSync(new URL(`../../../contracts/nexus/v1/${family}.json`, import.meta.url), 'utf8'))[key];
test('transcript UTF-8 tail is bounded, counts full bytes, and distinguishes settled replacement', () => {
  const transcript = new TranscriptAccumulator(5);
  transcript.accumulate('A你好B', 'variant'); expect(transcript.text).toBe('好B'); expect(transcript.length).toBe(8);
  expect(transcript.replaceOnSettle('A你好BC')).toBe('C'); expect(transcript.replaced).toBe(false);
  expect(transcript.replaceOnSettle('different')).toBe('different'); expect(transcript.replaced).toBe(true);
  transcript.accumulate('New', 'other'); expect(transcript.text).toBe('New'); expect(transcript.length).toBe(3);
  transcript.reset(); expect(transcript.empty).toBe(true);
});
test('thread live calls retract with a branch and settled snapshots clear their live marks', () => {
  const thread = new ThreadAccumulator();
  const progress = (task_key: string, payload: object) => shape('ProgressFrame', { type: 'step_started', task_key, tool_name: 'read', at: '2026-10-15T00:00:00Z', ...payload });
  thread.stepStarted(progress('r2t0', { status: 'dispatched' })); expect(thread.rows[0]?.task_key).toBe('r2');
  thread.roundStarted(progress('r2', { mainline: false })); expect(thread.rows).toEqual([]);
  expect(thread.stepStarted(progress('r2t1', { status: 'dispatched' }))).toBeNull();
  thread.stepStarted(progress('r3t0', { status: 'running' }));
  thread.settleRound(shape('TranscriptItem', { type: 'round', round: { task_key: 'r3', mainline: true, status: 'completed', calls: { count: 1, items: [{ task_key: 'r3t0', status: 'completed' }] }, branches: [] } }));
  expect(thread.rows[0]?.status).toBe('completed'); expect(thread.live).toEqual([]);
  const snapshot = thread.snapshot; snapshot.rows[0]!.status = 'modified'; expect(thread.rows[0]?.status).toBe('completed');
});
test('checkpoint restoration uses original Runners and deterministic independent request keys', async () => {
  const calls: { path: string; body: any; key: string | null }[] = [];
  const fetcher: Fetch = async (url, options) => {
    const path = new URL(String(url)).pathname, body = typeof options?.body === 'string' ? JSON.parse(options.body) : null;
    calls.push({ path, body, key: new Headers(options?.headers).get('Idempotency-Key') });
    if (path.endsWith('/runs')) return Response.json(fixture('runs', 'valid_request_run_fixture'), { status: 201 });
    if (path.endsWith('/start')) return Response.json(fixture('runs', 'valid_request_run_fixture'));
    if (path.endsWith('/tasks/call_tool')) { const detail = fixture('runs', 'valid_task_detail_fixture'); detail.task.status = 'completed'; detail.task.result = { is_error: false }; detail.task.metadata = { checkpoint: 'undo-hash' }; return Response.json(detail); }
    throw new Error(`Unexpected ${path}`);
  };
  const conversation = new Client({ baseURL: 'http://nexus.example', credential: 'member', fetch: fetcher }).workspace('workspace').conversation('conversation');
  const checkpoint = shape('Checkpoint', 'saved-hash'); expect(checkpoint.raw).toBe('saved-hash');
  const effects: RunnerEffects = { status: 'touched', reason: null, runners: ['runner-a', 'runner-b'].map(runner_executor_public_id => ({ runner_executor_public_id, run_public_id: 'original-run', task_key: 'tool', checkpoint, checkpoint_present: true })) };
  const result = await conversation.restoreCheckpoints(effects, { idempotencyKey: 'operation', restoreGuard: runner => runner === 'runner-b' ? 'refused' : null });
  expect(result.status).toBe('partial'); expect(result.runners.map(row => row.status)).toEqual(['restored', 'failed']);
  const creation = calls.find(row => row.path.endsWith('/runs'))!;
  expect(creation.body.run.steps[0].tool.route.runner_executor_public_id).toBe('runner-a'); expect(creation.body.run.steps[0].tool.input).toEqual({ checkpoint: 'saved-hash' }); expect(creation.key).toHaveLength(64);
  await conversation.restoreCheckpoints(effects, { idempotencyKey: 'operation', restoreGuard: runner => runner === 'runner-b' ? 'refused' : null });
  const keys = calls.filter(row => row.path.endsWith('/runs')).map(row => row.key); expect(keys[0]).toBe(keys[1]);
});
test('tool-result wait timeout is local and never calls stop', async () => {
  const paths: string[] = [];
  const fetcher: Fetch = async url => { paths.push(new URL(String(url)).pathname); const detail = fixture('runs', 'valid_task_detail_fixture'); detail.task.status = 'dispatched'; return Response.json(detail); };
  const run = new Client({ baseURL: 'http://nexus.example', credential: 'member', fetch: fetcher }).workspace('workspace').run('run');
  await expect(run.waitForToolResult({ pollMs: 2, patienceMs: 8 })).rejects.toBeInstanceOf(TimeoutError);
  expect(paths.every(path => path.endsWith('/tasks/call_tool'))).toBe(true);
});
