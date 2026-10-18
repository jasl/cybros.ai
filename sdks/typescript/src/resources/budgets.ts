import { Resource } from './base.js';
import { segment } from '../json.js';
import type { RequestOptions } from '../http.js';
import type { ListOptions } from '../requests.js';

export class BudgetReads extends Resource {
  list(query: ListOptions = {}, options: RequestOptions = {}) { return this.one('PlatformBudgetPage', '', undefined, { ...options, query }); }
  fetch(id: string, options: RequestOptions = {}) { return this.one('PlatformBudgetSnapshot', `/${segment(id)}`, undefined, options); }
  entries(id: string, query: ListOptions = {}, options: RequestOptions = {}) { return this.paged('PlatformBudgetLedgerEntry', 'entries', { ...options, query }, `/${segment(id)}/entries`); }
}
