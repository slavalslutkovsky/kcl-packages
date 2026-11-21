// The contract every remote exposes (see apps/console/bucket/src/mount.tsx):
// render into a host-owned element, return the teardown.

export interface MountProps {
  /** Console API origin; empty = same origin, through the host's /api proxy. */
  apiBase?: string;
  /** Host path of the domain's full page (widgets link to it). */
  pageHref?: string;
  /** Client-side navigation inside the host. */
  navigate?: (to: string) => void;
}

export interface RemoteModule {
  mount(el: HTMLElement, props: MountProps): () => void;
}
