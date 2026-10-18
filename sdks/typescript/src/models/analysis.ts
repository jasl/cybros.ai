import type { OpenString } from '../json.js';
import type { PlatformUsageCounters } from './identity.js';

export type AnalysisGroup = OpenString<'provider_id' | 'catalog_model_ref' | 'workload' | 'status'>;
export type AnalysisRank = OpenString<'request_count' | 'total_tokens' | 'cost_amount'>;
export interface AnalysisCounters extends PlatformUsageCounters { amount_sample_count: number; }
export interface AnalysisLatency { sample_count: number; missing_count: number; p50: number | null; p95: number | null; }
export interface AnalysisGroupTotals { value: string; totals: AnalysisCounters; }
export interface AnalysisBreakdown {
  group_by: AnalysisGroup;
  rank_by: AnalysisRank;
  limit: number;
  total_group_count: number;
  groups: AnalysisGroupTotals[];
  other: AnalysisCounters;
}
export interface ModelUsageAnalysis {
  totals: AnalysisCounters;
  status_counts: Record<string, number>;
  latency: { duration_ms: AnalysisLatency; time_to_first_token_ms: AnalysisLatency };
  breakdown: AnalysisBreakdown;
}
export interface PlatformUsageAnalysis {
  from: string;
  to: string;
  as_of: string;
  cost_unit: string | null;
  model_usage: ModelUsageAnalysis;
}
export interface ToolAnalysisGroup {
  tool_name: string;
  task_count: number;
  status_counts: Record<string, number>;
  error_result_count: number;
  latency: AnalysisLatency;
}
export interface ToolAnalysis extends Omit<ToolAnalysisGroup, 'tool_name'> {
  total_group_count: number;
  groups: ToolAnalysisGroup[];
  other_task_count: number;
}
export interface ExecutionAnalysis {
  run_count: number;
  retained_run_count: number;
  details_pruned_run_count: number;
  status_counts: Record<string, number>;
  delivered_count: number;
  undelivered_count: number;
  completed_count: number;
  uncompleted_count: number;
  latency: { delivery_ms: AnalysisLatency; completion_ms: AnalysisLatency };
  tools: ToolAnalysis;
}
export interface WorkAnalysis extends PlatformUsageAnalysis {
  workspace_public_id: string | null;
  agent_public_id: string | null;
  execution: ExecutionAnalysis;
}
