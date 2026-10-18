import type { Reader } from '../schemas.js';
import { identitySchemas } from './identity-schemas.js';

const tool = { task_count: ['integer'], status_counts: ['integer_map'], error_result_count: ['integer'], latency: ['shape', 'AnalysisLatency'] } satisfies Record<string, Reader>;
const analysis = { from: ['string'], to: ['string'], as_of: ['string'], cost_unit: ['nullable_string'], model_usage: ['shape', 'ModelUsageAnalysis'] } satisfies Record<string, Reader>;
export const analysisSchemas: Record<string, Record<string, Reader>> = {
  AnalysisCounters: { ...identitySchemas.PlatformUsageCounters, amount_sample_count: ['integer'] },
  AnalysisLatency: { sample_count: ['integer'], missing_count: ['integer'], p50: ['nullable_integer'], p95: ['nullable_integer'] },
  AnalysisGroupTotals: { value: ['string'], totals: ['shape', 'AnalysisCounters'] },
  AnalysisBreakdown: { group_by: ['string'], rank_by: ['string'], limit: ['integer'], total_group_count: ['integer'], groups: ['shapes', 'AnalysisGroupTotals'], other: ['shape', 'AnalysisCounters'] },
  ModelAnalysisLatency: { duration_ms: ['shape', 'AnalysisLatency'], time_to_first_token_ms: ['shape', 'AnalysisLatency'] },
  ModelUsageAnalysis: { totals: ['shape', 'AnalysisCounters'], status_counts: ['integer_map'], latency: ['shape', 'ModelAnalysisLatency'], breakdown: ['shape', 'AnalysisBreakdown'] },
  PlatformUsageAnalysis: analysis,
  ToolAnalysisGroup: { ...tool, tool_name: ['string'] },
  ToolAnalysis: { ...tool, total_group_count: ['integer'], groups: ['shapes', 'ToolAnalysisGroup'], other_task_count: ['integer'] },
  ExecutionAnalysisLatency: { delivery_ms: ['shape', 'AnalysisLatency'], completion_ms: ['shape', 'AnalysisLatency'] },
  ExecutionAnalysis: { run_count: ['integer'], retained_run_count: ['integer'], details_pruned_run_count: ['integer'], status_counts: ['integer_map'], delivered_count: ['integer'], undelivered_count: ['integer'], completed_count: ['integer'], uncompleted_count: ['integer'], latency: ['shape', 'ExecutionAnalysisLatency'], tools: ['shape', 'ToolAnalysis'] },
  WorkAnalysis: { ...analysis, workspace_public_id: ['nullable_string'], agent_public_id: ['nullable_string'], execution: ['shape', 'ExecutionAnalysis'] },
};
