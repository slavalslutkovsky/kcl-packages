import { describe, expect, it } from 'vitest';
import { type Bucket, filterBuckets, type Inventory, summarize } from './inventory';

const bucket = (over: Partial<Bucket>): Bucket => ({
  id: over.name ?? 'b',
  name: 'b',
  provider: 'aws',
  region: null,
  storageClass: null,
  created: null,
  url: null,
  consoleUrl: null,
  seenIn: ['k8s'],
  composite: null,
  ...over,
});

const composite = (ready: boolean | null) => ({
  namespace: 'team-a',
  name: 'xr',
  ready,
  synced: true,
  mode: 'created',
  message: null,
});

const buckets = [
  bucket({ name: 'assets', provider: 'aws', composite: composite(true) }),
  bucket({ name: 'logs', provider: 'gcp', region: 'europe-west1', composite: composite(null) }),
  bucket({ name: 'legacy', provider: 'aws', seenIn: ['aws'] }),
];

describe('summarize', () => {
  it('counts health and ranks providers', () => {
    const inventory: Inventory = {
      buckets,
      sources: [
        { source: 'k8s', label: 'context kind', state: 'ok', detail: null, count: 2, millis: 4 },
        { source: 'azure', label: 'az', state: 'unavailable', detail: 'not on PATH', count: 0, millis: 0 },
      ],
    };

    const summary = summarize(inventory);

    expect(summary).toMatchObject({ total: 3, ready: 1, pending: 1, unmanaged: 1 });
    expect(summary.providers).toEqual([['aws', 2], ['gcp', 1]]);
    expect(summary.failingSources.map((s) => s.source)).toEqual(['azure']);
  });
});

describe('filterBuckets', () => {
  it('combines provider, health and a query over name, region and composite', () => {
    const all = { query: '', provider: 'all', health: 'all' } as const;

    expect(filterBuckets(buckets, { ...all, health: 'unmanaged' }).map((b) => b.name)).toEqual(['legacy']);
    expect(filterBuckets(buckets, { ...all, provider: 'aws', health: 'ready' }).map((b) => b.name)).toEqual(['assets']);
    expect(filterBuckets(buckets, { ...all, query: 'EUROPE' }).map((b) => b.name)).toEqual(['logs']);
    expect(filterBuckets(buckets, { ...all, query: 'team-a' })).toHaveLength(2);
  });
});
