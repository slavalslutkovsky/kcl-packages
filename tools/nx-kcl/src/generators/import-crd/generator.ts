import { Tree, logger } from '@nx/devkit';
import { execFileSync, execSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { isAbsolute, join } from 'node:path';

export interface ImportCrdGeneratorSchema {
  name: string;
  directory?: string;
  from?: string;
  image?: string;
  repo?: string;
  ref?: string;
  service?: string;
  crdPath?: string;
  apiScope?: 'cluster' | 'namespaced';
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function parseServices(opt?: string): string[] {
  const services = (opt ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  for (const s of services) {
    if (!/^[a-zA-Z0-9_-]+$/.test(s)) {
      throw new Error(`Invalid service filter "${s}".`);
    }
  }
  return services;
}

/** Upjet CRD filenames: `<group>.<cloud>.upbound.io_*` (cluster) and
 * `<group>.<cloud>.m.upbound.io_*` (namespaced v2). */
function matchesScope(file: string, scope: 'cluster' | 'namespaced'): boolean {
  const namespaced = file.includes('.m.upbound.io_');
  return scope === 'namespaced'
    ? namespaced
    : file.includes('.upbound.io_') && !namespaced;
}

function matchesService(file: string, services: string[]): boolean {
  return services.length === 0 || services.some((s) => file.startsWith(`${s}.`));
}

/** Fetch matching CRD YAMLs from a GitHub repo into `destDir`; return paths. */
async function fetchRepoCrds(
  options: ImportCrdGeneratorSchema,
  destDir: string
): Promise<string[]> {
  const { repo } = options;
  const ref = options.ref ?? 'main';
  const crdPath = (options.crdPath ?? 'package/crds').replace(/\/+$/, '');
  const services = parseServices(options.service);
  const scope = options.apiScope ?? 'cluster';
  const headers = { accept: 'application/vnd.github+json', 'user-agent': 'nx-kcl' };

  const treeUrl = `https://api.github.com/repos/${repo}/git/trees/${encodeURIComponent(ref)}?recursive=1`;
  const res = await fetch(treeUrl, { headers });
  if (!res.ok) {
    throw new Error(`GitHub API ${res.status} ${res.statusText} for ${repo}@${ref}`);
  }
  const data: unknown = await res.json();
  if (isObject(data) && data.truncated === true) {
    logger.warn('GitHub tree was truncated; some CRDs may be missing. Narrow with --service.');
  }
  const entries = isObject(data) && Array.isArray(data.tree) ? data.tree : [];

  const prefix = `${crdPath}/`;
  const wanted: string[] = [];
  for (const entry of entries) {
    if (!isObject(entry)) continue;
    const path = asString(entry.path);
    if (!path.startsWith(prefix) || !/\.ya?ml$/i.test(path)) continue;
    const base = path.slice(prefix.length);
    if (base.includes('/')) continue;
    if (matchesService(base, services) && matchesScope(base, scope)) {
      wanted.push(path);
    }
  }
  if (wanted.length === 0) {
    throw new Error(
      `No CRDs matched in ${repo}/${crdPath} (service=${services.join(',') || '*'}, scope=${scope}).`
    );
  }

  logger.info(`Downloading ${wanted.length} CRD(s) from ${repo}@${ref} ...`);
  const files: string[] = [];
  for (const path of wanted) {
    const raw = `https://raw.githubusercontent.com/${repo}/${ref}/${path}`;
    const r = await fetch(raw, { headers: { 'user-agent': 'nx-kcl' } });
    if (!r.ok) {
      logger.warn(`skip ${path}: ${r.status}`);
      continue;
    }
    const dest = join(destDir, path.slice(prefix.length));
    writeFileSync(dest, await r.text());
    files.push(dest);
  }
  return files;
}

/** Extract CRDs from a Crossplane provider OCI image into `destDir` via docker + yq. */
function extractImageCrds(
  options: ImportCrdGeneratorSchema,
  destDir: string
): string[] {
  const image = options.image ?? '';
  if (!/^[a-zA-Z0-9._/:@-]+$/.test(image)) {
    throw new Error(`Invalid image reference "${image}".`);
  }
  // Require an explicit tag/digest — provider images publish versioned tags,
  // not :latest, so a tagless ref would fail with a cryptic docker error.
  const afterSlash = image.slice(image.lastIndexOf('/') + 1);
  if (!afterSlash.includes(':') && !image.includes('@')) {
    throw new Error(
      `--image "${image}" has no tag. Crossplane provider images publish versioned tags (not :latest); pin one, e.g. "${image}:v2.6.0".`
    );
  }
  const services = parseServices(options.service);
  const scope = options.apiScope ?? 'cluster';

  logger.info(`Extracting package.yaml from ${image} ...`);
  const cid = execFileSync('docker', ['create', image], { encoding: 'utf8' }).trim();
  try {
    // docker export streams the container fs; pull just /package.yaml out of it.
    execSync(`docker export ${cid} | tar -xf - -C "${destDir}" package.yaml`, {
      stdio: 'inherit',
    });
  } finally {
    try {
      execFileSync('docker', ['rm', cid], { stdio: 'ignore' });
    } catch {
      /* best effort */
    }
  }

  const pkgYaml = join(destDir, 'package.yaml');
  if (!existsSync(pkgYaml)) {
    throw new Error(`Image ${image} did not contain /package.yaml.`);
  }

  // Filter to CRDs + the requested scope (+ services) and split one file each.
  const scopeExpr =
    scope === 'namespaced'
      ? 'select(.metadata.name | test("\\.m\\.upbound\\.io$"))'
      : 'select(.metadata.name | test("\\.m\\.upbound\\.io$") | not)';
  let select = `select(.kind=="CustomResourceDefinition") | ${scopeExpr}`;
  if (services.length > 0) {
    const svc = services.map((s) => `(.spec.group | test("^${s}\\."))`).join(' or ');
    select += ` | select(${svc})`;
  }
  const crdsDir = join(destDir, 'crds');
  mkdirSync(crdsDir, { recursive: true });
  execSync(
    `yq '${select}' "${pkgYaml}" | yq -s '"${crdsDir}/" + .metadata.name + ".yaml"'`,
    { stdio: 'inherit' }
  );

  return readdirSync(crdsDir)
    .filter((f) => /\.ya?ml$/i.test(f))
    .map((f) => join(crdsDir, f));
}

function localCrds(tree: Tree, from: string, services: string[]): string[] {
  const abs = isAbsolute(from) ? from : join(tree.root, from);
  const stat = statSync(abs);
  if (stat.isFile()) return [abs];
  return readdirSync(abs)
    .filter((f) => /\.ya?ml$/i.test(f) && matchesService(f, services))
    .map((f) => join(abs, f));
}

/**
 * Generate a KCL package from CRDs. The CRDs are converted with
 * `kcl import -m crd`; the package manifest is created by `kcl mod init` and the
 * `k8s` dependency (required by the generated metadata schemas) is added.
 */
export default async function importCrdGenerator(
  tree: Tree,
  options: ImportCrdGeneratorSchema
) {
  const { name } = options;
  const directory = options.directory ?? 'packages';
  const projectRoot = join(directory, name);

  const sources = [options.from, options.image, options.repo].filter(Boolean);
  if (sources.length === 0) {
    throw new Error('Provide one of --image <ref>, --repo <owner/repo>, or --from <dir>.');
  }
  if (sources.length > 1) {
    throw new Error('Use only one of --image, --repo, or --from.');
  }
  if (tree.exists(join(projectRoot, 'kcl.mod'))) {
    throw new Error(`A KCL package already exists at "${projectRoot}".`);
  }

  let provenance = `# Source: ${options.from}`;
  if (options.image) {
    provenance = `# Source: ${options.image} (scope=${options.apiScope ?? 'cluster'}; service=${options.service ?? '*'})`;
  } else if (options.repo) {
    provenance = `# Source: ${options.repo}@${options.ref ?? 'main'} (${options.crdPath ?? 'package/crds'}); service=${options.service ?? '*'}; scope=${options.apiScope ?? 'cluster'}`;
  }

  tree.write(
    join(projectRoot, 'main.k'),
    [
      `# ${name} — KCL schemas generated from CRDs via \`kcl import -m crd\`.`,
      provenance,
      `#`,
      `# Generated models live under ./models. Import what you need, e.g.:`,
      `#   import models.v1beta2.<file> as <alias>`,
      `#`,
      `# Regenerate with the nx-kcl:import-crd generator.`,
      `_generated = "see ./models for schemas"`,
      ``,
    ].join('\n')
  );

  return async () => {
    const pkgAbs = join(tree.root, projectRoot);
    try {
      execFileSync('kcl', ['mod', 'init'], { cwd: pkgAbs, stdio: 'inherit' });
    } catch {
      logger.warn(
        `Wrote sources to ${projectRoot}, but \`kcl mod init\` failed. Run it manually.`
      );
      return;
    }

    let crdFiles: string[] = [];
    let tmp: string | undefined;
    try {
      if (options.image) {
        tmp = mkdtempSync(join(tmpdir(), 'nx-kcl-crd-'));
        crdFiles = extractImageCrds(options, tmp);
      } else if (options.repo) {
        tmp = mkdtempSync(join(tmpdir(), 'nx-kcl-crd-'));
        crdFiles = await fetchRepoCrds(options, tmp);
      } else if (options.from) {
        crdFiles = localCrds(tree, options.from, parseServices(options.service));
      }
    } catch (err) {
      logger.error(
        `CRD source error: ${err instanceof Error ? err.message : String(err)}`
      );
      return;
    }

    if (crdFiles.length === 0) {
      logger.warn('No CRDs to import.');
      return;
    }

    logger.info(`Importing ${crdFiles.length} CRD(s) into ${projectRoot}/models ...`);
    try {
      execFileSync('kcl', ['import', '-m', 'crd', '-f', ...crdFiles], {
        cwd: pkgAbs,
        stdio: 'inherit',
      });
    } catch {
      logger.error('kcl import failed.');
      return;
    }

    // `kcl import` writes a nested models/kcl.mod, which would create a spurious
    // Nx project. Strip it so models/ stays part of this package.
    rmSync(join(pkgAbs, 'models', 'kcl.mod'), { force: true });
    rmSync(join(pkgAbs, 'models', 'kcl.mod.lock'), { force: true });

    // Generated CRD schemas import the `k8s` module (for ObjectMeta).
    try {
      execFileSync('kcl', ['mod', 'add', 'k8s'], { cwd: pkgAbs, stdio: 'inherit' });
    } catch {
      logger.warn(`Could not add the k8s dependency; run \`nx run ${name}:add k8s\`.`);
    }

    if (tmp) rmSync(tmp, { recursive: true, force: true });

    logger.info(`✅ Imported ${crdFiles.length} CRD(s) into ${projectRoot}.`);
    logger.info(`   nx build ${name}`);
  };
}
