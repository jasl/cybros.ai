import { nonempty } from '../json.js';
import { list, page, shape } from '../decode.js';
import type { Shapes } from '../schemas.js';
import type { CallOptions, Receipt, Transport } from '../http.js';
export class Resource {
  constructor(protected readonly transport: Transport, protected readonly path: string) {}
  protected async one<N extends keyof Shapes>(name: N, suffix = '', key?: string, options: CallOptions = {}): Promise<Shapes[N]> {
    return shape(name, (await this.transport.call(this.path + suffix, options)).data, key);
  }
  protected async many<N extends keyof Shapes>(name: N, key: string, options: CallOptions = {}, suffix = '') {
    return list(name, (await this.transport.call(this.path + suffix, options)).data, key);
  }
  protected async paged<N extends keyof Shapes>(name: N, key: string, options: CallOptions = {}, suffix = '') {
    return page(name, (await this.transport.call(this.path + suffix, options)).data, key);
  }
  protected async receipt<N extends keyof Shapes, K extends string>(name: N, key: K, options: CallOptions, suffix = ''): Promise<Receipt<{ [P in K]: Shapes[N] }>> {
    nonempty(options.idempotencyKey ?? '', 'idempotencyKey');
    const result = await this.transport.call(this.path + suffix, options);
    return { status: result.status, replayed: result.replayed, requestId: result.requestId, [key]: shape(name, result.data, key) } as unknown as Receipt<{ [P in K]: Shapes[N] }>;
  }
  protected async empty(suffix = '', options: CallOptions = {}): Promise<void> { await this.transport.call(this.path + suffix, { ...options, allowEmpty: true }); }
}
