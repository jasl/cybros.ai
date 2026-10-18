import type { Reader } from '../schemas.js';
const totals = { created_runs: ['integer'], active_answering_agents: ['integer'], conversation_usage: ['shape', 'PlatformUsageCounters'] } satisfies Record<string, Reader>;
export const workSchemas: Record<string, Record<string, Reader>> = {
  AttentionItem: { workspace_public_id: ['string'], run_public_id: ['string'], conversation_public_id: ['nullable_string'], task: ['shape', 'Task'] },
  WorkRunCounts: { pending: ['integer'], running: ['integer'], paused: ['integer'], needs_attention: ['integer'], canceling: ['integer'], completed: ['integer'], canceled: ['integer'] },
  WorkCurrent: { run_counts: ['shape', 'WorkRunCounts'], attention_count: ['integer'] },
  WorkTotals: totals,
  WorkPoint: { ...totals, bucket_start_at: ['string'] },
  WorkPrevious: { from: ['string'], to: ['string'], totals: ['shape', 'WorkTotals'] },
  WorkReport: { from: ['string'], to: ['string'], unit: ['string'], as_of: ['string'], workspace_public_id: ['nullable_string'], agent_public_id: ['nullable_string'], current: ['shape', 'WorkCurrent'], totals: ['shape', 'WorkTotals'], series: ['shapes', 'WorkPoint'], previous: ['shape', 'WorkPrevious'] },
};
