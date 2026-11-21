import type { JSX } from 'solid-js';
import type { Bucket, SourceState } from '../inventory';
import { health } from '../inventory';

const PROVIDER_TONE: Record<string, string> = {
  aws: 'bg-orange-100 text-orange-800 dark:bg-orange-950 dark:text-orange-300',
  gcp: 'bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300',
  azure: 'bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-300',
  rustfs: 'bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300',
};

/** Bar/legend colour per provider, same hues as the badges. */
export const PROVIDER_FILL: Record<string, string> = {
  aws: 'bg-orange-500',
  gcp: 'bg-blue-500',
  azure: 'bg-sky-500',
  rustfs: 'bg-rose-500',
};

const pill = 'inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium';

export function ProviderBadge(props: { provider: string }): JSX.Element {
  return (
    <span class={`${pill} ${PROVIDER_TONE[props.provider] ?? 'bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300'}`}>
      {props.provider}
    </span>
  );
}

export function HealthBadge(props: { bucket: Bucket }): JSX.Element {
  const view = () => {
    switch (health(props.bucket)) {
      case 'ready':
        return { label: 'Ready', tone: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300' };
      case 'pending':
        return { label: 'Not ready', tone: 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300' };
      case 'unmanaged':
        return { label: 'Unmanaged', tone: 'bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300' };
    }
  };
  return (
    <span class={`${pill} ${view().tone}`} title={props.bucket.composite?.message ?? undefined}>
      {view().label}
    </span>
  );
}

export const STATE_DOT: Record<SourceState, string> = {
  ok: 'bg-emerald-500',
  unavailable: 'bg-zinc-400',
  error: 'bg-red-500',
};
