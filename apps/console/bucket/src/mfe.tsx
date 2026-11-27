// single-spa micro frontend `@shluviza/bucket`, loaded by the shluviza-wrokspace
// console host (apps/console-host) through its mfe-registry. The application
// renders BucketsPage at the host route; `widget` is a parcel the host's
// overview mounts. Both render into the host-owned `domElement`.
import type { JSX } from 'solid-js';
import { render } from 'solid-js/web';
import { BucketsPage } from './components/BucketsPage';
import { BucketsWidget } from './components/BucketsWidget';
import css from './styles.css?inline';

export interface AppProps {
  name: string;
  domElement: HTMLElement;
  apiBase: string;
  basePath: string;
  navigate(to: string): void;
  /** console-host: installs the CSS scoped to this module's containers and returns its remover. */
  addStyles?(css: string): () => void;
}

export type WidgetProps = Omit<AppProps, 'name'>;

const STYLE_ID = 'mfe-style-@shluviza/bucket';

/** Without a host that scopes styles: one global <style>, kept while page or widget is mounted. */
let globalUsers = 0;

function addGlobalStyles(text: string): () => void {
  globalUsers += 1;
  if (!document.getElementById(STYLE_ID)) {
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = text;
    document.head.append(style);
  }
  return () => {
    globalUsers = Math.max(0, globalUsers - 1);
    if (globalUsers === 0) document.getElementById(STYLE_ID)?.remove();
  };
}

const disposers = new WeakMap<HTMLElement, () => void>();

function mountInto(props: WidgetProps, view: () => JSX.Element): void {
  const removeStyles = props.addStyles ? props.addStyles(css) : addGlobalStyles(css);
  const dispose = render(view, props.domElement);
  disposers.set(props.domElement, () => {
    dispose();
    removeStyles();
  });
}

function unmountFrom(el: HTMLElement): void {
  const dispose = disposers.get(el);
  if (!dispose) return;
  disposers.delete(el);
  dispose();
}

export async function bootstrap(_props: AppProps): Promise<void> {}

export async function mount(props: AppProps): Promise<void> {
  mountInto(props, () => <BucketsPage apiBase={props.apiBase} />);
}

export async function unmount(props: AppProps): Promise<void> {
  unmountFrom(props.domElement);
}

export const widget = {
  async bootstrap(_props: WidgetProps): Promise<void> {},
  async mount(props: WidgetProps): Promise<void> {
    mountInto(props, () => (
      <BucketsWidget apiBase={props.apiBase} pageHref={props.basePath} navigate={props.navigate} />
    ));
  },
  async unmount(props: WidgetProps): Promise<void> {
    unmountFrom(props.domElement);
  },
};
