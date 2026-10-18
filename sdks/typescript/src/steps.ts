import type { JsonObject } from './json.js';
import type { McpToolImport, ModelSelection, ModelSelectionIntent, ToolDefinition, Workload } from './requests.js';
export type OnFailure = 'absorb' | 'propagate' | 'halt';
export type StepVisibility = 'visible' | 'collapsed' | 'hidden';
export type FanOnFailure = 'absorb' | 'propagate';
export interface StepOptions {
  key?: string; detached?: boolean; lifetime?: 'turn' | 'conversation';
  wake?: 'auto' | 'passive'; on_failure?: OnFailure; visibility?: StepVisibility; after?: string[];
}
export type ToolStepRoute = { kind: 'runner'; runner_executor_public_id?: string } | { kind: 'mcp'; connection_public_id: string };
export interface ToolStepInput extends StepOptions { name: string; input?: JsonObject; timeout_ms?: number; model_defaults?: ModelDefaults; route?: ToolStepRoute; }
export interface ModelStepInput extends StepOptions {
  prompt: string; model?: string | ModelSelection; workload?: Workload; tools?: ToolDefinition[]; instructions?: string;
  configuration?: JsonObject; compaction?: JsonObject; fan_on_failure?: FanOnFailure; results?: string[];
  attachments?: string[]; kernel_tools?: string[]; runner_executor_public_ids?: string[];
  runner_tool_names?: string[]; mcp_tools?: McpToolImport[]; model_selection?: ModelSelectionIntent; fallback_models?: string[];
}
export type ModelDefaults = Pick<ModelStepInput, 'model' | 'workload' | 'configuration' | 'tools' | 'instructions' | 'compaction' | 'on_failure' | 'fan_on_failure' | 'kernel_tools' | 'runner_executor_public_ids' | 'runner_tool_names' | 'mcp_tools' | 'model_selection' | 'fallback_models'>;
export interface AskStepInput extends StepOptions { prompt: string; options?: string[]; multi?: boolean; timeout_ms?: number; }
export interface WaitStepInput extends StepOptions { task: string; run_public_id?: string; timeout_ms?: number; }
export interface ParallelStep { parallel: Step[]; until?: 'all' | 'any' | number; losers?: 'cancel' | 'run_out'; key?: string; on_failure?: OnFailure; lifetime?: 'turn' | 'conversation'; wake?: 'auto' | 'passive'; }
export type Step = { tool: ToolStepInput } | { model: ModelStepInput } | { ask: AskStepInput } | { wait: WaitStepInput } | ParallelStep | Step[];
export const Steps = {
  tool(input: ToolStepInput): Step { return { tool: input }; },
  model(input: ModelStepInput): Step { return { model: input }; },
  ask(input: AskStepInput): Step { return { ask: input }; },
  wait(input: WaitStepInput): Step { return { wait: input }; },
  parallel(members: Step[], options: Omit<ParallelStep, 'parallel'> = {}): Step { return { parallel: members, ...options }; },
};
