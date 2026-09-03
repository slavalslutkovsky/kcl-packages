/**
 * JSON <-> `google.protobuf.Struct` in the object form `@grpc/proto-loader`
 * expects. protobufjs only auto-wraps `google.protobuf.Any`, so Structs have to
 * be built and read by hand: every leaf becomes a `Value` with exactly one of
 * the oneof fields set (camelCase, because the loader runs with keepCase:false).
 */

export interface Struct {
  fields: Record<string, Value>;
}

export interface ListValue {
  values: Value[];
}

export interface Value {
  nullValue?: 'NULL_VALUE';
  numberValue?: number;
  stringValue?: string;
  boolValue?: boolean;
  structValue?: Struct;
  listValue?: ListValue;
}

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

export function toValue(value: unknown): Value {
  if (value === null || value === undefined) return { nullValue: 'NULL_VALUE' };
  switch (typeof value) {
    case 'boolean':
      return { boolValue: value };
    case 'number':
      return { numberValue: value };
    case 'bigint':
      return { numberValue: Number(value) };
    case 'string':
      return { stringValue: value };
    default:
      break;
  }
  if (Array.isArray(value)) return { listValue: { values: value.map(toValue) } };
  return { structValue: toStruct(value as Record<string, unknown>) };
}

export function toStruct(obj: Record<string, unknown>): Struct {
  const fields: Record<string, Value> = {};
  for (const [key, value] of Object.entries(obj)) {
    if (value === undefined) continue; // undefined is absence, not null
    fields[key] = toValue(value);
  }
  return { fields };
}

export function fromValue(value: Value | undefined): Json {
  if (!value) return null;
  if (value.stringValue !== undefined) return value.stringValue;
  if (value.boolValue !== undefined) return value.boolValue;
  if (value.numberValue !== undefined) return value.numberValue;
  if (value.structValue !== undefined) return fromStruct(value.structValue);
  if (value.listValue !== undefined) return (value.listValue.values ?? []).map(fromValue);
  return null; // nullValue, or an empty Value
}

export function fromStruct(struct: Struct | undefined): { [key: string]: Json } {
  const out: { [key: string]: Json } = {};
  for (const [key, value] of Object.entries(struct?.fields ?? {})) out[key] = fromValue(value);
  return out;
}
