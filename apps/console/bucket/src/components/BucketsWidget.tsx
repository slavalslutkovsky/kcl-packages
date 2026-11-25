import { createMemo, createResource, For, type JSX, Show } from 'solid-js';
import { loadInventory, summarize } from '../inventory';
import { PROVIDER_FILL } from './badges';

export interface WidgetProps {
  apiBase?: string;
  /** Where the full page lives in the host. */
  pageHref?: string;
  /** Host-side client navigation; a plain link when absent. */
  navigate?: (to: string) => void;
}

/** The card the host's overview shows: totals, provider split, source health. */
export function BucketsWidget(props: WidgetProps): JSX.Element {
  const [inventory] = createResource(() => loadInventory(props.apiBase ?? ''));
  const summary = createMemo(() => (inventory.latest ? summarize(inventory.latest) : undefined));
  const open = (event: MouseEvent) => {
    if (!props.navigate || !props.pageHref) return;
    event.preventDefault();
    props.navigate(props.pageHref);
  };

  return (
    <section class="flex h-full flex-col gap-4 rounded-xl border border-zinc-200 p-5 text-zinc-900 dark:border-zinc-800 dark:text-zinc-100">
      <header class="flex items-center justify-between">
        <h2 class="font-semibold">Buckets</h2>
        <Show when={props.pageHref}>
          {(href) => (
            <a href={href()} onClick={open} class="text-sm text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100">
              Open →
            </a>
          )}
        </Show>
      </header>

      <Show when={inventory.error}>
        <p class="text-sm text-red-600 dark:text-red-400">Console API unreachable.</p>
      </Show>

      <Show
        when={summary()}
        fallback={
          <Show when={!inventory.error}>
            <div class="h-24 animate-pulse rounded-lg bg-zinc-200 dark:bg-zinc-800" />
          </Show>
        }
      >
        {(s) => (
          <>
            <div class="flex items-end gap-6">
              <div>
                <div class="text-3xl font-semibold tabular-nums">{s().total}</div>
                <div class="text-xs text-zinc-500">total</div>
              </div>
              <Stat value={s().ready} label="ready" tone="text-emerald-600 dark:text-emerald-400" />
              <Stat value={s().pending} label="not ready" tone="text-amber-600 dark:text-amber-400" />
              <Stat value={s().unmanaged} label="unmanaged" tone="text-zinc-500" />
            </div>

            <Show when={s().total > 0}>
              <div>
                <div class="flex h-2 overflow-hidden rounded-full bg-zinc-200 dark:bg-zinc-800">
                  <For each={s().providers}>
                    {([provider, n]) => (
                      <div
                        class={PROVIDER_FILL[provider] ?? 'bg-zinc-500'}
                        style={{ width: `${(n / s().total) * 100}%` }}
                        title={`${provider}: ${n}`}
                      />
                    )}
                  </For>
                </div>
                <ul class="mt-2 flex flex-wrap gap-3 text-xs text-zinc-500">
                  <For each={s().providers}>
                    {([provider, n]) => (
                      <li class="flex items-center gap-1">
                        <span class={`size-2 rounded-full ${PROVIDER_FILL[provider] ?? 'bg-zinc-500'}`} />
                        {provider} {n}
                      </li>
                    )}
                  </For>
                </ul>
              </div>
            </Show>

            <Show when={s().failingSources.length > 0}>
              <p class="mt-auto text-xs text-zinc-500" title={s().failingSources.map((f) => `${f.source}: ${f.detail}`).join('\n')}>
                {s().failingSources.length} source{s().failingSources.length === 1 ? '' : 's'} not answering:{' '}
                {s().failingSources.map((f) => f.source).join(', ')}
              </p>
            </Show>
          </>
        )}
      </Show>
    </section>
  );
}

function Stat(props: { value: number; label: string; tone: string }): JSX.Element {
  return (
    <div>
      <div class={`text-lg font-semibold tabular-nums ${props.tone}`}>{props.value}</div>
      <div class="text-xs text-zinc-500">{props.label}</div>
    </div>
  );
}
