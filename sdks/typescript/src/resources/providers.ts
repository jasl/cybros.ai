import { Resource } from './base.js';
import { segment } from '../json.js';
import type { JsonObject } from '../json.js';
import type { RequestOptions } from '../http.js';
export interface ExpectedVersion { expected_lock_version: number | null; }
export class PlatformModelProviders extends Resource {
  list(options: RequestOptions = {}) { return this.many('ModelProvider', 'model_providers', options); }
  provider(id: string) { return new ModelProviderScope(this.transport, `${this.path}/${segment(id)}`); }
}
export class ModelProviderScope extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('ModelProvider', '', 'model_provider', options); }
  configuration(options: RequestOptions = {}) { return this.one('PlatformModelProviderConfiguration', '', undefined, options); }
  setDefinition(input: ExpectedVersion & { definition: JsonObject }, options: RequestOptions = {}) { return this.writeConfiguration('definition', 'PUT', input, options); }
  resetDefinition(input: ExpectedVersion, options: RequestOptions = {}) { return this.writeConfiguration('definition', 'DELETE', input, options); }
  setModelDefinition(input: ExpectedVersion & { model: string; definition: JsonObject }, options: RequestOptions = {}) { return this.writeConfiguration('model_definition', 'PUT', input, options); }
  removeModelDefinition(input: ExpectedVersion & { model: string }, options: RequestOptions = {}) { return this.writeConfiguration('model_definition', 'DELETE', input, options); }
  resetModelDefinition(input: ExpectedVersion & { model: string }, options: RequestOptions = {}) { return this.writeConfiguration('model_definition/reset', 'POST', input, options); }
  discoverModels(input: ExpectedVersion, options: RequestOptions = {}) { return this.many('PlatformDiscoveredModel', 'models', { ...options, method: 'POST', body: { command: input } }, '/model_discovery'); }
  get authorization() { return new ProviderAuthorization(this.transport, this.path + '/authorization'); }
  setEnabled(input: ExpectedVersion & { enabled: boolean }, options: RequestOptions = {}) { return this.one('ModelProvider', '/lane', 'model_provider', { ...options, method: 'PUT', body: { command: input } }); }
  setModelVisibility(input: ExpectedVersion & { model: string; visible: boolean }, options: RequestOptions = {}) { return this.one('ModelProvider', '/model_visibility', 'model_provider', { ...options, method: 'PUT', body: { command: input } }); }
  setModelAvailability(input: ExpectedVersion & { model: string; available: boolean }, options: RequestOptions = {}) { return this.one('ModelProvider', '/model_availability', 'model_provider', { ...options, method: 'PUT', body: { command: input } }); }
  testModel(input: ExpectedVersion & { model: string }, options: RequestOptions = {}) { return this.one('PlatformModelTestResult', '/model_test', undefined, { ...options, method: 'POST', body: { command: input } }); }
  installApiKey(api_key: string, options: RequestOptions = {}) { return this.one('ModelProvider', '/api_key', 'model_provider', { ...options, method: 'PUT', body: { command: { api_key } } }); }
  removeApiKey(options: RequestOptions = {}) { return this.one('ModelProvider', '/api_key', 'model_provider', { ...options, method: 'DELETE' }); }
  private writeConfiguration(resource: string, method: string, command: object, options: RequestOptions) { return this.one('PlatformModelProviderConfiguration', `/${resource}`, undefined, { ...options, method, body: { command } }); }
}
export class ProviderAuthorization extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('PlatformAuthorization', '', 'authorization', options); }
  start(restart = false, options: RequestOptions = {}) { return this.one('PlatformAuthorizationSession', '', 'authorization_session', { ...options, method: 'POST', body: { command: { restart } }, success: [202] }); }
  clear(options: RequestOptions = {}) { return this.one('PlatformAuthorization', '', 'authorization', { ...options, method: 'DELETE' }); }
  session(id: string, options: RequestOptions = {}) { return this.one('PlatformAuthorizationSession', `/sessions/${segment(id)}`, 'authorization_session', options); }
}
