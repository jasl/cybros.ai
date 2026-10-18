import { MalformedResponse } from './errors.js';
import { bearer, object } from './json.js';
import { schemas } from './schemas.js';
import type { Reader, Shapes } from './schemas.js';
export function shape<N extends keyof Shapes>(name: N, input: unknown, key?: string): Shapes[N] {
  const raw = key === undefined ? input : object(input)[key];
  const body = name === 'Checkpoint' && typeof raw === 'string' ? { hash: raw } : object(raw, key);
  const fields = schemas[name];
  if (!fields) throw new TypeError(`Unknown schema ${name}`);
  const result: Record<string, unknown> = {};
  for (const [field, reader] of Object.entries(fields)) result[field] = read(body, field, reader, fields);
  if (name === 'Checkpoint') result.raw = raw;
  if (name === 'Credential' && result.plane !== 'member') throw new MalformedResponse('Unexpected member credential plane');
  if (name === 'PlatformProfile' && result.credential_plane !== null && result.credential_plane !== 'platform') throw new MalformedResponse('Unexpected platform credential plane');
  return result as unknown as Shapes[N];
}
export function list<N extends keyof Shapes>(name: N, input: unknown, key: string): Shapes[N][] {
  const values = object(input)[key];
  if (!Array.isArray(values)) throw new MalformedResponse(`Expected ${key} array`);
  return values.map(value => shape(name, value));
}
export interface Page<T> { items: T[]; next_after: string | null; }
export function page<N extends keyof Shapes>(name: N, input: unknown, key: string): Page<Shapes[N]> {
  const pagination = object(object(input).pagination, 'pagination');
  if (!('next_after' in pagination) || (pagination.next_after !== null && typeof pagination.next_after !== 'string')) throw new MalformedResponse('Expected nullable next_after');
  return { items: list(name, input, key), next_after: pagination.next_after as string | null };
}
export async function* pages<T>(fetchPage: (after: string | undefined) => Promise<Page<T>>): AsyncGenerator<Page<T>> {
  let after: string | undefined;
  do { const result = await fetchPage(after); yield result; after = result.next_after ?? undefined; } while (after !== undefined);
}
function read(body: Record<string, unknown>, field: string, reader: Reader, fields: Record<string, Reader>): unknown {
  const op = reader[0]!;
  const nested = ['shape','optional_shape','nullable_shape','shapes','optional_shapes','shape_or_empty','shapes_or_empty','self','map'].includes(op);
  const path = reader.slice(nested ? 2 : 1);
  let value: unknown = body;
  for (const key of path.length ? path : [field]) value = object(value)[key];
  const fail = () => { throw new MalformedResponse(`Expected ${field} ${op}`); };
  if (op === 'self') return shape(reader[1] as keyof Shapes, body);
  if (op === 'present') return reader[1]! in body;
  if (op === 'rest') return Object.fromEntries(Object.entries(body).filter(([key]) => !(key in fields)));
  if (op === 'rendered') return 'entries' in body ? shape('RenderedEstimate', body) : null;
  if (op === 'optional_integer_task_key') return body.task == null ? null : requiredString(object(body.task).key, field);
  if (op === 'bearer') return bearer(value);
  if (op === 'speaker' || op === 'optional_speaker') {
    if (value == null && op === 'optional_speaker') return null;
    return shape(object(value).kind === 'ingress' ? 'ConversationIngressSpeaker' : 'ConversationSpeaker', value);
  }
  if (op === 'active_variant') return value == null ? null : { ...shape('Variant', value), active: true };
  if (op === 'address') return value == null || object(value).role == null ? null : shape('AddressedTo', value);
  if (op === 'shape' || op === 'optional_shape' || op === 'nullable_shape' || op === 'shape_or_empty') {
    if (op === 'nullable_shape' && value === null) return null;
    if (value == null && op === 'optional_shape') return null;
    return shape(reader[1] as keyof Shapes, value ?? (op === 'shape_or_empty' ? {} : value));
  }
  if (op === 'map') return Object.fromEntries(Object.entries(object(value)).map(([key, item]) => [key, shape(reader[1] as keyof Shapes, item)]));
  if (op === 'integer_map') {
    const counts = object(value);
    return Object.values(counts).every(Number.isSafeInteger) ? counts : fail();
  }
  if (op === 'shapes' || op === 'optional_shapes' || op === 'shapes_or_empty') {
    if (value == null && op === 'optional_shapes') return null;
    if (value == null && op === 'shapes_or_empty') return [];
    if (!Array.isArray(value)) return fail();
    return value.map(item => shape(reader[1] as keyof Shapes, item));
  }
  if (op.startsWith('nullable_')) {
    let owner = body;
    for (const key of path.slice(0,-1)) owner = object(owner[key]);
    if (!((path.at(-1) ?? field) in owner)) return fail();
  }
  if (op.startsWith('optional_') || op.startsWith('nullable_')) { if (value == null) return null; }
  const base = op.replace(/^optional_|^nullable_/, '');
  if (base === 'string') return typeof value === 'string' && (op !== 'string' || value.length > 0) ? value : fail();
  if (base === 'integer') return Number.isSafeInteger(value) ? value : fail();
  if (base === 'number') return typeof value === 'number' && Number.isFinite(value) ? value : fail();
  if (base === 'boolean') return typeof value === 'boolean' ? value : fail();
  if (op === 'flag') return value === true;
  if (op === 'count') return value == null ? 0 : Number.isSafeInteger(value) ? value : fail();
  if (op === 'names' && value == null) return [];
  if (base === 'string_list' || op === 'names') return Array.isArray(value) && value.every(x => typeof x === 'string') ? value : fail();
  if (op === 'numbers') return Array.isArray(value) && value.every(x => typeof x === 'number') ? value : fail();
  if (base === 'json_object' || op === 'json_object_or_empty') return object(value ?? (op.endsWith('_or_empty') ? {} : value));
  if (base === 'json_array' || op === 'json_array_or_empty') return value == null && op.endsWith('_or_empty') ? [] : Array.isArray(value) ? value : fail();
  if (base === 'json' || op === 'raw') return value ?? null;
  throw new TypeError(`Unknown reader ${op}`);
}
function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value) throw new MalformedResponse(`Expected ${field} string`);
  return value;
}
