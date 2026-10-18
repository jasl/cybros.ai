import { Client, ExecutorClient, PlatformClient, Sessions, ApplicationOAuth, Steps, Unauthorized } from '@cybros/agent';
import { RealtimeClient } from '@cybros/agent/realtime';
import { readFileSync } from 'node:fs';
interface Configuration {
  action: string; base_url: string; credential: string; marker: string; runner_public_id: string;
  workspace_key: string; conversation_key: string; input_key: string;
  workspace_public_id: string; conversation_public_id: string; input_public_id: string;
  run_public_id: string; task_key: string; email: string; password: string; agent_identifier: string;
  position?: { cursor: string | null; sequence: number } | null;
}
const config = JSON.parse(readFileSync(0, 'utf8')) as Configuration;
const emit = (value: object) => process.stdout.write(JSON.stringify(value) + '\n');
const member = () => new Client({ baseURL: config.base_url, credential: config.credential });
const executor = () => new ExecutorClient({ baseURL: config.base_url, credential: config.credential });
const signal = AbortSignal.timeout(60_000);
const pause = () => new Promise(resolve => setTimeout(resolve, 100));
const chat = () => member().workspace(config.workspace_public_id).conversation(config.conversation_public_id);
async function observe() {
  const conversation = chat();
  const execution = conversation.inputExecution(config.input_public_id, config.position ?? undefined);
  const sequences: number[] = [];
  const feed = conversation.feed({ position: config.position ?? { cursor: null, sequence: 0 }, signal });
  await feed.consume(event => { sequences.push(event.sequence); });
  while (true) {
    signal.throwIfAborted(); await execution.refresh({ signal }); const snapshot = await execution.recover({ signal });
    if (snapshot?.terminal && ['completed', 'canceled'].includes(snapshot.run_status ?? '')) return { ...snapshot.execution, status: snapshot.status, run_status: snapshot.run_status, text: snapshot.content, final_text: snapshot.content, content: snapshot.content, position: feed.position, sequences };
    await pause();
  }
}
async function main(): Promise<object> {
  switch (config.action) {
    case 'executor_announce': {
      const description = await executor().announce({ tools: [{ name: 'sdk_echo', description: 'Echo one test marker', input_schema: { type: 'object', properties: { marker: { type: 'string' } }, required: ['marker'] }, effect_profile: { kind: 'read_only', destructive: false, effect_scope: 'closed', idempotency: 'intrinsic', reconciliation: 'none' } }] });
      return { executor_public_id: description.executor.public_id };
    }
    case 'member_prepare': {
      const client = member();
      await client.profile.declareConfiguration({ configuration: { approval_mode: 'bypass', prompt_mechanism: 'default', runner_executor_public_ids: [config.runner_public_id], runner_tool_names: [] } });
      const { workspace } = await client.workspaces.create({ name: config.marker }, { idempotencyKey: config.workspace_key });
      const { conversation } = await client.workspace(workspace.public_id).conversations.create({ title: config.marker, default_runner_executor_public_id: config.runner_public_id }, { idempotencyKey: config.conversation_key });
      const { input } = await client.workspace(workspace.public_id).conversation(conversation.public_id).inputs.create({ kind: 'direct_reply', text: `!mock -- ${config.marker}`, model: { model: 'dev/mock-text' }, approval_mode: 'bypass', steps: [Steps.tool({ name: 'sdk_echo', key: 'sdk_echo', input: { marker: config.marker }, route: { kind: 'runner', runner_executor_public_id: config.runner_public_id } })] }, { idempotencyKey: config.input_key });
      return { workspace_public_id: workspace.public_id, conversation_public_id: conversation.public_id, input_public_id: input.public_id };
    }
    case 'executor_complete': {
      const client = executor(); const inbox = await client.inbox.list();
      if (!inbox.items.some(task => task.run_public_id === config.run_public_id && task.task_key === config.task_key)) throw new Error('Exact inbox task missing');
      const task = client.inboxTask(config.run_public_id, config.task_key);
      const claimed = await task.claim(); await task.claimStatus(claimed.claim_token);
      const upload = await client.uploads.create(new Blob([`capture:${config.marker}`], { type: 'text/plain' }), 'capture.txt');
      await task.commit({ claim_token: claimed.claim_token, content: [{ type: 'text', text: `echo:${config.marker}` }, { type: 'resource_link', uri: `nexus://uploads/${upload.public_id}`, name: 'capture.txt', mimeType: 'text/plain', size: upload.byte_size }], structured_content: { marker: config.marker }, outcome: 'completed', is_error: false });
      return { run_public_id: config.run_public_id, task_key: config.task_key, upload_public_id: upload.public_id };
    }
    case 'member_observe': return observe();
    case 'member_follow': {
      const conversation = chat();
      const execution = conversation.inputExecution(config.input_public_id, config.position ?? undefined);
      const realtime = new RealtimeClient({ baseURL: config.base_url, credential: config.credential });
      const sequences: number[] = [];
      let ready = false;
      const feed = conversation.feed({ signal, position: config.position ?? { cursor: null, sequence: 0 }, subscribe: async options => {
        const sub = await realtime.conversationEvents(config.workspace_public_id, config.conversation_public_id, options);
        if (!ready) { ready = true; emit({ event: 'ready' }); } else emit({ event: 'reconnected' });
        return sub;
      } });
      try {
        await feed.consume(async event => {
          sequences.push(event.sequence); await execution.refresh({ signal }); const snapshot = await execution.recover({ signal });
          if (snapshot?.terminal && ready && ['completed', 'canceled'].includes(snapshot.run_status ?? '')) await feed.close();
        });
        const snapshot = await execution.recover({ signal });
        if (!snapshot?.terminal) throw new Error('Observation ended before original input settled');
        return { ...snapshot.execution, status: snapshot.status, run_status: snapshot.run_status, text: snapshot.content, final_text: snapshot.content, content: snapshot.content, position: feed.position, sequences };
      } finally { await feed.close(); await realtime.close(); }
    }
    case 'member_cancel': {
      const execution = chat().inputExecution(config.input_public_id);
      while (!execution.result) { signal.throwIfAborted(); await execution.refresh({ signal }); if (!execution.result) await pause(); }
      const runId = execution.result.run_public_id; if (!runId) throw new Error('Original input has no Run');
      const run = member().workspace(config.workspace_public_id).run(runId); await run.stop(true, { signal });
      let state = await run.fetch({ signal });
      while (state.status !== 'canceled') { signal.throwIfAborted(); await pause(); state = await run.fetch({ signal }); }
      return { ...execution.result, status: state.status, run_status: state.status };
    }
    case 'platform_smoke': {
      const grant = await new Sessions({ baseURL: config.base_url }).create({ email: config.email, password: config.password });
      const client = new PlatformClient({ baseURL: config.base_url, credential: grant.token });
      const profile = await client.profile.fetch(); const agent = await client.agents.create(config.marker);
      const listed = await client.agents.list(); if (!listed.items.some(row => row.public_id === agent.public_id)) throw new Error('Created Agent missing');
      await client.agents.agent(agent.public_id).remove(); await client.session.revoke();
      return { human_public_id: profile.member.public_id, agent_public_id: agent.public_id, removed: true };
    }
    case 'application_login': {
      const oauth = new ApplicationOAuth({ baseURL: config.base_url });
      const authorization = await oauth.requestDeviceAuthorization({ agent_identifier: config.agent_identifier, agent_display_name: config.marker, executor_display_name: config.marker }, 'login');
      emit({ event: 'authorization', verification_uri_complete: authorization.verification_uri_complete, user_code: authorization.user_code });
      const initial = await oauth.awaitCredentials(authorization, { signal });
      if (!initial.platform_access_token) throw new Error('No platform grant');
      const profile = await new PlatformClient({ baseURL: config.base_url, credential: initial.platform_access_token }).profile.fetch();
      const rotated = await oauth.rotate(initial.refresh_token); if (!rotated.platform_access_token) throw new Error('No refreshed platform grant');
      const client = new PlatformClient({ baseURL: config.base_url, credential: rotated.platform_access_token }); await client.profile.fetch(); await oauth.revoke(rotated.platform_access_token);
      let revoked = false; try { await client.profile.fetch(); } catch (error) { if (!(error instanceof Unauthorized)) throw error; revoked = true; }
      return { human_public_id: profile.member.public_id, agent_public_id: initial.agent_public_id, has_agent_credentials: initial.agent !== null, has_runner_credentials: initial.runner !== null, refresh_rotated: initial.refresh_token !== rotated.refresh_token, revoked };
    }
    default: throw new Error('Unknown E2E driver action');
  }
}
try { emit({ event: 'result', ...await main() }); } catch (error) { process.stderr.write(`${error instanceof Error ? error.name + ': ' + error.message : 'Driver failed'}\n`); process.exitCode = 1; }
