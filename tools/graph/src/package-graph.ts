/**
 * The KCL package graph: every kcl.mod in this repo and in the repos checked out
 * beside it, what each package depends on, and who uses it. What gitops'
 * scripts/flow.sh is for the Flux bring-up DAG, this is for packages: a page to
 * look at, a CI gate, and the order to act in.
 *
 *   node tools/graph/src/package-graph.ts                write docs/packages/index.html
 *   node tools/graph/src/package-graph.ts serve [port]   serve that page on 127.0.0.1 (default 4560),
 *                                                        rescanning on every load: reload = current
 *   node tools/graph/src/package-graph.ts check          print findings; exit 1 on any error
 *   node tools/graph/src/package-graph.ts impact <pkg>   bump/publish order downstream of <pkg>,
 *                                                        and the files that consume it
 *   node tools/graph/src/package-graph.ts cypher [file]  a Neo4j load script (stdout without file)
 *
 *   --repo <name>=<dir>   scan these repos (repeatable) instead of the auto-detected ones
 *   --json                check and impact: machine-readable output
 *
 * Repos: this one, plus the siblings in SIBLINGS that exist next to it, plus the
 * superproject when it is the shluviza workspace (vendor/<repo> submodules). Only
 * tracked files are read (`git ls-files`), so the result is what is committed.
 *
 * Edges, from a package's kcl.mod:
 *   path       `{ path = "../x" }`, resolved to the package in that directory
 *   oci        `{ oci = "oci://<registry>/<name>", tag }`: an own package when the
 *              registry is one of REGISTRIES, else an external module
 *   registry   `name = "1.2.3"`: the KCL registry, ghcr.io/kcl-lang/<name>
 *   git        `{ git = …, tag }`: external
 *
 * Usage, from every other tracked text file:
 *   - an OCI reference to an own package (`<registry>/<name>`, optional `:tag` or
 *     `?tag=`), in any scanned repo
 *   - a package's path (`packages/app`, `kcl-packages/packages/app/main.k`) in its
 *     own repo, or prefixed with the repo's name from another one
 * classified by the file: docs (markdown, docs/, catalog/, backstage/), tooling
 * (CI, justfile, Taskfile, project.json, devkit.toml…), manifest (other YAML),
 * code (everything else). References inside the package's own directory do not
 * count. Tier: `used` when another package depends on it or a non-docs file
 * references it, `docs-only`, else `unused` - "nothing points at it", which a
 * package run only as `kcl run .` or pasted inline is too.
 *
 * Findings (errors fail `check`):
 *   error  missing-path   a path dependency with no kcl.mod at its target
 *   error  cycle          a dependency cycle among own packages
 *   error  pin-behind     an oci/registry pin on an own package older than its source version
 *   error  pin-ahead      … newer than its source version: never published
 *   error  diverged-copy  one package name in several directories with different .k files
 *   warn   duplicate      … with identical .k files
 *   warn   name-mismatch  a dependency key that is not the target's package name
 *   warn   stale-ref      a non-docs file pins an own package at a tag other than its version
 */
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { basename, dirname, posix, relative, resolve } from "node:path";
import { parse as parseToml } from "smol-toml";

const root = resolve(import.meta.dirname, "../../..");
const SELF = "kcl-packages";
const templatePath = resolve(import.meta.dirname, "package-graph.html");
const outPath = resolve(root, "docs/packages/index.html");

/** Repos looked for next to this one. */
const SIBLINGS = ["platform-api", "gitops", "toolkit", "infra"];

/**
 * Registry → the repo that publishes there. nx.json `registry` for this repo;
 * platform-api's scripts/publish.sh default KCL_REGISTRY.
 */
const REGISTRIES: Record<string, string> = {
  "docker.io/yurikrupnik": SELF,
  "me-west1-docker.pkg.dev/shl-artifacts/platform": "platform-api",
};
const KCL_REGISTRY = "ghcr.io/kcl-lang";

const SKIP_SEGMENTS = new Set(["node_modules", "fixtures", "testdata", ".kcl", "target", "dist"]);
const TEXT_EXT = /\.(ya?ml|toml|json|jsonc|k|rs|ts|tsx|js|mjs|cjs|nu|sh|bash|py|go|md|mdx|txt|cue|tpl)$/;
const TEXT_NAMES = new Set(["justfile", "Justfile", "Taskfile", "Makefile", "Dockerfile", "Tiltfile"]);
const MAX_FILE_BYTES = 1 << 20;

// ------------------------------------------------------------------ types ---

interface Repo {
  name: string;
  dir: string;
}

type DepKind = "path" | "oci" | "registry" | "git";
type RefKind = "docs" | "tooling" | "manifest" | "code";
type Tier = "used" | "docs-only" | "unused";
type Severity = "error" | "warn";

interface Pkg {
  id: string;
  kind: "package";
  name: string;
  version: string;
  repo: string;
  path: string;
  generated: boolean;
  files: number;
  hash: string;
  level: number;
  tier: Tier;
}

interface External {
  id: string;
  kind: "external";
  name: string;
  level: number;
}

type GraphNode = Pkg | External;

/** `from` depends on `to`. */
interface Edge {
  from: string;
  to: string;
  kind: DepKind;
  key: string;
  pin: string | null;
}

interface Ref {
  pkg: string;
  repo: string;
  path: string;
  line: number;
  kind: RefKind;
  tag: string | null;
}

interface Finding {
  severity: Severity;
  code: string;
  message: string;
  ids: string[];
}

interface Graph {
  repos: { name: string; packages: number }[];
  registries: Record<string, string>;
  nodes: GraphNode[];
  edges: Edge[];
  refs: Ref[];
  findings: Finding[];
}

// ------------------------------------------------------------------- args ---

interface Args {
  command: "page" | "check" | "impact" | "cypher" | "serve";
  target: string | null;
  json: boolean;
  repos: Repo[];
}

function parseArgs(argv: string[]): Args {
  const positional: string[] = [];
  const explicit: Repo[] = [];
  let json = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--json") json = true;
    else if (a === "--repo" || a.startsWith("--repo=")) {
      const v = a === "--repo" ? argv[++i] : a.slice("--repo=".length);
      const eq = v?.indexOf("=") ?? -1;
      if (!v || eq < 1) throw new Error(`--repo wants <name>=<dir>, got ${v}`);
      explicit.push({ name: v.slice(0, eq), dir: resolve(v.slice(eq + 1)) });
    } else if (a.startsWith("-")) throw new Error(`unknown flag ${a}`);
    else positional.push(a);
  }
  const command = (positional[0] ?? "page") as Args["command"];
  if (!["page", "check", "impact", "cypher", "serve"].includes(command)) throw new Error(`unknown command ${command}`);
  if (command === "serve" && positional[1] && !/^\d+$/.test(positional[1])) throw new Error(`serve wants a port, got ${positional[1]}`);
  if (command === "impact" && !positional[1]) throw new Error("impact wants a package: name, <repo>:<path> or a path");
  return { command, target: positional[1] ?? null, json, repos: explicit.length ? [{ name: SELF, dir: root }, ...explicit] : detectRepos() };
}

function detectRepos(): Repo[] {
  const repos: Repo[] = [{ name: SELF, dir: root }];
  for (const name of SIBLINGS) {
    const dir = resolve(root, "..", name);
    if (existsSync(resolve(dir, ".git"))) repos.push({ name, dir });
  }
  const workspace = resolve(root, "../..");
  const gitmodules = resolve(workspace, ".gitmodules");
  if (existsSync(gitmodules) && readFileSync(gitmodules, "utf8").includes(`vendor/${SELF}`)) {
    repos.push({ name: basename(workspace), dir: workspace });
  }
  return repos;
}

// ------------------------------------------------------------------- scan ---

interface RepoFiles {
  repo: Repo;
  files: string[];
}

function trackedFiles(repo: Repo): RepoFiles {
  const out = execFileSync("git", ["-C", repo.dir, "ls-files", "-z"], { encoding: "utf8", maxBuffer: 1 << 28 });
  const files = out
    .split("\0")
    .filter((f) => f && !f.split("/").some((s) => SKIP_SEGMENTS.has(s)))
    .filter((f) => {
      try {
        return statSync(resolve(repo.dir, f)).isFile();
      } catch {
        return false; // submodule gitlink or deleted in the worktree
      }
    })
    .sort();
  return { repo, files };
}

function compareVersions(a: string, b: string): number {
  const pa = a.replace(/^v/, "").split(/[.+-]/).map((x) => Number.parseInt(x, 10));
  const pb = b.replace(/^v/, "").split(/[.+-]/).map((x) => Number.parseInt(x, 10));
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = Number.isNaN(pa[i] ?? 0) ? 0 : (pa[i] ?? 0);
    const y = Number.isNaN(pb[i] ?? 0) ? 0 : (pb[i] ?? 0);
    if (x !== y) return x - y;
  }
  return 0;
}

function refKind(path: string): RefKind {
  const b = posix.basename(path);
  if (/\.(md|mdx|txt|html)$/.test(b) || /(^|\/)(docs|catalog|backstage)\//.test(path)) return "docs";
  if (
    /^\.(github|tekton|gitlab|forgejo)\//.test(path) ||
    /^(justfile|Justfile|Makefile|Tiltfile|project\.json|package\.json|mise\.toml|devkit\.toml|dev\.toml|nx\.json)$/.test(b) ||
    /^(Taskfile|lefthook)/.test(b) ||
    path.startsWith("tasks/")
  )
    return "tooling";
  if (/\.ya?ml$/.test(b)) return "manifest";
  return "code";
}

const escapeRe = (s: string): string => s.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");

function build(repos: Repo[]): Graph {
  const scanned = repos.map(trackedFiles);
  const abs = (repo: Repo, p: string): string => resolve(repo.dir, p);

  // Packages: every kcl.mod, keyed by absolute directory.
  const pkgs: Pkg[] = [];
  const byDir = new Map<string, Pkg>();
  const mods = new Map<string, Record<string, unknown>>();
  for (const { repo, files } of scanned) {
    for (const f of files) {
      if (basename(f) !== "kcl.mod") continue;
      const mod = parseToml(readFileSync(abs(repo, f), "utf8")) as Record<string, unknown>;
      const pkgPath = posix.dirname(f);
      const meta = (mod.package ?? {}) as Record<string, string>;
      const p: Pkg = {
        id: `${repo.name}:${pkgPath}`,
        kind: "package",
        name: meta.name ?? posix.basename(pkgPath),
        version: meta.version ?? "0.0.0",
        repo: repo.name,
        path: pkgPath,
        generated: false,
        files: 0,
        hash: "",
        level: 0,
        tier: "unused",
      };
      pkgs.push(p);
      byDir.set(abs(repo, pkgPath), p);
      mods.set(p.id, mod);
    }
  }
  const byId = new Map(pkgs.map((p) => [p.id, p]));

  // The deepest package directory containing a file, or none.
  const dirsDeepFirst = [...byDir.keys()].sort((a, b) => b.length - a.length);
  const owner = (file: string): Pkg | undefined => {
    for (const d of dirsDeepFirst) if (file.startsWith(`${d}/`)) return byDir.get(d);
    return undefined;
  };

  // Content hash and generated flag over each package's own .k files.
  const kFiles = new Map<string, string[]>();
  for (const { repo, files } of scanned) {
    for (const f of files) {
      if (!f.endsWith(".k")) continue;
      const a = abs(repo, f);
      const p = owner(a);
      if (!p) continue;
      if (!kFiles.has(p.id)) kFiles.set(p.id, []);
      kFiles.get(p.id)?.push(a);
    }
  }
  for (const p of pkgs) {
    const list = (kFiles.get(p.id) ?? []).sort();
    const dir = abs(repos.find((r) => r.name === p.repo) as Repo, p.path);
    const h = createHash("sha256");
    let generated = list.length > 0;
    for (const a of list) {
      const text = readFileSync(a, "utf8");
      h.update(relative(dir, a)).update("\0").update(text).update("\0");
      if (!/generated by|do not edit|auto-gen/i.test(text.slice(0, 400))) generated = false;
    }
    p.files = list.length;
    p.hash = h.digest("hex").slice(0, 16);
    p.generated = generated;
  }

  // Edges from kcl.mod [dependencies].
  const externals = new Map<string, External>();
  const external = (name: string): string => {
    const id = `ext:${name}`;
    if (!externals.has(id)) externals.set(id, { id, kind: "external", name, level: 0 });
    return id;
  };
  const ownByRegistry = (ref: string): Pkg | undefined => {
    const cut = ref.lastIndexOf("/");
    const repo = REGISTRIES[ref.slice(0, cut)];
    const name = ref.slice(cut + 1);
    return repo ? pkgs.find((p) => p.repo === repo && p.name === name) : undefined;
  };
  const edges: Edge[] = [];
  const findings: Finding[] = [];
  for (const p of pkgs) {
    const repo = repos.find((r) => r.name === p.repo) as Repo;
    const deps = (mods.get(p.id)?.dependencies ?? {}) as Record<string, unknown>;
    for (const [key, spec] of Object.entries(deps)) {
      if (typeof spec === "string" || (typeof spec === "object" && spec && "version" in spec && !("oci" in spec))) {
        const version = typeof spec === "string" ? spec : String((spec as Record<string, unknown>).version);
        edges.push({ from: p.id, to: external(`${KCL_REGISTRY}/${key}`), kind: "registry", key, pin: version });
        continue;
      }
      const s = spec as Record<string, string>;
      if (s.path !== undefined) {
        const target = byDir.get(resolve(repo.dir, p.path, s.path));
        if (!target) {
          findings.push({ severity: "error", code: "missing-path", message: `${p.id}: dependency ${key} = { path = "${s.path}" } has no kcl.mod`, ids: [p.id] });
          continue;
        }
        edges.push({ from: p.id, to: target.id, kind: "path", key, pin: null });
      } else if (s.oci !== undefined) {
        const ref = s.oci.replace(/^oci:\/\//, "");
        const own = ownByRegistry(ref);
        edges.push({ from: p.id, to: own ? own.id : external(ref), kind: "oci", key, pin: s.tag ?? null });
      } else if (s.git !== undefined) {
        edges.push({ from: p.id, to: external(s.git), kind: "git", key, pin: s.tag ?? s.commit ?? s.branch ?? null });
      }
    }
  }

  // Usage: OCI references and path mentions in every other tracked text file.
  const names = new Set(pkgs.map((p) => p.name));
  const ociRe = new RegExp(
    `(?:oci://)?(${Object.keys(REGISTRIES).map(escapeRe).join("|")})/([a-z0-9][a-z0-9_-]*)(?:(?::|\\?tag=)(v?[0-9][A-Za-z0-9._+-]*[A-Za-z0-9]))?`,
    "g",
  );
  const repoNames = new Set(repos.map((r) => r.name));
  const pathRe = /(?:([A-Za-z0-9_.-]+)\/)?(packages\/[A-Za-z0-9_\-/.]*[A-Za-z0-9_-])/g;
  const refs: Ref[] = [];
  const seen = new Set<string>();
  const addRef = (r: Ref): void => {
    const k = `${r.pkg}|${r.repo}|${r.path}|${r.line}|${r.tag}`;
    if (seen.has(k)) return;
    seen.add(k);
    refs.push(r);
  };
  for (const { repo, files } of scanned) {
    for (const f of files) {
      const b = basename(f);
      const textual = TEXT_EXT.test(f) || TEXT_NAMES.has(b) || b.startsWith("Taskfile.");
      if (!textual || b === "kcl.mod" || b === "kcl.mod.lock" || b.endsWith(".lock") || b === "pnpm-lock.yaml") continue;
      const a = abs(repo, f);
      if (a === outPath) continue;
      if (statSync(a).size > MAX_FILE_BYTES) continue;
      const text = readFileSync(a, "utf8");
      if (!text.includes("packages/") && !Object.keys(REGISTRIES).some((r) => text.includes(r))) continue;
      const self = owner(a);
      const kind = refKind(f);
      const lines = text.split("\n");
      lines.forEach((line, i) => {
        for (const m of line.matchAll(ociRe)) {
          const pkgRepo = REGISTRIES[m[1]];
          if (!names.has(m[2])) continue;
          const target = pkgs.find((p) => p.repo === pkgRepo && p.name === m[2]);
          if (!target || target === self) continue;
          addRef({ pkg: target.id, repo: repo.name, path: f, line: i + 1, kind, tag: m[3] ?? null });
        }
        for (const m of line.matchAll(pathRe)) {
          const inRepo = m[1] && repoNames.has(m[1]) ? (repos.find((r) => r.name === m[1]) as Repo) : repo;
          const target = owner(`${resolve(inRepo.dir, m[2])}/`);
          if (!target || target === self) continue;
          addRef({ pkg: target.id, repo: repo.name, path: f, line: i + 1, kind, tag: null });
        }
      });
    }
  }

  // Levels: dependencies first. A back edge (a cycle, reported below) counts as a leaf.
  const out = new Map<string, Edge[]>();
  for (const e of edges) {
    if (!out.has(e.from)) out.set(e.from, []);
    out.get(e.from)?.push(e);
  }
  const level = new Map<string, number>();
  const visiting = new Set<string>();
  const levelOf = (id: string): number => {
    const known = level.get(id);
    if (known !== undefined) return known;
    if (visiting.has(id)) return 0;
    visiting.add(id);
    const deps = out.get(id) ?? [];
    const l = deps.length ? 1 + Math.max(...deps.map((e) => levelOf(e.to))) : 0;
    visiting.delete(id);
    level.set(id, l);
    return l;
  };
  for (const p of pkgs) p.level = levelOf(p.id);
  for (const x of externals.values()) x.level = 0;

  // Tiers.
  const depended = new Set(edges.filter((e) => byId.has(e.to)).map((e) => e.to));
  for (const p of pkgs) {
    const mine = refs.filter((r) => r.pkg === p.id);
    if (depended.has(p.id) || mine.some((r) => r.kind !== "docs")) p.tier = "used";
    else if (mine.length) p.tier = "docs-only";
  }

  findings.push(...analyse(pkgs, byId, edges, refs));
  findings.sort((a, b) => (a.severity === b.severity ? a.code.localeCompare(b.code) || a.message.localeCompare(b.message) : a.severity === "error" ? -1 : 1));

  return {
    repos: repos.map((r) => ({ name: r.name, packages: pkgs.filter((p) => p.repo === r.name).length })),
    registries: REGISTRIES,
    nodes: [...pkgs.sort((a, b) => a.level - b.level || a.name.localeCompare(b.name) || a.id.localeCompare(b.id)), ...[...externals.values()].sort((a, b) => a.name.localeCompare(b.name))],
    edges: edges.sort((a, b) => a.from.localeCompare(b.from) || a.to.localeCompare(b.to)),
    refs: refs.sort((a, b) => a.pkg.localeCompare(b.pkg) || a.repo.localeCompare(b.repo) || a.path.localeCompare(b.path) || a.line - b.line),
    findings,
  };
}

// --------------------------------------------------------------- findings ---

function analyse(pkgs: Pkg[], byId: Map<string, Pkg>, edges: Edge[], refs: Ref[]): Finding[] {
  const findings: Finding[] = [];

  // Cycles: strongly connected components over own-package edges (Tarjan).
  const own = edges.filter((e) => byId.has(e.to));
  const next = new Map<string, string[]>();
  for (const e of own) {
    if (!next.has(e.from)) next.set(e.from, []);
    next.get(e.from)?.push(e.to);
  }
  let index = 0;
  const idx = new Map<string, number>();
  const low = new Map<string, number>();
  const stack: string[] = [];
  const onStack = new Set<string>();
  const strong = (v: string): void => {
    idx.set(v, index);
    low.set(v, index++);
    stack.push(v);
    onStack.add(v);
    for (const w of next.get(v) ?? []) {
      if (!idx.has(w)) {
        strong(w);
        low.set(v, Math.min(low.get(v) as number, low.get(w) as number));
      } else if (onStack.has(w)) low.set(v, Math.min(low.get(v) as number, idx.get(w) as number));
    }
    if (low.get(v) === idx.get(v)) {
      const scc: string[] = [];
      let w: string;
      do {
        w = stack.pop() as string;
        onStack.delete(w);
        scc.push(w);
      } while (w !== v);
      if (scc.length > 1 || (next.get(v) ?? []).includes(v)) {
        findings.push({ severity: "error", code: "cycle", message: `dependency cycle: ${scc.sort().join(" → ")}`, ids: scc });
      }
    }
  };
  for (const p of pkgs) if (!idx.has(p.id)) strong(p.id);

  // Pins on own packages against their source version, and dependency keys.
  for (const e of own) {
    const target = byId.get(e.to) as Pkg;
    if (e.key !== target.name) {
      findings.push({ severity: "warn", code: "name-mismatch", message: `${e.from}: dependency key ${e.key} names package ${target.name} (${target.id})`, ids: [e.from, e.to] });
    }
    if (e.pin === null) continue;
    const c = compareVersions(e.pin, target.version);
    if (c < 0) findings.push({ severity: "error", code: "pin-behind", message: `${e.from} pins ${target.name} ${e.pin}; its source (${target.id}) is ${target.version}`, ids: [e.from, e.to] });
    if (c > 0) findings.push({ severity: "error", code: "pin-ahead", message: `${e.from} pins ${target.name} ${e.pin}, newer than its source ${target.id} at ${target.version}`, ids: [e.from, e.to] });
  }

  // One name, several directories.
  const byName = new Map<string, Pkg[]>();
  for (const p of pkgs) {
    if (!byName.has(p.name)) byName.set(p.name, []);
    byName.get(p.name)?.push(p);
  }
  for (const [name, list] of byName) {
    if (list.length < 2) continue;
    const ids = list.map((p) => p.id);
    const same = list.every((p) => p.hash === list[0].hash);
    findings.push(
      same
        ? { severity: "warn", code: "duplicate", message: `${name}: identical copies in ${ids.join(", ")}`, ids }
        : { severity: "error", code: "diverged-copy", message: `${name}: ${list.length} copies with different .k files: ${list.map((p) => `${p.id}@${p.version}`).join(", ")}`, ids },
    );
  }

  // Tagged references in non-docs files that miss the source version.
  for (const r of refs) {
    if (r.tag === null || r.kind === "docs") continue;
    const target = byId.get(r.pkg) as Pkg;
    if (compareVersions(r.tag, target.version) === 0) continue;
    findings.push({ severity: "warn", code: "stale-ref", message: `${r.repo}:${r.path}:${r.line} uses ${target.name}:${r.tag}; source is ${target.version}`, ids: [r.pkg] });
  }
  return findings;
}

// ----------------------------------------------------------------- impact ---

interface ImpactStep {
  id: string;
  name: string;
  version: string;
  via: { from: string; kind: DepKind; pin: string | null }[];
}

/** Everything downstream of `ids`, dependencies before dependents. */
function impact(graph: Graph, ids: string[]): { order: ImpactStep[]; refs: Ref[] } {
  const dependents = new Map<string, Edge[]>();
  for (const e of graph.edges) {
    if (!dependents.has(e.to)) dependents.set(e.to, []);
    dependents.get(e.to)?.push(e);
  }
  const affected = new Set(ids);
  const todo = [...ids];
  while (todo.length) {
    const id = todo.pop() as string;
    for (const e of dependents.get(id) ?? []) {
      if (!affected.has(e.from)) {
        affected.add(e.from);
        todo.push(e.from);
      }
    }
  }
  const nodes = new Map(graph.nodes.map((n) => [n.id, n]));
  const inside = graph.edges.filter((e) => affected.has(e.from) && affected.has(e.to));
  const waiting = new Map([...affected].map((id) => [id, inside.filter((e) => e.from === id).length]));
  const order: ImpactStep[] = [];
  const ready = [...affected].filter((id) => waiting.get(id) === 0);
  const rank = (id: string): string => {
    const n = nodes.get(id) as GraphNode;
    return `${String(n.level).padStart(4, "0")} ${n.name} ${id}`;
  };
  while (ready.length) {
    ready.sort((a, b) => rank(a).localeCompare(rank(b)));
    const id = ready.shift() as string;
    const n = nodes.get(id) as Pkg;
    order.push({
      id,
      name: n.name,
      version: n.kind === "package" ? n.version : "",
      via: inside.filter((e) => e.from === id).map((e) => ({ from: e.to, kind: e.kind, pin: e.pin })),
    });
    for (const e of inside.filter((x) => x.to === id)) {
      const left = (waiting.get(e.from) as number) - 1;
      waiting.set(e.from, left);
      if (left === 0) ready.push(e.from);
    }
  }
  // A cycle leaves members unordered; list them last rather than drop them.
  for (const id of affected) {
    if (!order.some((s) => s.id === id)) {
      const n = nodes.get(id) as Pkg;
      order.push({ id, name: n.name, version: n.version ?? "", via: inside.filter((e) => e.from === id).map((e) => ({ from: e.to, kind: e.kind, pin: e.pin })) });
    }
  }
  return { order, refs: graph.refs.filter((r) => affected.has(r.pkg) && r.kind !== "docs") };
}

function resolveTarget(graph: Graph, target: string): string[] {
  const pkgs = graph.nodes.filter((n): n is Pkg => n.kind === "package");
  const exact = pkgs.filter((p) => p.id === target || p.path === target.replace(/\/$/, ""));
  if (exact.length) return exact.map((p) => p.id);
  const named = pkgs.filter((p) => p.name === target);
  if (named.length) return named.map((p) => p.id);
  // An external module by its reference or last segment: `k8s`, `ghcr.io/kcl-lang/k8s`.
  const ext = graph.nodes.filter((n) => n.kind === "external" && (n.name === target || n.name.endsWith(`/${target}`)));
  if (ext.length) return ext.map((n) => n.id);
  throw new Error(`no package or external module ${target}; give a name, <repo>:<path>, a path or a module reference`);
}

// ----------------------------------------------------------------- cypher ---

function lit(v: unknown): string {
  if (v === null || v === undefined) return "null";
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (Array.isArray(v)) return `[${v.map(lit).join(", ")}]`;
  if (typeof v === "object") return `{${Object.entries(v).map(([k, x]) => `${k}: ${lit(x)}`).join(", ")}}`;
  return `'${String(v).replace(/\\/g, "\\\\").replace(/'/g, "\\'")}'`;
}

function cypher(graph: Graph): string {
  const files = new Map<string, { id: string; repo: string; path: string; kind: RefKind }>();
  for (const r of graph.refs) files.set(`${r.repo}:${r.path}`, { id: `${r.repo}:${r.path}`, repo: r.repo, path: r.path, kind: r.kind });
  const unwind = (rows: unknown[], body: string): string => (rows.length ? `UNWIND ${lit(rows)} AS row\n${body};\n` : "");
  const pkgs = graph.nodes.filter((n): n is Pkg => n.kind === "package");
  const exts = graph.nodes.filter((n): n is External => n.kind === "external");
  return [
    "// GENERATED by `just package-graph-cypher` (tools/graph/src/package-graph.ts). Do not edit.",
    "// Load into Neo4j 5: cypher-shell -u neo4j -p <password> -f <this file>",
    "// Every node carries the label KclGraph; a reload replaces exactly those.",
    "//",
    "// Blast radius of a package (everything that depends on it, transitively):",
    "//   MATCH (p:KclPackage {name: 'cluster-gcp'})<-[:DEPENDS_ON*]-(d:KclPackage) RETURN DISTINCT d.id, d.version",
    "// Who uses a package from another repo:",
    "//   MATCH (f:SourceFile)-[r:REFERENCES]->(p:KclPackage {name: 'app'}) WHERE f.repo <> p.repo RETURN f.id, r.line, r.tag",
    "// Pins behind their source:",
    "//   MATCH (a)-[d:DEPENDS_ON]->(b:KclPackage) WHERE d.pin IS NOT NULL AND d.pin <> b.version RETURN a.id, b.id, d.pin, b.version",
    "// Packages nothing uses:",
    "//   MATCH (p:KclPackage {tier: 'unused'}) RETURN p.repo, p.path ORDER BY p.repo, p.path",
    "",
    "CREATE INDEX kcl_graph_id IF NOT EXISTS FOR (n:KclGraph) ON (n.id);",
    "MATCH (n:KclGraph) DETACH DELETE n;",
    unwind(graph.repos.map((r) => ({ id: `repo:${r.name}`, name: r.name })), "CREATE (n:KclGraph:Repo) SET n = row"),
    unwind(
      pkgs.map(({ id, name, version, repo, path, generated, files, level, tier }) => ({ id, name, version, repo, path, generated, files, level, tier })),
      "CREATE (n:KclGraph:KclPackage) SET n = row\nWITH n MATCH (r:Repo {id: 'repo:' + n.repo}) CREATE (n)-[:IN_REPO]->(r)",
    ),
    unwind(exts.map(({ id, name }) => ({ id, ref: name })), "CREATE (n:KclGraph:ExternalModule) SET n = row"),
    unwind([...files.values()], "CREATE (n:KclGraph:SourceFile) SET n = row\nWITH n MATCH (r:Repo {id: 'repo:' + n.repo}) CREATE (n)-[:IN_REPO]->(r)"),
    unwind(
      graph.edges.map((e) => ({ a: e.from, b: e.to, kind: e.kind, key: e.key, pin: e.pin })),
      "MATCH (a:KclGraph {id: row.a}), (b:KclGraph {id: row.b})\nCREATE (a)-[:DEPENDS_ON {kind: row.kind, key: row.key, pin: row.pin}]->(b)",
    ),
    unwind(
      graph.refs.map((r) => ({ f: `${r.repo}:${r.path}`, p: r.pkg, line: r.line, tag: r.tag })),
      "MATCH (f:KclGraph {id: row.f}), (p:KclGraph {id: row.p})\nCREATE (f)-[:REFERENCES {line: row.line, tag: row.tag}]->(p)",
    ),
  ].join("\n");
}

// ------------------------------------------------------------------- main ---

function summary(graph: Graph): string {
  const pkgs = graph.nodes.filter((n): n is Pkg => n.kind === "package");
  const tiers = ["used", "docs-only", "unused"].map((t) => `${pkgs.filter((p) => p.tier === t).length} ${t}`).join(", ");
  return `${pkgs.length} packages in ${graph.repos.map((r) => `${r.name} (${r.packages})`).join(", ")}; ${graph.edges.length} dependencies; ${graph.refs.length} references; ${tiers}`;
}

/** The page: the template with the graph inlined, `<` escaped so no string in the data can close the script element. */
function page(graph: Graph): string {
  const data = JSON.stringify(graph).replace(/</g, "\\u003c");
  return readFileSync(templatePath, "utf8").replace("__GRAPH_DATA__", () => data);
}

/** Serve the page, rebuilt from the repos on every load; nothing is written. */
function serve(repos: Repo[], port: number): void {
  createServer((req, res) => {
    const path = new URL(req.url ?? "/", "http://localhost").pathname;
    if (req.method !== "GET" || (path !== "/" && path !== "/index.html")) {
      res.writeHead(404).end();
      return;
    }
    try {
      const graph = build(repos);
      res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }).end(page(graph));
      console.log(`${new Date().toISOString()} ${summary(graph)}`);
    } catch (e) {
      res.writeHead(500, { "content-type": "text/plain; charset=utf-8" }).end(`package-graph: ${e instanceof Error ? e.message : e}\n`);
    }
  }).listen(port, "127.0.0.1", () => console.log(`serving the KCL package graph on http://127.0.0.1:${port}`));
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));
  if (args.command === "serve") {
    serve(args.repos, Number(args.target ?? 4560));
    return;
  }
  const graph = build(args.repos);

  if (args.command === "page") {
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, page(graph));
    console.log(`wrote ${relative(root, outPath)}: ${summary(graph)}`);
    return;
  }

  if (args.command === "cypher") {
    const text = cypher(graph);
    if (args.target) {
      mkdirSync(dirname(resolve(args.target)), { recursive: true });
      writeFileSync(resolve(args.target), text);
      console.log(`wrote ${args.target}: ${summary(graph)}`);
    } else process.stdout.write(text);
    return;
  }

  if (args.command === "impact") {
    const ids = resolveTarget(graph, args.target as string);
    const result = impact(graph, ids);
    if (args.json) {
      console.log(JSON.stringify({ targets: ids, ...result }, null, 2));
      return;
    }
    console.log(`Impact of ${ids.join(", ")}: ${result.order.length} packages, dependencies first.\n`);
    result.order.forEach((s, i) => {
      const how = s.via.length
        ? s.via.map((v) => (v.kind === "path" ? `path dep on ${v.from}` : `${v.kind} pin ${v.pin} on ${v.from}: bump it`)).join("; ")
        : "changed";
      console.log(`${String(i + 1).padStart(3)}. ${s.id}${s.version ? `@${s.version}` : ""}  ${how}`);
    });
    const byRepo = new Map<string, Ref[]>();
    for (const r of result.refs) {
      if (!byRepo.has(r.repo)) byRepo.set(r.repo, []);
      byRepo.get(r.repo)?.push(r);
    }
    console.log(`\nConsumers to retest: ${result.refs.length} references in ${byRepo.size} repos.`);
    for (const [repo, list] of byRepo) {
      console.log(`  ${repo}`);
      for (const r of list) console.log(`    ${r.path}:${r.line}  ${r.pkg}${r.tag ? `:${r.tag}` : ""}  (${r.kind})`);
    }
    return;
  }

  // check
  const errors = graph.findings.filter((f) => f.severity === "error");
  if (args.json) console.log(JSON.stringify({ summary: summary(graph), findings: graph.findings }, null, 2));
  else {
    console.log(summary(graph));
    for (const f of graph.findings) console.log(`${f.severity === "error" ? "error" : "warn "} ${f.code.padEnd(13)} ${f.message}`);
    console.log(`${errors.length} errors, ${graph.findings.length - errors.length} warnings`);
  }
  if (errors.length) process.exitCode = 1;
}

try {
  main();
} catch (e) {
  console.error(`package-graph: ${e instanceof Error ? e.message : e}`);
  process.exitCode = 2;
}
