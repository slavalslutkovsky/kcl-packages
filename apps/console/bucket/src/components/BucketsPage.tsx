import { createMemo, createResource, createSignal, For, type JSX, Show } from 'solid-js';
import { type Filter, filterBuckets, type Health, type Inventory, loadInventory, summarize } from '../inventory';
import { HealthBadge, ProviderBadge, STATE_DOT } from './badges';

export interface PageProps {
  /** Origin of the console API; empty means same origin (the host proxies /api). */
  apiBase?: string;
}

export function BucketsPage(props: PageProps): JSX.Element {
  // 0 = first load (may reuse the widget's answer), n > 0 = user asked for fresh data.
  const [reload, setReload] = createSignal(0);
  const [inventory] = createResource(reload, (n) => loadInventory(props.apiBase ?? '', n > 0));
  const [filter, setFilter] = createSignal<Filter>({ query: '', provider: 'all', health: 'all' });
  const patch = (next: Partial<Filter>) => setFilter((f) => ({ ...f, ...next }));

  return (
    <div class="space-y-5 p-6 text-zinc-900 dark:text-zinc-100">
      <header class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-xl font-semibold">Buckets</h1>
          <p class="text-sm text-zinc-500 dark:text-zinc-400">
            Crossplane <code>Bucket</code> composites, joined with what each cloud reports.
          </p>
        </div>
        <button
          type="button"
          class="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          disabled={inventory.loading}
          onClick={() => setReload((n) => n + 1)}
        >
          {inventory.loading ? 'Refreshing…' : 'Refresh'}
        </button>
      </header>

      <Show when={inventory.error}>
        {(error) => (
          <p class="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            Console API unreachable: {String((error() as Error).message ?? error())}. Is <code>just console-api</code>{' '}
            running?
          </p>
        )}
      </Show>

      <Show when={inventory.latest} fallback={<Show when={!inventory.error}><Skeleton /></Show>}>
        {(data) => <Body inventory={data()} filter={filter()} patch={patch} />}
      </Show>
    </div>
  );
}

function Body(props: { inventory: Inventory; filter: Filter; patch: (f: Partial<Filter>) => void }): JSX.Element {
  const summary = createMemo(() => summarize(props.inventory));
  const rows = createMemo(() => filterBuckets(props.inventory.buckets, props.filter));
  const tiles: { health: Health | 'all'; label: string; value: () => number }[] = [
    { health: 'all', label: 'Total', value: () => summary().total },
    { health: 'ready', label: 'Ready', value: () => summary().ready },
    { health: 'pending', label: 'Not ready', value: () => summary().pending },
    { health: 'unmanaged', label: 'Unmanaged', value: () => summary().unmanaged },
  ];

  return (
    <>
      <ul class="flex flex-wrap gap-2">
        <For each={props.inventory.sources}>
          {(source) => (
            <li
              class="flex items-center gap-2 rounded-md border border-zinc-200 px-2.5 py-1 text-xs dark:border-zinc-800"
              title={source.detail ?? source.label}
            >
              <span class={`size-2 rounded-full ${STATE_DOT[source.state]}`} />
              <span class="font-medium">{source.source}</span>
              <span class="text-zinc-500">{source.state === 'ok' ? `${source.count} · ${source.millis} ms` : source.state}</span>
            </li>
          )}
        </For>
      </ul>
      <Show when={summary().failingSources.length > 0}>
        <ul class="space-y-1 text-xs text-zinc-500 dark:text-zinc-400">
          <For each={summary().failingSources}>
            {(source) => (
              <li>
                <span class="font-medium">{source.source}</span> ({source.label}): {source.detail}
              </li>
            )}
          </For>
        </ul>
      </Show>

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <For each={tiles}>
          {(tile) => (
            <button
              type="button"
              onClick={() => props.patch({ health: tile.health })}
              class={`rounded-lg border p-3 text-left transition-colors ${
                props.filter.health === tile.health
                  ? 'border-zinc-900 dark:border-zinc-100'
                  : 'border-zinc-200 hover:border-zinc-400 dark:border-zinc-800 dark:hover:border-zinc-600'
              }`}
            >
              <div class="text-xs text-zinc-500">{tile.label}</div>
              <div class="text-2xl font-semibold tabular-nums">{tile.value()}</div>
            </button>
          )}
        </For>
      </div>

      <div class="flex flex-wrap gap-2">
        <input
          type="search"
          placeholder="Name, region, namespace…"
          value={props.filter.query}
          onInput={(e) => props.patch({ query: e.currentTarget.value })}
          class="min-w-56 flex-1 rounded-md border border-zinc-300 bg-transparent px-3 py-1.5 text-sm dark:border-zinc-700"
        />
        <select
          value={props.filter.provider}
          onChange={(e) => props.patch({ provider: e.currentTarget.value })}
          class="rounded-md border border-zinc-300 bg-transparent px-2 py-1.5 text-sm dark:border-zinc-700"
        >
          <option value="all">All providers</option>
          <For each={summary().providers}>{([provider, n]) => <option value={provider}>{`${provider} (${n})`}</option>}</For>
        </select>
      </div>

      <div class="overflow-x-auto rounded-lg border border-zinc-200 dark:border-zinc-800">
        <table class="w-full text-sm">
          <thead class="bg-zinc-50 text-left text-xs uppercase tracking-wide text-zinc-500 dark:bg-zinc-900">
            <tr>
              <th class="px-3 py-2">Bucket</th>
              <th class="px-3 py-2">Provider</th>
              <th class="px-3 py-2">Region</th>
              <th class="px-3 py-2">Class</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Mode</th>
              <th class="px-3 py-2">Seen in</th>
              <th class="px-3 py-2">Created</th>
              <th class="px-3 py-2" />
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-200 dark:divide-zinc-800">
            <For
              each={rows()}
              fallback={
                <tr>
                  <td colSpan={9} class="px-3 py-8 text-center text-zinc-500">
                    {props.inventory.buckets.length === 0 ? 'No source reported any bucket.' : 'No bucket matches the filter.'}
                  </td>
                </tr>
              }
            >
              {(bucket) => (
                <tr class="align-top">
                  <td class="px-3 py-2">
                    <div class="font-medium">{bucket.name}</div>
                    <Show when={bucket.composite}>
                      {(xr) => (
                        <div class="text-xs text-zinc-500">
                          {xr().namespace}/{xr().name}
                        </div>
                      )}
                    </Show>
                  </td>
                  <td class="px-3 py-2">
                    <ProviderBadge provider={bucket.provider} />
                  </td>
                  <td class="px-3 py-2">{bucket.region ?? '—'}</td>
                  <td class="px-3 py-2">{bucket.storageClass ?? '—'}</td>
                  <td class="px-3 py-2">
                    <HealthBadge bucket={bucket} />
                  </td>
                  <td class="px-3 py-2 text-zinc-500">{bucket.composite?.mode ?? '—'}</td>
                  <td class="px-3 py-2 text-xs text-zinc-500">{bucket.seenIn.join(' · ')}</td>
                  <td class="px-3 py-2 text-zinc-500 tabular-nums">{bucket.created ? bucket.created.slice(0, 10) : '—'}</td>
                  <td class="px-3 py-2 text-right">
                    <Show when={bucket.consoleUrl}>
                      {(href) => (
                        <a href={href()} target="_blank" rel="noreferrer" class="text-xs underline underline-offset-2">
                          Console ↗
                        </a>
                      )}
                    </Show>
                  </td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>
    </>
  );
}

function Skeleton(): JSX.Element {
  return (
    <div class="space-y-3" aria-busy="true">
      <div class="h-6 w-80 animate-pulse rounded bg-zinc-200 dark:bg-zinc-800" />
      <div class="grid grid-cols-4 gap-3">
        <For each={[0, 1, 2, 3]}>{() => <div class="h-16 animate-pulse rounded-lg bg-zinc-200 dark:bg-zinc-800" />}</For>
      </div>
      <div class="h-48 animate-pulse rounded-lg bg-zinc-200 dark:bg-zinc-800" />
    </div>
  );
}
