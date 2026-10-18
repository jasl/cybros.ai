import { Resource } from './base.js';
import { segment } from '../json.js';
import { MalformedResponse } from '../errors.js';
import { shape } from '../decode.js';
import type { JsonValue } from '../json.js';
import type { MutationOptions, RequestOptions } from '../http.js';
import type { PlatformDeploymentRelease, PlatformDeploymentError, PlatformDeploymentLog } from '../models.js';
export interface DeploymentEvent { event: string; id: string | null; data: JsonValue; log: PlatformDeploymentLog | null; error: PlatformDeploymentError | null; }
export class Deployment extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('PlatformDeploymentState', '', 'deployment', options); }
  checkRelease(input: { tag?: string; backup?: boolean } = {}, options: RequestOptions = {}) { return this.one('PlatformDeploymentState', '/release_check', 'deployment', { timeoutMs: 130_000, ...options, method: 'POST', body: { release_check: input } }); }
  upgrade(input: { candidate: PlatformDeploymentRelease; backup?: boolean }, options: MutationOptions) { return this.receipt('PlatformDeploymentUpgrade', 'upgrade', { ...options, method: 'POST', body: input, success: [202] }, '/upgrades'); }
  operation(id: string) { return new DeploymentOperation(this.transport, `${this.path}/upgrades/${segment(id)}`); }
}
export class DeploymentOperation extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('PlatformDeploymentUpgrade', '', 'upgrade', options); }
  log(cursor?: string, options: RequestOptions = {}) { return this.one('PlatformDeploymentLog', '/log', 'log', { ...options, query: { cursor } }); }
  async *stream(input: { cursor?: string; lastEventId?: string } = {}, options: RequestOptions = {}): AsyncGenerator<DeploymentEvent> {
    const headers = new Headers({ Accept: 'text/event-stream' });
    if (input.lastEventId !== undefined) headers.set('Last-Event-ID', input.lastEventId);
    const download = await this.transport.download(this.path + '/stream', { ...options, headers, query: { cursor: input.cursor } });
    if (!download.body) return;
    const reader = download.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '', event = 'message', id: string | null = null, data: string[] = [];
    try {
      while (true) {
        const chunk = await reader.read();
        buffer += chunk.done ? decoder.decode() : decoder.decode(chunk.value, { stream: true });
        while (true) {
          const match = /\r\n|\r|\n/.exec(buffer);
          if (!match || (match[0] === '\r' && match.index === buffer.length - 1 && !chunk.done)) break;
          const line = buffer.slice(0, match.index); buffer = buffer.slice(match.index + match[0].length);
          if (line === '') {
            if (data.length) {
              let parsed: JsonValue;
              try { parsed = JSON.parse(data.join('\n')) as JsonValue; } catch { throw new MalformedResponse('Invalid deployment SSE JSON'); }
              yield { event, id, data: parsed, log: event === 'deployment.progress.v1' ? shape('PlatformDeploymentLog', parsed) : null, error: event === 'deployment.error.v1' ? shape('PlatformDeploymentError', parsed) : null };
            }
            event = 'message'; data = [];
          } else if (!line.startsWith(':')) {
            const colon = line.indexOf(':'); const field = colon < 0 ? line : line.slice(0, colon); const value = colon < 0 ? '' : line.slice(colon + 1).replace(/^ /, '');
            if (field === 'event') event = value;
            if (field === 'id' && !value.includes('\0')) id = value;
            if (field === 'data') data.push(value);
          }
        }
        if (chunk.done) break;
      }
    } finally { await reader.cancel(); reader.releaseLock(); }
  }
}
