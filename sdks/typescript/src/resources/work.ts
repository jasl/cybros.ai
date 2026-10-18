import { Resource } from './base.js';
import type { RequestOptions } from '../http.js';
import type { AllRunList, AttentionList, WorkReportQuery, WorkAnalysisQuery } from '../requests.js';

export class WorkQueries extends Resource {
  runs(query: AllRunList = {}, options: RequestOptions = {}) { return this.paged('Run', 'runs', { ...options, query }, '/runs'); }
  attention(query: AttentionList = {}, options: RequestOptions = {}) { return this.paged('AttentionItem', 'items', { ...options, query }, '/attention'); }
  report(query: WorkReportQuery = {}, options: RequestOptions = {}) { return this.one('WorkReport', '/work_report', 'report', { ...options, query }); }
  analysis(query: WorkAnalysisQuery = {}, options: RequestOptions = {}) { return this.one('WorkAnalysis', '/work_analysis', 'analysis', { ...options, query }); }
}
