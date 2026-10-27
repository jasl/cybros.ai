import type { Client } from './client.js';
import type { JsonObject } from './json.js';
import type { NestedFunctionTool, ToolAlias } from './requests.js';
import { nonempty } from './json.js';
const groups = {
  orchestration: ['nexus.graph.delegate_task', 'nexus.graph.wait', 'nexus.human.ask'],
  conversation: ['nexus.conversation.spawn', 'nexus.conversation.send', 'nexus.conversation.request', 'nexus.conversation.links', 'nexus.conversation.status', 'nexus.conversation.cancel'],
  history: ['nexus.conversation.search', 'nexus.conversation.read'],
  memory: ['nexus.memory.read', 'nexus.memory.write', 'nexus.memory.edit', 'nexus.memory.ls', 'nexus.memory.grep', 'nexus.memory.delete'],
  discovery: ['nexus.tools.search', 'nexus.tools.call', 'nexus.runners.list', 'nexus.models.list'],
  skills: ['nexus.skill.load'], images: ['nexus.image.generate'], schedules: ['nexus.schedules.read', 'nexus.schedules.manage'],
} as const;
export type ToolsetName = keyof typeof groups;
export const Toolsets = {
  names(...names: ToolsetName[]): string[] { return [...new Set(names.flatMap(name => [...groups[name]]))]; },
  async verify(client: Client, ...names: ToolsetName[]): Promise<string[]> {
    const requested = names.length ? this.names(...names) : this.names(...Object.keys(groups) as ToolsetName[]);
    const catalog = await client.tools.list(); const available = new Set(catalog.map(tool => tool.canonical_name));
    const missing = requested.filter(name => !available.has(name)); if (missing.length) throw new TypeError(`Deployment does not serve: ${missing.join(', ')}`);
    return requested;
  },
};
export interface McpTool { name: string; description?: string; inputSchema?: JsonObject; input_schema?: JsonObject; }
export const ToolLowering = {
  functionEntry(tool: McpTool): NestedFunctionTool {
    const schema = tool.inputSchema ?? tool.input_schema;
    return { type: 'function', function: { name: nonempty(tool.name, 'tool name'), description: tool.description ?? '', parameters: schema && Object.keys(schema).length ? schema : { type: 'object', properties: {} } } };
  },
  functionEntries(tools: McpTool[]): NestedFunctionTool[] { return tools.map(tool => this.functionEntry(tool)).sort((left, right) => left.function.name < right.function.name ? -1 : left.function.name > right.function.name ? 1 : 0); },
};

export function toolAlias(name: string, canonical: string, options: Omit<ToolAlias, 'type' | 'function' | 'canonical'> = {}): ToolAlias { return { type: 'function', function: { name: nonempty(name, 'alias name') }, canonical: nonempty(canonical, 'canonical name'), ...options }; }
