// Mirrors rust/crates/kcl-console/src/model.rs (GET /api/buckets).

export type Source = 'k8s' | 'aws' | 'gcp' | 'azure';
export type SourceState = 'ok' | 'unavailable' | 'error';

export interface SourceReport {
  source: Source;
  label: string;
  state: SourceState;
  detail: string | null;
  count: number;
  millis: number;
}

export interface Composite {
  namespace: string;
  name: string;
  ready: boolean | null;
  synced: boolean | null;
  mode: string | null;
  message: string | null;
}

export interface Bucket {
  id: string;
  name: string;
  provider: string;
  region: string | null;
  storageClass: string | null;
  created: string | null;
  url: string | null;
  consoleUrl: string | null;
  seenIn: Source[];
  composite: Composite | null;
}

export interface Inventory {
  sources: SourceReport[];
  buckets: Bucket[];
}

/** Every listing shells out to cloud CLIs; reuse a recent answer across the widget and the page. */
const FRESH_MS = 30_000;
let cache: { key: string; at: number; value: Promise<Inventory> } | undefined;

export function loadInventory(apiBase = '', force = false): Promise<Inventory> {
  const now = Date.now();
  if (!force && cache && cache.key === apiBase && now - cache.at < FRESH_MS) return cache.value;
  const value = fetch(`${apiBase}/api/buckets`).then(async (response) => {
    if (!response.ok) throw new Error(`GET /api/buckets: ${response.status} ${response.statusText}`);
    return (await response.json()) as Inventory;
  });
  cache = { key: apiBase, at: now, value };
  // A failed load must not be served from cache for the next 30 s.
  value.catch(() => {
    if (cache?.value === value) cache = undefined;
  });
  return value;
}

export type Health = 'ready' | 'pending' | 'unmanaged';

/** Unmanaged: a cloud has it, no composite does. Pending: a composite that is not (yet) Ready. */
export function health(bucket: Bucket): Health {
  if (!bucket.composite) return 'unmanaged';
  return bucket.composite.ready ? 'ready' : 'pending';
}

export interface Summary {
  total: number;
  ready: number;
  pending: number;
  unmanaged: number;
  /** Provider → bucket count, largest first. */
  providers: [string, number][];
  failingSources: SourceReport[];
}

export function summarize(inventory: Inventory): Summary {
  const counts = { ready: 0, pending: 0, unmanaged: 0 };
  const providers = new Map<string, number>();
  for (const bucket of inventory.buckets) {
    counts[health(bucket)] += 1;
    providers.set(bucket.provider, (providers.get(bucket.provider) ?? 0) + 1);
  }
  return {
    total: inventory.buckets.length,
    ...counts,
    providers: [...providers].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])),
    failingSources: inventory.sources.filter((s) => s.state !== 'ok'),
  };
}

export interface Filter {
  query: string;
  provider: string;
  health: Health | 'all';
}

export function filterBuckets(buckets: Bucket[], filter: Filter): Bucket[] {
  const query = filter.query.trim().toLowerCase();
  return buckets.filter((bucket) => {
    if (filter.provider !== 'all' && bucket.provider !== filter.provider) return false;
    if (filter.health !== 'all' && health(bucket) !== filter.health) return false;
    if (!query) return true;
    const haystack = [
      bucket.name,
      bucket.region,
      bucket.composite?.namespace,
      bucket.composite?.name,
    ];
    return haystack.some((field) => field?.toLowerCase().includes(query));
  });
}
