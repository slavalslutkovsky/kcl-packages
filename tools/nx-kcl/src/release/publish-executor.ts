import type { ExecutorContext } from '@nx/devkit';
import { execSync } from 'node:child_process';
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { basename, join } from 'node:path';
import { tmpdir } from 'node:os';

export interface KclPublishExecutorOptions {
  /**
   * OCI registry prefix the package is published under, e.g.
   * "oci://docker.io/<namespace>". Environment variables (e.g. $KCL_REGISTRY)
   * are expanded at runtime. Defaults to "oci://$KCL_REGISTRY".
   */
  registry?: string;
  /** Set by `nx release --dry-run`; when true the push is skipped. */
  dryRun?: boolean;
}

/** A local path dependency line: `name = { path = "../rel" }`. */
const PATH_DEP_RE = /^\s*([\w-]+)\s*=\s*\{[^}]*\bpath\s*=\s*"([^"]+)"[^}]*\}/;

function findPathDeps(kclMod: string): { name: string; rel: string }[] {
  const out: { name: string; rel: string }[] = [];
  for (const line of kclMod.split('\n')) {
    const m = line.match(PATH_DEP_RE);
    if (m) out.push({ name: m[1], rel: m[2] });
  }
  return out;
}

/** Registry (non-path) entries inside a kcl.mod `[dependencies]` block. */
function registryDeps(kclMod: string): Record<string, string> {
  const res: Record<string, string> = {};
  let inDeps = false;
  for (const line of kclMod.split('\n')) {
    if (/^\s*\[dependencies\]\s*$/.test(line)) {
      inDeps = true;
      continue;
    }
    if (inDeps && /^\s*\[/.test(line)) break;
    if (inDeps && !PATH_DEP_RE.test(line)) {
      const m = line.match(/^\s*([\w-]+)\s*=\s*(\S.*?)\s*$/);
      if (m) res[m[1]] = m[2];
    }
  }
  return res;
}

/** Drop `drop` deps and union in `add` (existing entries win) in `[dependencies]`. */
function rewriteDeps(
  kclMod: string,
  drop: Set<string>,
  add: Record<string, string>
): string {
  const lines = kclMod.split('\n');
  const out: string[] = [];
  const present = new Set<string>();
  let inDeps = false;
  const flushAdds = () => {
    for (const [k, v] of Object.entries(add)) if (!present.has(k)) out.push(`${k} = ${v}`);
  };
  for (const line of lines) {
    if (/^\s*\[dependencies\]\s*$/.test(line)) {
      inDeps = true;
      out.push(line);
      continue;
    }
    if (inDeps && /^\s*\[/.test(line)) {
      flushAdds();
      inDeps = false;
      out.push(line);
      continue;
    }
    if (inDeps) {
      const m = line.match(/^\s*([\w-]+)\s*=/);
      if (m) {
        if (drop.has(m[1])) continue;
        present.add(m[1]);
      }
    }
    out.push(line);
  }
  if (inDeps) flushAdds();
  return out.join('\n');
}

export default async function kclPublishExecutor(
  options: KclPublishExecutorOptions,
  context: ExecutorContext
) {
  const projectName = context.projectName;
  if (!projectName) {
    throw new Error('The kcl publish executor must be run against a project.');
  }
  const projectRoot = context.projectsConfigurations.projects[projectName].root;
  const absProjectRoot = join(context.root, projectRoot);

  const registry = (options.registry ?? 'oci://$KCL_REGISTRY').replace(
    /\$\{?(\w+)\}?/g,
    (_, name) => {
      const value = process.env[name];
      if (!value) {
        throw new Error(
          `Cannot publish "${projectName}": environment variable $${name} is not set. ` +
            `Set it to your OCI namespace, e.g. KCL_REGISTRY=docker.io/<namespace>.`
        );
      }
      return value;
    }
  );
  const target = `${registry}/${projectName}`;

  const kclMod = readFileSync(join(absProjectRoot, 'kcl.mod'), 'utf-8');
  const pathDeps = findPathDeps(kclMod);

  // `nx release --dry-run` sets both the option and the env var (the latter
  // reaches executors triggered indirectly via dependsOn).
  if (options.dryRun || process.env.NX_DRY_RUN === 'true') {
    const note = pathDeps.length
      ? ` (embedding ${pathDeps.map((d) => d.name).join(', ')})`
      : '';
    console.log(`[dry-run] kcl mod push ${target}  (cwd: ${projectRoot})${note}`);
    return { success: true };
  }

  // No local path deps -> the package is already self-contained; push as-is.
  if (pathDeps.length === 0) {
    console.log(`Publishing ${projectName} to ${target}`);
    execSync(`kcl mod push ${target}`, { cwd: absProjectRoot, stdio: 'inherit' });
    return { success: true };
  }

  // Local path deps (schema packages) don't travel inside an OCI artifact, so a
  // consumer pulling this module would hit `CannotFindModule`. Mirror Upbound's
  // `up project build`: vendor each schema into the artifact as an in-package
  // source dir (`<import_name>/`), drop the path dep, and merge the schema's own
  // registry deps. The repo source keeps the clean path dep (local `kcl run` /
  // `nx build` resolve it); only the published image is self-contained, so
  // schema packages never need to be pushed to a registry.
  const staging = mkdtempSync(join(tmpdir(), 'kcl-pub-'));
  try {
    cpSync(absProjectRoot, staging, { recursive: true });
    const drop = new Set<string>();
    const add: Record<string, string> = {};
    for (const { name, rel } of pathDeps) {
      const depAbs = join(absProjectRoot, rel);
      const importDir = name.replace(/-/g, '_'); // kcl maps `-` -> `_` in imports
      cpSync(depAbs, join(staging, importDir), {
        recursive: true,
        // Skip the dep's manifest so it embeds as plain source, not a nested module.
        filter: (src) => basename(src) !== 'kcl.mod' && basename(src) !== 'kcl.mod.lock',
      });
      drop.add(name);
      const depMod = join(depAbs, 'kcl.mod');
      if (existsSync(depMod)) Object.assign(add, registryDeps(readFileSync(depMod, 'utf-8')));
      console.log(`Embedding schema "${name}" -> ${importDir}/ (vendored, not published)`);
    }
    writeFileSync(join(staging, 'kcl.mod'), rewriteDeps(kclMod, drop, add));
    rmSync(join(staging, 'kcl.mod.lock'), { force: true }); // regenerated on push
    console.log(`Publishing ${projectName} to ${target} (self-contained)`);
    execSync(`kcl mod push ${target}`, { cwd: staging, stdio: 'inherit' });
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
  return { success: true };
}
