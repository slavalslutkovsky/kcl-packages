import type { RemoteModule } from './remote';

/**
 * One entry per packages/cloud XRD that has a micro frontend. A domain is a
 * remote exposing `./Widget` (overview card) and `./Page` (its route).
 * Adding one: a remote app, its entry in vite.config.ts `remotes`, a
 * `declare module` in remotes.d.ts, and an entry here.
 */
export interface Domain {
  id: string;
  title: string;
  /** Host route of the domain page. */
  path: string;
  /** remoteEntry.js URL, shown when the remote does not load. */
  entry: string;
  widget: () => Promise<RemoteModule>;
  page: () => Promise<RemoteModule>;
}

export const domains: Domain[] = [
  {
    id: 'bucket',
    title: 'Buckets',
    path: '/buckets',
    entry: import.meta.env.VITE_BUCKET_REMOTE,
    widget: () => import('bucket/Widget'),
    page: () => import('bucket/Page'),
  },
];
