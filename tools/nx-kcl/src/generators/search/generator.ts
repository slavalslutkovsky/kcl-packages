import { Tree, logger } from '@nx/devkit';

export interface KclSearchGeneratorSchema {
  query?: string;
  limit?: number;
}

interface KclPackage {
  name: string;
  version: string;
  stars: number;
  description: string;
  repoUrl: string;
  publisher: string;
  verified: boolean;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function asNumber(value: unknown): number {
  return typeof value === 'number' ? value : 0;
}

/** Narrow one Artifact Hub search result; returns null for malformed entries. */
function parsePackage(raw: unknown): KclPackage | null {
  if (!isObject(raw)) return null;
  const name = asString(raw.name);
  if (!name) return null;
  const repo = isObject(raw.repository) ? raw.repository : {};
  return {
    name,
    version: asString(raw.version),
    stars: asNumber(raw.stars),
    description: asString(raw.description).replace(/\s+/g, ' ').trim(),
    repoUrl: asString(repo.url),
    publisher:
      asString(repo.organization_name) ||
      asString(repo.user_alias) ||
      asString(repo.display_name),
    verified: repo.verified_publisher === true,
  };
}

/** Packages from the default KCL registry can be added by bare `name`. */
function isDefaultRegistry(pkg: KclPackage): boolean {
  return pkg.publisher === 'kcl' || pkg.repoUrl.includes('kcl-lang/modules');
}

/**
 * List published KCL packages from Artifact Hub (kind=20) so you can discover
 * what to add as a dependency. Writes nothing — discovery only.
 */
export default async function kclSearchGenerator(
  _tree: Tree,
  options: KclSearchGeneratorSchema
) {
  const limit = options.limit && options.limit > 0 ? options.limit : 20;
  const query = options.query?.trim();

  const url = new URL('https://artifacthub.io/api/v1/packages/search');
  url.searchParams.set('kind', '20');
  url.searchParams.set('sort', 'relevance');
  url.searchParams.set('facets', 'false');
  url.searchParams.set('offset', '0');
  url.searchParams.set('limit', String(limit));
  if (query) url.searchParams.set('ts_query_web', query);

  let payload: unknown;
  try {
    const res = await fetch(url, { headers: { accept: 'application/json' } });
    if (!res.ok) {
      logger.error(`Artifact Hub request failed: ${res.status} ${res.statusText}`);
      return;
    }
    payload = await res.json();
  } catch (err) {
    logger.error(
      `Could not reach Artifact Hub (${url.host}). ${
        err instanceof Error ? err.message : 'network error'
      }`
    );
    return;
  }

  const rawList =
    isObject(payload) && Array.isArray(payload.packages) ? payload.packages : [];
  const packages = rawList
    .map((entry: unknown) => parsePackage(entry))
    .filter((p): p is KclPackage => p !== null);

  if (packages.length === 0) {
    logger.info(
      query ? `No KCL packages found for "${query}".` : 'No KCL packages found.'
    );
    return;
  }

  const nameWidth = Math.max(...packages.map((p) => p.name.length));
  const verWidth = Math.max(...packages.map((p) => p.version.length));

  logger.info(
    query
      ? `KCL packages on Artifact Hub matching "${query}":\n`
      : 'KCL packages on Artifact Hub (by relevance):\n'
  );
  for (const pkg of packages) {
    const pub = `${pkg.publisher || 'unknown'}${pkg.verified ? ' ✓' : ''}`;
    logger.info(
      `${pkg.name.padEnd(nameWidth)}  ${pkg.version.padStart(verWidth)}  ★${pkg.stars}  ${pub}`
    );
    if (pkg.description) logger.info(`    ${pkg.description}`);
    if (isDefaultRegistry(pkg)) {
      logger.info(`    → kcl mod add ${pkg.name}:${pkg.version}`);
    } else if (pkg.repoUrl) {
      logger.info(`    → custom registry; see ${pkg.repoUrl}`);
    }
  }
  logger.info(
    `\nAdd to a package: nx run <project>:add <name>:<version>\n` +
      `Scaffold with deps: nx g nx-kcl:package <name> --dependencies=<name>:<version>`
  );
}
