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
import { basename, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

export interface KclPublishExecutorOptions {
  /**
   * OCI registry prefix the package is published under, e.g.
   * "oci://docker.io/<namespace>". Environment variables (e.g. $KCL_REGISTRY)
   * are expanded at runtime; $KCL_REGISTRY itself falls back to nx.json's
   * `release.registry` (the same chain version-actions uses to pin
   * composition.yaml), so both steps always target the same registry.
   * Defaults to "oci://$KCL_REGISTRY".
   */
  registry?: string;
  /** Set by `nx release --dry-run`; when true the push is skipped. */
  dryRun?: boolean;
  /**
   * Build the self-contained artifact and compile it, but never push. Backs
   * the `publish-check` target, so CI and the release gate catch an artifact
   * that only compiles from the repo layout before any tag is pushed.
   */
  verifyOnly?: boolean;
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

/**
 * Every local path dependency reachable from `absProjectRoot`, transitively.
 *
 * A vendored dep is plain source inside the artifact, so its own path deps
 * must be vendored next to it: `application` -> `app` -> `chaos-mesh` needs
 * `chaos_mesh/` at the artifact root, or `app/lib.k` fails to resolve its
 * imports once pulled from OCI. Deps are keyed by import name, which is what
 * KCL resolves against; one name bound to two different directories is an
 * error rather than a silent pick.
 */
export function pathDepClosure(absProjectRoot: string): { name: string; abs: string }[] {
  const byName = new Map<string, string>();
  const queue = [absProjectRoot];
  const visited = new Set(queue);
  while (queue.length > 0) {
    const dir = queue.shift()!;
    for (const { name, rel } of findPathDeps(readFileSync(join(dir, 'kcl.mod'), 'utf-8'))) {
      const abs = resolve(dir, rel);
      const bound = byName.get(name);
      if (bound !== undefined) {
        if (bound !== abs) {
          throw new Error(`Path dependency "${name}" resolves to both ${bound} and ${abs}.`);
        }
        continue;
      }
      byName.set(name, abs);
      if (!visited.has(abs)) {
        visited.add(abs);
        queue.push(abs);
      }
    }
  }
  return [...byName].map(([name, abs]) => ({ name, abs }));
}

/**
 * Copy the package into a fresh temp dir shaped exactly like the published
 * artifact. The caller owns (and removes) the returned directory.
 *
 * Local path deps don't travel inside an OCI artifact, so a consumer pulling
 * the module would hit `CannotFindModule`. Mirror Upbound's `up project
 * build`: vendor every dep of the closure as an in-package source dir
 * (`<import_name>/`), drop the path deps, and merge the deps' registry deps
 * (the package's own entries win). The repo source keeps the clean path deps
 * (local `kcl run` / `nx build` resolve them); only the published image is
 * self-contained, so schema packages never need to be pushed to a registry.
 */
export function stageArtifact(absProjectRoot: string): string {
  const staging = mkdtempSync(join(tmpdir(), 'kcl-pub-'));
  try {
    cpSync(absProjectRoot, staging, { recursive: true });
    const closure = pathDepClosure(absProjectRoot);
    if (closure.length === 0) return staging;

    const kclMod = readFileSync(join(absProjectRoot, 'kcl.mod'), 'utf-8');
    const own = registryDeps(kclMod);
    const add: Record<string, string> = {};
    for (const { name, abs } of closure) {
      const importDir = name.replace(/-/g, '_'); // kcl maps `-` -> `_` in imports
      cpSync(abs, join(staging, importDir), {
        recursive: true,
        // Skip the dep's manifest so it embeds as plain source, not a nested module.
        filter: (src) => basename(src) !== 'kcl.mod' && basename(src) !== 'kcl.mod.lock',
      });
      const depMod = join(abs, 'kcl.mod');
      if (!existsSync(depMod)) continue;
      for (const [dep, version] of Object.entries(registryDeps(readFileSync(depMod, 'utf-8')))) {
        if (dep in own) continue;
        if (dep in add && add[dep] !== version) {
          throw new Error(
            `Vendored path deps pin "${dep}" to both ${add[dep]} and ${version}; ` +
              `pin it in ${join(absProjectRoot, 'kcl.mod')} to choose one.`
          );
        }
        add[dep] = version;
      }
      console.log(`Embedding "${name}" -> ${importDir}/ (vendored, not published)`);
    }
    const drop = new Set(findPathDeps(kclMod).map((d) => d.name));
    writeFileSync(join(staging, 'kcl.mod'), rewriteDeps(kclMod, drop, add));
    rmSync(join(staging, 'kcl.mod.lock'), { force: true }); // stale once deps are rewritten
    return staging;
  } catch (e) {
    rmSync(staging, { recursive: true, force: true });
    throw e;
  }
}

/**
 * `kcl run main.k` inside the staged artifact — the same compile function-kcl
 * performs after pulling it. Fails when the artifact only works from the repo
 * layout (e.g. an import that resolves through a path dep nobody vendored).
 */
export function compileArtifact(staging: string, projectName: string): void {
  try {
    execSync('kcl run main.k', {
      cwd: staging,
      stdio: ['ignore', 'ignore', 'pipe'],
      encoding: 'utf-8',
    });
  } catch (e) {
    const err = e as { stderr?: string };
    if (err.stderr) console.error(err.stderr);
    throw new Error(`"${projectName}" does not compile as a published artifact (staged at ${staging}).`);
  }
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

  // Same resolution chain as version-actions' resolveRegistry: the env var
  // (set in CI) wins, nx.json `release.registry` is the in-repo default.
  // Resolved lazily: `verifyOnly` never pushes and needs no registry.
  const resolveTarget = () => {
    const nxRegistry = (
      context.nxJsonConfiguration as { release?: { registry?: string } } | undefined
    )?.release?.registry;
    const registry = (options.registry ?? 'oci://$KCL_REGISTRY').replace(
      /\$\{?(\w+)\}?/g,
      (_, name) => {
        const value =
          process.env[name] ?? (name === 'KCL_REGISTRY' ? nxRegistry : undefined);
        if (!value) {
          throw new Error(
            `Cannot publish "${projectName}": environment variable $${name} is not set ` +
              `and nx.json has no release.registry. Set one of them, e.g. ` +
              `KCL_REGISTRY=docker.io/<namespace>.`
          );
        }
        return value;
      }
    );
    return `${registry}/${projectName}`;
  };

  // `nx release --dry-run` sets both the option and the env var (the latter
  // reaches executors triggered indirectly via dependsOn).
  if (!options.verifyOnly && (options.dryRun || process.env.NX_DRY_RUN === 'true')) {
    const closure = pathDepClosure(absProjectRoot);
    const note = closure.length
      ? ` (embedding ${closure.map((d) => d.name).join(', ')})`
      : '';
    console.log(`[dry-run] kcl mod push ${resolveTarget()}  (cwd: ${projectRoot})${note}`);
    return { success: true };
  }

  const staging = stageArtifact(absProjectRoot);
  try {
    compileArtifact(staging, projectName);
    if (options.verifyOnly) {
      console.log(`${projectName}: published artifact compiles.`);
      return { success: true };
    }
    const target = resolveTarget();
    console.log(`Publishing ${projectName} to ${target} (self-contained)`);
    // `kcl mod push` refuses to overwrite an existing version. For a publish
    // RETRY (some projects landed, some failed) that refusal is the desired
    // end state, not an error — treat it as an idempotent success.
    try {
      execSync(`kcl mod push ${target}`, { cwd: staging, stdio: 'pipe', encoding: 'utf-8' });
    } catch (e) {
      const err = e as { stdout?: string; stderr?: string };
      const output = `${err.stdout ?? ''}${err.stderr ?? ''}`;
      if (output.includes('already exists')) {
        console.log(`Already published: ${target} — skipping.`);
        return { success: true };
      }
      if (output) console.error(output);
      throw e;
    }
    console.log(`pushed [registry] ${target.replace(/^oci:\/\//, '')}`);
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
  return { success: true };
}
