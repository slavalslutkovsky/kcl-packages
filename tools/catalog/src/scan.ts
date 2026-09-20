/**
 * Scan packages/** for everything the Crossplane estate is made of, and answer
 * the four questions a portal has to answer about it:
 *
 *   what exists      every KCL package, every XRD, every Composition, every
 *                    example XR on disk
 *   what depends on  kcl.mod `path = "…"` deps (the same edges nx draws), plus
 *   what             Composition → XRD (which API it implements) and
 *                    Composition → child XR (a composite of composites)
 *   how used         per XR kind: how many Compositions implement it, how many
 *                    examples instantiate it, how many other Compositions
 *                    render it as a child, how many devkit.toml rows install it
 *   what to fix      findings.ts, over exactly this model
 *
 * This module only reads files; catalog.ts turns the result into Backstage
 * entities and mcp.ts serves it to agents. Both consume `scan()`, so the portal
 * and an assistant can never disagree about what the repo contains.
 *
 * Nothing here talks to a cluster. A running XR is a fact about a cluster, not
 * about this repo, and a catalog that needs a kubeconfig to build is a catalog
 * that is empty exactly when a cluster is down.
 */
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { parse as parseToml } from "smol-toml";
import { parseAllDocuments, stringify as stringifyYaml } from "yaml";

import { computeFindings } from "./findings.ts";

export const repoRoot = resolve(import.meta.dirname, "../../..");

/** The API groups an XR lives in. A `kind` literal in one of these groups is a
 *  composite resource; anything else a Composition renders is a managed one. */
export const xrGroups = ["cloud.example.org", "platform.example.org"];

export type PackageKind = "function" | "xrd" | "cli" | "provider" | "lib";

export interface KclPackage {
  name: string;
  version: string;
  /** repo-relative directory, e.g. "packages/cloud/bucket/aws" */
  root: string;
  /** segment after packages/, e.g. "cloud" */
  area: string;
  /** capability module directory, e.g. "bucket"; "" for top-level packages */
  module: string;
  kind: PackageKind;
  /** package NAMES this one depends on, from `path = "…"` entries */
  pathDeps: string[];
  /** package names that depend on this one */
  dependents: string[];
  hasTests: boolean;
}

export interface XrdInfo {
  package: string;
  root: string;
  file: string;
  group: string;
  xrKind: string;
  plural: string;
  scope: string;
  versions: string[];
  /** group/<first served version> */
  apiVersion: string;
  module: string;
  /** the first served version's openAPIV3Schema, re-serialised */
  schemaYaml: string;
  description: string;
}

export interface CompositionInfo {
  /** the KCL package that renders it, or its own metadata.name when the
   *  renderer is not a KCL package (packages/cloud/package-registry/*) */
  package: string;
  root: string;
  file: string;
  /** capability module directory, e.g. "bucket" */
  module: string;
  name: string;
  compositeApiVersion: string;
  compositeKind: string;
  /** metadata.labels.provider — the backend a claim selects; "" when the
   *  Composition is the only implementation of its XRD */
  backend: string;
  functions: string[];
  sourceImage: string;
  pinnedTag: string;
  packageVersion: string;
  /** XR kinds this module renders as CHILDREN (composite of composites) */
  childKinds: string[];
}

export interface ExampleXr {
  file: string;
  apiVersion: string;
  kind: string;
  name: string;
  backend: string;
  module: string;
}

export interface Usage {
  xrKind: string;
  compositions: string[];
  backends: string[];
  examples: number;
  childOf: string[];
  devkitRows: number;
  total: number;
}

export type Severity = "high" | "medium" | "low";

export interface Finding {
  rule: string;
  severity: Severity;
  subject: string;
  detail: string;
  evidence: string;
}

export interface Workspace {
  root: string;
  repoSlug: string;
  packages: KclPackage[];
  xrds: XrdInfo[];
  compositions: CompositionInfo[];
  examples: ExampleXr[];
  usage: Usage[];
  findings: Finding[];
}

// ── narrowing over parsed YAML/TOML ──────────────────────────────────────────
// Documents on disk are `unknown` until proven otherwise. These three keep the
// proof in one place instead of at every field read; a shape that is missing or
// the wrong type reads as empty rather than throwing, because a malformed
// example must not take the whole catalog down with it.

export function asObject(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

export function asString(value: unknown): string {
  return typeof value === "string" ? value : typeof value === "number" || typeof value === "boolean" ? String(value) : "";
}

export function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

/** Nested read: `dig(doc, "spec", "names", "kind")`. */
function dig(value: unknown, ...keys: string[]): unknown {
  let cursor = value;
  for (const key of keys) cursor = asObject(cursor)[key];
  return cursor;
}

// ── file helpers ─────────────────────────────────────────────────────────────

/** Depth-first walk yielding repo-relative file paths, skipping what is never
 *  an input: installed modules, build output, the kcl cache. */
function* walk(dir: string, root: string): Generator<string> {
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }
  for (const entry of entries) {
    if (entry === "node_modules" || entry === "target" || entry === ".git" || entry === ".kclvm") continue;
    const abs = join(dir, entry);
    let isDir: boolean;
    try {
      isDir = statSync(abs).isDirectory();
    } catch {
      continue; // broken symlink
    }
    if (isDir) yield* walk(abs, root);
    else yield relative(root, abs);
  }
}

function readText(root: string, rel: string): string {
  return readFileSync(join(root, rel), "utf8");
}

function exists(root: string, rel: string): boolean {
  try {
    statSync(join(root, rel));
    return true;
  } catch {
    return false;
  }
}

/** packages/<area>/<module>/<backend> → module; shallower paths have none.
 *  The module is the unit the whole estate is organised by: one XRD, one set
 *  of backend Compositions, one set of examples, one devkit row group. */
function moduleOf(dir: string): string {
  const parts = dir.split("/");
  return parts.length >= 4 ? parts[2]! : "";
}

// ── kcl.mod ──────────────────────────────────────────────────────────────────

interface ModInfo {
  name: string;
  version: string;
  /** repo-relative directories of `path = "…"` dependencies */
  deps: string[];
}

/** kcl.mod is TOML in practice, but the kcl CLI accepts shapes smol-toml
 *  rejects, so a parse failure falls back to the same regex
 *  tools/nx-kcl/src/utils.ts uses rather than dropping the package out of the
 *  graph entirely. */
function modInfo(root: string, modRel: string): ModInfo {
  const text = readText(root, modRel);
  const dir = modRel.slice(0, modRel.lastIndexOf("/"));
  const deps: string[] = [];
  try {
    const parsed = parseToml(text);
    const pkg = asObject(asObject(parsed).package);
    for (const value of Object.values(asObject(asObject(parsed).dependencies))) {
      const p = asObject(value).path;
      if (typeof p === "string") deps.push(relative(root, resolve(root, dir, p)));
    }
    return { name: asString(pkg.name), version: asString(pkg.version), deps };
  } catch {
    for (const m of text.matchAll(/^\s*[\w-]+\s*=\s*\{[^}]*path\s*=\s*"([^"]+)"/gm)) {
      deps.push(relative(root, resolve(root, dir, m[1]!)));
    }
    return {
      name: /^\s*name\s*=\s*"([^"]+)"/m.exec(text)?.[1] ?? "",
      version: /^\s*version\s*=\s*"([^"]+)"/m.exec(text)?.[1] ?? "",
      deps,
    };
  }
}

/** What a package IS, decided by what sits next to its kcl.mod — the same
 *  discriminator tools/nx-kcl uses to give a package a `render` target. */
function classify(root: string, dir: string): PackageKind {
  if (exists(root, `${dir}/composition.yaml`)) return "function";
  if (exists(root, `${dir}/xrd.yaml`)) return "xrd";
  if (dir.startsWith("packages/providers/")) return "provider";
  const main = exists(root, `${dir}/main.k`) ? readText(root, `${dir}/main.k`) : "";
  return main.includes("yaml_stream") ? "cli" : "lib";
}

// ── XRDs, Compositions, examples ─────────────────────────────────────────────

function xrdFrom(root: string, file: string, pkgName: string): XrdInfo | undefined {
  const doc = parseAllDocuments(readText(root, file))
    .map((d) => d.toJS() as unknown)
    .find((d) => asString(asObject(d).kind) === "CompositeResourceDefinition");
  if (!doc) return undefined;
  const spec = asObject(asObject(doc).spec);
  const versions = asArray(spec.versions);
  const version = asObject(versions.find((v) => asObject(v).served !== false) ?? versions[0]);
  const schema = dig(version, "schema", "openAPIV3Schema");
  const dir = file.slice(0, file.lastIndexOf("/"));
  return {
    package: pkgName,
    root: dir,
    file,
    group: asString(spec.group),
    xrKind: asString(dig(spec, "names", "kind")),
    plural: asString(dig(spec, "names", "plural")),
    scope: asString(spec.scope) || "Cluster",
    versions: versions.map((v) => asString(asObject(v).name)),
    apiVersion: `${asString(spec.group)}/${asString(version.name)}`,
    module: moduleOf(dir),
    schemaYaml: stringifyYaml(schema ?? {}),
    description: asString(dig(schema, "properties", "spec", "description")).replace(/\s+/g, " ").trim(),
  };
}

/** XR kinds a Composition package renders as children.
 *
 *  Two spellings, because the two composites of composites in the tree use
 *  both: appstack builds child dicts from a `"<group>/<version>"` literal, and
 *  inbox imports the child XRDs' generated schemas (`bucket-xrd`) and
 *  instantiates them by type. The status echo `oxr?.apiVersion or "<group>/…"`
 *  is stripped first — every Composition has one, and counting it would make
 *  all 63 of them look like composites of composites. */
function childKindsOf(
  root: string,
  pkg: KclPackage,
  ownKind: string,
  xrKinds: Set<string>,
  xrdByPackage: Map<string, XrdInfo>,
): string[] {
  const found = new Set<string>();

  for (const dep of pkg.pathDeps) {
    const xrd = xrdByPackage.get(dep);
    if (xrd && xrd.xrKind !== ownKind) found.add(xrd.xrKind);
  }

  for (const file of readdirSync(join(root, pkg.root))) {
    if (!file.endsWith(".k") || file.endsWith("_test.k") || file === "main.k") continue;
    const text = readText(root, `${pkg.root}/${file}`)
      .split("\n")
      .filter((line) => !line.includes("oxr?.apiVersion or") && !line.includes("oxr?.kind or"))
      .join("\n");
    if (!xrGroups.some((g) => text.includes(`"${g}/`))) continue;
    for (const m of text.matchAll(/kind\s*=\s*"([A-Z][A-Za-z0-9]*)"/g)) {
      const kind = m[1]!;
      if (kind !== ownKind && xrKinds.has(kind)) found.add(kind);
    }
  }
  return [...found].sort();
}

/** One composition.yaml.
 *
 *  `pkg` is undefined for a Composition whose renderer is NOT a KCL package —
 *  packages/cloud/package-registry/* is rendered by the Python function in
 *  python/function-package-registry and therefore ships no kcl.mod. Such a
 *  Composition has no package name, version, source image or path deps, so it
 *  is identified by its own metadata.name and is silently exempt from the
 *  pin-drift and unpinned rules (both key off `sourceImage`/`pinnedTag`). */
function compositionFrom(
  root: string,
  dir: string,
  pkg: KclPackage | undefined,
  xrKinds: Set<string>,
  xrdByPackage: Map<string, XrdInfo>,
): CompositionInfo | undefined {
  const file = `${dir}/composition.yaml`;
  const comp = parseAllDocuments(readText(root, file))
    .map((d) => d.toJS() as unknown)
    .find((d) => asString(asObject(d).kind) === "Composition");
  if (!comp) return undefined;
  const spec = asObject(asObject(comp).spec);
  const pipeline = asArray(spec.pipeline);
  const source = pipeline.map((step) => asString(dig(step, "input", "spec", "source"))).find((s) => s.length > 0) ?? "";
  const [image, query] = source.split("?");
  const compositeKind = asString(dig(spec, "compositeTypeRef", "kind"));
  return {
    package: pkg?.name ?? asString(dig(comp, "metadata", "name")),
    root: dir,
    file,
    module: moduleOf(dir),
    name: asString(dig(comp, "metadata", "name")),
    compositeApiVersion: asString(dig(spec, "compositeTypeRef", "apiVersion")),
    compositeKind,
    backend: asString(dig(comp, "metadata", "labels", "provider")),
    functions: pipeline.map((step) => asString(dig(step, "functionRef", "name"))).filter(Boolean),
    sourceImage: image ?? "",
    pinnedTag: /(?:^|&)tag=([^&]+)/.exec(query ?? "")?.[1] ?? "",
    packageVersion: pkg?.version ?? "",
    childKinds: pkg ? childKindsOf(root, pkg, compositeKind, xrKinds, xrdByPackage) : [],
  };
}

/** Which backend an example selects.
 *
 *  `spec.crossplane.compositionSelector.matchLabels.provider` is the explicit
 *  answer and is used whenever present. Several modules leave it out — an
 *  IRSA WorkloadIdentity is unambiguous from its fields alone — and name the
 *  file after the backend instead (`workload-identity-aws.yaml`), which is
 *  the convention `nx render --example` already relies on. Without this
 *  fallback every such backend would be reported as untested. */
function exampleBackend(obj: Record<string, unknown>, file: string, backends: Set<string>): string {
  const selected = asString(dig(obj, "spec", "crossplane", "compositionSelector", "matchLabels", "provider"));
  if (selected) return selected;
  const stem = file.slice(file.lastIndexOf("/") + 1).replace(/\.ya?ml$/, "");
  return stem.split("-").find((token) => backends.has(token)) ?? "";
}

function examplesFrom(root: string, files: string[], xrKinds: Set<string>, backends: Set<string>): ExampleXr[] {
  const out: ExampleXr[] = [];
  for (const file of files) {
    for (const doc of parseAllDocuments(readText(root, file))) {
      const obj = asObject(doc.toJS() as unknown);
      const kind = asString(obj.kind);
      if (!kind || !xrKinds.has(kind)) continue;
      out.push({
        file,
        apiVersion: asString(obj.apiVersion),
        kind,
        name: asString(dig(obj, "metadata", "name")),
        backend: exampleBackend(obj, file, backends),
        module: moduleOf(file.slice(0, file.lastIndexOf("/"))),
      });
    }
  }
  return out;
}

/** devkit.toml rows per module: `manifest = "packages/<area>/<module>/…"`.
 *  A capability nobody installs is a capability nobody runs, which is why the
 *  row count is part of usage rather than a separate report. */
function devkitRowsByModule(root: string): Map<string, number> {
  const counts = new Map<string, number>();
  if (!exists(root, "devkit.toml")) return counts;
  for (const m of readText(root, "devkit.toml").matchAll(/^\s*manifest\s*=\s*"(packages\/[^"]+)"/gm)) {
    const mod = moduleOf(m[1]!);
    if (mod) counts.set(mod, (counts.get(mod) ?? 0) + 1);
  }
  return counts;
}

/** `git remote get-url origin` → "owner/repo". Every entity is annotated with
 *  this slug, so a guess would point every portal card at the wrong
 *  repository; no remote falls back to the directory name. */
function repoSlug(root: string): string {
  try {
    const url = execFileSync("git", ["-C", root, "remote", "get-url", "origin"], { encoding: "utf8" }).trim();
    const m = /[:/]([^/:]+\/[^/]+?)(?:\.git)?$/.exec(url);
    if (m) return m[1]!;
  } catch {
    // no remote, or no git in PATH: fall through
  }
  return root.slice(root.lastIndexOf("/") + 1);
}

// ── the scan ─────────────────────────────────────────────────────────────────

export function scan(root: string = repoRoot): Workspace {
  const files = [...walk(join(root, "packages"), root)];

  // 1. Packages, from kcl.mod — the same unit nx infers a project from.
  const byRoot = new Map<string, KclPackage>();
  const depDirs = new Map<string, string[]>();
  for (const mod of files.filter((f) => f.endsWith("/kcl.mod"))) {
    const dir = mod.slice(0, -"/kcl.mod".length);
    const { name, version, deps } = modInfo(root, mod);
    if (!name) continue;
    depDirs.set(dir, deps);
    byRoot.set(dir, {
      name,
      version,
      root: dir,
      area: dir.split("/")[1] ?? "",
      module: moduleOf(dir),
      kind: classify(root, dir),
      pathDeps: [],
      dependents: [],
      // Only the package's own tests count: `kcl test` runs the directory, not
      // the subtree, so a sibling's test file proves nothing about this one.
      hasTests: files.some((f) => f.startsWith(`${dir}/`) && f.endsWith("_test.k") && !f.slice(dir.length + 1).includes("/")),
    });
  }
  const byName = new Map([...byRoot.values()].map((p) => [p.name, p]));
  for (const [dir, deps] of depDirs) {
    byRoot.get(dir)!.pathDeps = deps
      .map((d) => byRoot.get(d)?.name)
      .filter((n) => n !== undefined)
      .sort();
  }
  for (const pkg of byRoot.values()) {
    for (const dep of pkg.pathDeps) byName.get(dep)?.dependents.push(pkg.name);
  }
  for (const pkg of byRoot.values()) pkg.dependents.sort();

  // 2. XRDs — the APIs. Keyed by package too, so a typed child import resolves.
  const xrds: XrdInfo[] = [];
  for (const file of files.filter((f) => f.endsWith("/xrd.yaml"))) {
    const dir = file.slice(0, file.lastIndexOf("/"));
    const xrd = xrdFrom(root, file, byRoot.get(dir)?.name ?? "");
    if (xrd?.xrKind) xrds.push(xrd);
  }
  xrds.sort((a, b) => a.xrKind.localeCompare(b.xrKind));
  const xrKinds = new Set(xrds.map((x) => x.xrKind));
  const xrdByPackage = new Map(xrds.filter((x) => x.package).map((x) => [x.package, x]));

  // 3. Compositions — the implementations. Keyed off the FILE rather than the
  // package: a Composition rendered by a non-KCL function (the Python
  // function-package-registry) has no kcl.mod beside it.
  const compositions: CompositionInfo[] = [];
  for (const file of files.filter((f) => f.endsWith("/composition.yaml"))) {
    const dir = file.slice(0, -"/composition.yaml".length);
    const comp = compositionFrom(root, dir, byRoot.get(dir), xrKinds, xrdByPackage);
    if (comp) compositions.push(comp);
  }
  compositions.sort((a, b) => a.package.localeCompare(b.package));

  // 4. Example XRs — the only instances this repo knows about.
  const examples = examplesFrom(
    root,
    files.filter((f) => /\/xrd\/examples\/[^/]+\.ya?ml$/.test(f)),
    xrKinds,
    new Set(compositions.map((c) => c.backend).filter(Boolean)),
  ).sort((a, b) => a.file.localeCompare(b.file));

  // 5. Usage, per API.
  const devkit = devkitRowsByModule(root);
  const usage: Usage[] = xrds.map((xrd) => {
    const impls = compositions.filter((c) => c.compositeKind === xrd.xrKind);
    const childOf = compositions.filter((c) => c.childKinds.includes(xrd.xrKind)).map((c) => c.package);
    const exampleCount = examples.filter((e) => e.kind === xrd.xrKind).length;
    return {
      xrKind: xrd.xrKind,
      compositions: impls.map((c) => c.package),
      backends: [...new Set(impls.map((c) => c.backend).filter(Boolean))].sort(),
      examples: exampleCount,
      childOf,
      devkitRows: devkit.get(xrd.module) ?? 0,
      total: impls.length + exampleCount + childOf.length,
    };
  });

  const ws: Workspace = {
    root,
    repoSlug: repoSlug(root),
    packages: [...byRoot.values()].sort((a, b) => a.name.localeCompare(b.name)),
    xrds,
    compositions,
    examples,
    usage,
    findings: [],
  };
  ws.findings = computeFindings(ws);
  return ws;
}
