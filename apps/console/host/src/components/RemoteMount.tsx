import { createSignal, type JSX, onCleanup, onMount, Show } from 'solid-js';
import type { MountProps, RemoteModule } from '../remote';

/**
 * Loads a remote module and mounts it into an element this component owns.
 * A remote that is down or throws shows where it was expected instead of
 * breaking the rest of the host.
 */
export function RemoteMount(props: {
  load: () => Promise<RemoteModule>;
  entry: string;
  mountProps: MountProps;
  class?: string;
}): JSX.Element {
  let el!: HTMLDivElement;
  const [error, setError] = createSignal<string>();
  let dispose: (() => void) | undefined;
  let disposed = false;

  onMount(() => {
    props
      .load()
      .then((remote) => {
        if (!disposed) dispose = remote.mount(el, props.mountProps);
      })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
  });
  onCleanup(() => {
    disposed = true;
    dispose?.();
  });

  return (
    <>
      <Show when={error()}>
        {(message) => (
          <div class="rounded-xl border border-dashed border-red-300 p-5 text-sm dark:border-red-900">
            <p class="font-medium text-red-700 dark:text-red-400">Remote did not load</p>
            <p class="mt-1 text-zinc-500">
              Expected at <code>{props.entry}</code>
            </p>
            <p class="mt-1 text-xs text-zinc-400">{message()}</p>
          </div>
        )}
      </Show>
      <div ref={el} class={props.class} />
    </>
  );
}
