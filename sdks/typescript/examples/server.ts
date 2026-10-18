import { Client, ExecutorClient, PlatformClient, Steps } from '@cybros/agent';
import type { ClientOptions, EventPosition } from '@cybros/agent';

/** The host application owns credentials, stable mutation keys, polling and storage. */
export async function submit(options: ClientOptions, keys: { workspace: string; conversation: string; input: string }, model: string) {
  const client = new Client(options);
  const { workspace } = await client.workspaces.create({ name: 'Example' }, { idempotencyKey: keys.workspace });
  const { conversation } = await client.workspace(workspace.public_id).conversations.create({}, { idempotencyKey: keys.conversation });
  const chat = client.workspace(workspace.public_id).conversation(conversation.public_id);
  const position: EventPosition = { cursor: null, sequence: 0 };
  const accepted = await chat.inputs.create({ kind: 'direct_reply', text: 'Hello', model: { model } }, { idempotencyKey: keys.input });
  const execution = chat.inputExecution(accepted.input.public_id, position);
  await execution.refresh();
  return { accepted, execution, snapshot: await execution.recover() };
}

export async function announce(options: ClientOptions) {
  return new ExecutorClient(options).announce({ tools: [{ name: 'echo', input_schema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] }, effect_profile: { kind: 'read_only', destructive: false, effect_scope: 'closed', idempotency: 'intrinsic', reconciliation: 'none' } }] });
}
export async function settings(options: ClientOptions) { return new PlatformClient(options).profile.fetch(); }
export const askThenModel = [Steps.ask({ prompt: 'Continue?' }), Steps.model({ prompt: 'Summarize the result.' })];
