import type { Task } from './execution.js';
import type { PlatformUsageCounters } from './identity.js';

export interface AttentionItem {
  workspace_public_id: string;
  run_public_id: string;
  conversation_public_id: string | null;
  task: Task;
}
export interface WorkRunCounts {
  pending: number;
  running: number;
  paused: number;
  needs_attention: number;
  canceling: number;
  completed: number;
  canceled: number;
}
export interface WorkCurrent { run_counts: WorkRunCounts; attention_count: number; }
export interface WorkTotals {
  created_runs: number;
  active_answering_agents: number;
  conversation_usage: PlatformUsageCounters;
}
export interface WorkPoint extends WorkTotals { bucket_start_at: string; }
export interface WorkPrevious { from: string; to: string; totals: WorkTotals; }
export interface WorkReport {
  from: string;
  to: string;
  unit: string;
  as_of: string;
  workspace_public_id: string | null;
  agent_public_id: string | null;
  current: WorkCurrent;
  totals: WorkTotals;
  series: WorkPoint[];
  previous: WorkPrevious;
}
