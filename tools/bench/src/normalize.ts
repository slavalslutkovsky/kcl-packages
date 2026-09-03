/**
 * Canonicalisation and diffing of function responses.
 *
 * "Same Composition, three runtimes" is only a meaningful claim if the desired
 * state they produce is compared, not just their latency. Keys are sorted so a
 * map-iteration-order difference never shows up as a behavioural one; anything
 * that survives that is a real difference in composed resources.
 */
import { fromStruct } from './struct.ts';
import type { Json } from './struct.ts';
import type { Result, RunFunctionResponse } from './client.ts';

export interface Canonical {
  /** Desired composed resources by composition-resource-name, keys sorted. */
  resources: Record<string, Json>;
  /** Desired composite status — the only part of the XR a function may set. */
  compositeStatus: Json;
  /** Readiness each runtime claims per composed resource. */
  ready: Record<string, string>;
  results: Result[];
}

function sortedKeysDeep(value: Json): Json {
  if (Array.isArray(value)) return value.map(sortedKeysDeep);
  if (value && typeof value === 'object') {
    const out: { [key: string]: Json } = {};
    for (const key of Object.keys(value).sort()) out[key] = sortedKeysDeep(value[key]);
    return out;
  }
  return value;
}

export function canonical(response: RunFunctionResponse): Canonical {
  const resources: Record<string, Json> = {};
  const ready: Record<string, string> = {};
  for (const name of Object.keys(response.desired?.resources ?? {}).sort()) {
    const entry = response.desired!.resources![name];
    resources[name] = sortedKeysDeep(fromStruct(entry.resource));
    ready[name] = entry.ready ?? 'READY_UNSPECIFIED';
  }
  const composite = fromStruct(response.desired?.composite?.resource);
  return {
    resources,
    compositeStatus: sortedKeysDeep((composite.status ?? null) as Json),
    ready,
    results: response.results ?? [],
  };
}

/**
 * Drop the empty metadata bookkeeping maps runtimes disagree about.
 *
 * function-kcl consumes `krm.kcl.dev/composition-resource-name` and leaves
 * `metadata.annotations: {}` behind; kclx removes the emptied map on purpose
 * (`rust/crates/kcl-render/src/compose.rs`, `take_annotation`). Kubernetes
 * treats an empty map and an absent one identically, so this is the one
 * difference the benchmark reports as equivalent rather than divergent — and it
 * is applied only to a *second* comparison, never to the primary diff.
 */
export function stripEmptyMetadata(value: Json): Json {
  if (Array.isArray(value)) return value.map(stripEmptyMetadata);
  if (!value || typeof value !== 'object') return value;
  const out: { [key: string]: Json } = {};
  for (const [key, child] of Object.entries(value)) {
    if (key === 'metadata' && child && typeof child === 'object' && !Array.isArray(child)) {
      const metadata: { [k: string]: Json } = {};
      for (const [field, entry] of Object.entries(child)) {
        const empty =
          (field === 'annotations' || field === 'labels') &&
          entry !== null &&
          typeof entry === 'object' &&
          !Array.isArray(entry) &&
          Object.keys(entry).length === 0;
        if (!empty) metadata[field] = stripEmptyMetadata(entry);
      }
      if (Object.keys(metadata).length) out[key] = metadata;
      continue;
    }
    out[key] = stripEmptyMetadata(child);
  }
  return out;
}

export interface Diff {
  /** Number of differing lines (added + removed). */
  lines: number;
  text: string;
}

/**
 * Unified-ish line diff of two pretty-printed JSON values. A dependency-free
 * LCS is enough: the inputs are a few hundred sorted lines and only ever
 * differ in a handful of them.
 */
export function diffText(reference: unknown, candidate: unknown): Diff {
  const a = JSON.stringify(reference, null, 2).split('\n');
  const b = JSON.stringify(candidate, null, 2).split('\n');

  // lcs[i][j] = length of the longest common subsequence of a[i:] and b[j:].
  const lcs: number[][] = Array.from({ length: a.length + 1 }, () =>
    new Array<number>(b.length + 1).fill(0)
  );
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }

  const out: string[] = [];
  let changed = 0;
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      out.push(`  ${a[i]}`);
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.push(`- ${a[i++]}`);
      changed++;
    } else {
      out.push(`+ ${b[j++]}`);
      changed++;
    }
  }
  while (i < a.length) {
    out.push(`- ${a[i++]}`);
    changed++;
  }
  while (j < b.length) {
    out.push(`+ ${b[j++]}`);
    changed++;
  }

  // Only the changed lines and a little surrounding context are useful.
  const keep = new Set<number>();
  out.forEach((line, idx) => {
    if (line.startsWith('  ')) return;
    for (let k = Math.max(0, idx - 3); k <= Math.min(out.length - 1, idx + 3); k++) keep.add(k);
  });
  const hunks: string[] = [];
  let previous = -2;
  for (const idx of [...keep].sort((x, y) => x - y)) {
    if (idx !== previous + 1 && hunks.length) hunks.push('  @@');
    hunks.push(out[idx]);
    previous = idx;
  }
  return { lines: changed, text: hunks.join('\n') };
}
