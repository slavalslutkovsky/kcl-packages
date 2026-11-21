// The contract every console remote exposes: `mount(el, props)` renders into
// a host-owned element and returns the function that tears it down. The host
// never imports a component, so remotes and host stay free to pick (and
// upgrade) their own framework.
import { render } from 'solid-js/web';
import { BucketsPage, type PageProps } from './components/BucketsPage';
import { BucketsWidget, type WidgetProps } from './components/BucketsWidget';
import css from './styles.css?inline';

export type Unmount = () => void;

const STYLE_ID = 'console-remote-bucket';

/** The remote ships its own Tailwind build; the host's stylesheet never sees these classes. */
function ensureStyles(): void {
  if (document.getElementById(STYLE_ID)) return;
  const style = document.createElement('style');
  style.id = STYLE_ID;
  style.textContent = css;
  document.head.append(style);
}

export function mountPage(el: HTMLElement, props: PageProps = {}): Unmount {
  ensureStyles();
  return render(() => <BucketsPage {...props} />, el);
}

export function mountWidget(el: HTMLElement, props: WidgetProps = {}): Unmount {
  ensureStyles();
  return render(() => <BucketsWidget {...props} />, el);
}
