import {
  createRootRoute,
  createRoute,
  createRouter,
  Link,
  Outlet,
  useNavigate,
} from '@tanstack/solid-router';
import { For, type JSX } from 'solid-js';
import { RemoteMount } from './components/RemoteMount';
import { type Domain, domains } from './domains';

const navLink =
  'block rounded-md px-3 py-1.5 text-sm text-zinc-600 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:bg-zinc-900';
const navActive = { class: 'bg-zinc-100 font-medium text-zinc-900 dark:bg-zinc-900 dark:text-zinc-100' };

function Shell(): JSX.Element {
  return (
    <div class="flex min-h-screen text-zinc-900 dark:text-zinc-100">
      <nav class="w-56 shrink-0 border-r border-zinc-200 p-4 dark:border-zinc-800">
        <div class="mb-6 px-3">
          <div class="font-semibold">Console</div>
          <div class="text-xs text-zinc-500">kcl-packages · multi-cloud</div>
        </div>
        <ul class="space-y-1">
          <li>
            <Link to="/" class={navLink} activeProps={navActive} activeOptions={{ exact: true }}>
              Overview
            </Link>
          </li>
          <For each={domains}>
            {(domain) => (
              <li>
                <Link to={domain.path} class={navLink} activeProps={navActive}>
                  {domain.title}
                </Link>
              </li>
            )}
          </For>
        </ul>
      </nav>
      <main class="min-w-0 flex-1">
        <Outlet />
      </main>
    </div>
  );
}

function Overview(): JSX.Element {
  const navigate = useNavigate();
  return (
    <div class="space-y-5 p-6">
      <header>
        <h1 class="text-xl font-semibold">Overview</h1>
        <p class="text-sm text-zinc-500">
          Every domain joins its Crossplane composites with what AWS, GCP, Azure and the cluster report.
        </p>
      </header>
      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <For each={domains}>
          {(domain) => (
            <RemoteMount
              load={domain.widget}
              entry={domain.entry}
              class="h-full"
              mountProps={{ pageHref: domain.path, navigate: (to) => void navigate({ to }) }}
            />
          )}
        </For>
      </div>
    </div>
  );
}

function DomainPage(props: { domain: Domain }): JSX.Element {
  return <RemoteMount load={props.domain.page} entry={props.domain.entry} mountProps={{}} />;
}

function NotFound(): JSX.Element {
  return <p class="p-6 text-sm text-zinc-500">No such page.</p>;
}

const rootRoute = createRootRoute({ component: Shell, notFoundComponent: NotFound });

const overviewRoute = createRoute({ getParentRoute: () => rootRoute, path: '/', component: Overview });

const domainRoutes = domains.map((domain) =>
  createRoute({
    getParentRoute: () => rootRoute,
    path: domain.path,
    component: () => <DomainPage domain={domain} />,
  }),
);

export const router = createRouter({
  routeTree: rootRoute.addChildren([overviewRoute, ...domainRoutes]),
});

declare module '@tanstack/solid-router' {
  interface Register {
    router: typeof router;
  }
}
