/**
 * Emit the Backstage view of this repo's Crossplane estate, from the scan:
 *
 *   catalog/crossplane.yaml    entities — one Domain, one System per capability
 *                              module, one API per XRD, one Component per
 *                              Composition package and per KCL package, one
 *                              Resource per example XR
 *   docs/crossplane-graph.md   the same graph for humans: Mermaid, usage
 *                              counts, provider fan-in, refactor findings
 *
 *   node tools/catalog/src/catalog.ts            # write both
 *   node tools/catalog/src/catalog.ts --check    # exit 1 if either is stale
 *
 * Entities are FILES, not cluster objects: Backstage ingests them from a
 * Location in git (docs/backstage.md § Getting the entities into Backstage),
 * so the portal keeps working when a cluster is down and a reviewer sees the
 * catalog diff in the same PR as the change that caused it.
 *
 * Why an emitter and not a Composition that renders entities: a Composition's
 * output IS Kubernetes objects, and `backstage.io/v1alpha1` is not an API any
 * cluster serves. docs/backstage.md listed this as the missing piece; this is
 * that piece.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { stringify as stringifyYaml } from "yaml";

import type { CompositionInfo, Finding, KclPackage, Usage, Workspace, XrdInfo } from "./scan.ts";
import { repoRoot, scan } from "./scan.ts";

const entitiesOut = "catalog/crossplane.yaml";
const graphOut = "docs/crossplane-graph.md";

/** Owner of everything emitted here. The estate is platform-owned by
 *  construction — a capability module has no other claimant — and Backstage
 *  rejects an ownerless entity. Override for a different org chart. */
const owner = process.env.BACKSTAGE_OWNER ?? "group:default/platform";

/** Jira project the tickets card filters on. GitHub Issues is authoritative
 *  here (backstage/README.md); the Jira card is the second surface. */
const jiraProject = process.env.JIRA_PROJECT_KEY ?? "PLAT";

const domainName = "crossplane-platform";
const providerSystem = "provider-schemas";
const toolingSystem = "platform-tooling";

interface Entity {
  apiVersion: "backstage.io/v1alpha1";
  kind: "Domain" | "System" | "API" | "Component" | "Resource";
  metadata: {
    name: string;
    title?: string;
    description?: string;
    tags?: string[];
    annotations?: Record<string, string>;
    links?: { url: string; title: string }[];
  };
  spec: Record<string, unknown>;
}

/** Backstage names allow [A-Za-z0-9._-]; everything else has to go, and a
 *  name that only differs by case is the same entity to a human reader. */
function entityName(raw: string): string {
  return raw.toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 63);
}

/** Tags are stricter than names: lowercase letters, digits, +, # and -. */
function tags(...raw: (string | undefined)[]): string[] {
  const out = raw
    .map((t) => (t ?? "").toLowerCase().replace(/[^a-z0-9+#-]+/g, "-").replace(/^-+|-+$/g, ""))
    .filter((t) => t.length > 0);
  return [...new Set(out)].sort();
}

export function buildEntities(ws: Workspace): Entity[] {
  const tree = `https://github.com/${ws.repoSlug}/tree/main`;
  const blob = `https://github.com/${ws.repoSlug}/blob/main`;
  const usageByKind = new Map(ws.usage.map((u) => [u.xrKind, u]));
  const xrdByKind = new Map(ws.xrds.map((x) => [x.xrKind, x]));
  const pkgByName = new Map(ws.packages.map((p) => [p.name, p]));
  const findingsBySubject = new Map<string, Finding[]>();
  for (const f of ws.findings) {
    const list = findingsBySubject.get(f.subject) ?? [];
    list.push(f);
    findingsBySubject.set(f.subject, list);
  }

  /** Annotations every entity carries: where the source is, which repo's PRs
   *  and issues belong to it, which Jira project its tickets live in. The
   *  GitHub and Jira cards render from exactly these three. */
  const common = (dir: string): Record<string, string> => ({
    "backstage.io/source-location": `url:${tree}/${dir}/`,
    "github.com/project-slug": ws.repoSlug,
    "jira/project-key": jiraProject,
  });

  /** A subject's open findings, as an annotation a portal card can list
   *  without re-deriving them: "high:composition-pin-drift, medium:…". */
  const findingAnnotation = (subject: string): Record<string, string> => {
    const list = findingsBySubject.get(subject);
    if (!list || list.length === 0) return {};
    return {
      "platform.example.org/findings": list.map((f) => `${f.severity}:${f.rule}`).join(", "),
      "platform.example.org/finding-count": String(list.length),
    };
  };

  const apiName = (xrd: XrdInfo): string => entityName(`${xrd.plural}.${xrd.group}`);

  const entities: Entity[] = [
    {
      apiVersion: "backstage.io/v1alpha1",
      kind: "Domain",
      metadata: {
        name: domainName,
        title: "Crossplane platform",
        description:
          "Portable cloud capabilities served as Crossplane composite resources: one XRD per capability, one Composition per backend, rendered by function-kcl from the packages in this repo.",
        tags: tags("crossplane", "kcl", "platform"),
        annotations: common("packages"),
      },
      spec: { owner },
    },
  ];

  // One System per capability module: the XRD, its backend Compositions and
  // its examples belong together and are released together.
  const modules = [...new Set(ws.xrds.map((x) => x.module))].filter(Boolean).sort();
  for (const mod of modules) {
    const xrd = ws.xrds.find((x) => x.module === mod)!;
    const usage = usageByKind.get(xrd.xrKind)!;
    entities.push({
      apiVersion: "backstage.io/v1alpha1",
      kind: "System",
      metadata: {
        name: entityName(mod),
        title: mod,
        description: `${xrd.xrKind} capability: XRD, ${usage.compositions.length} Composition(s)${usage.backends.length > 0 ? ` (${usage.backends.join(", ")})` : ""}, ${usage.examples} example XR(s).`,
        tags: tags("crossplane", mod, ...usage.backends),
        annotations: { ...common(xrd.root.split("/").slice(0, 3).join("/")) },
      },
      spec: { owner, domain: domainName },
    });
  }

  // Two systems for what is not a capability: the generated provider schemas
  // every Composition imports, and the packages that render plain manifests.
  entities.push(
    {
      apiVersion: "backstage.io/v1alpha1",
      kind: "System",
      metadata: {
        name: providerSystem,
        title: "Provider schemas",
        description:
          "Generated KCL schema packages, one per Crossplane provider, imported by the Compositions so a managed resource is type-checked at render time.",
        tags: tags("crossplane", "generated", "kcl"),
        annotations: common("packages/providers"),
      },
      spec: { owner, domain: domainName },
    },
    {
      apiVersion: "backstage.io/v1alpha1",
      kind: "System",
      metadata: {
        name: toolingSystem,
        title: "Platform packages",
        description: "KCL packages that render manifests or shared schemas rather than Crossplane Compositions.",
        tags: tags("kcl", "platform"),
        annotations: common("packages"),
      },
      spec: { owner, domain: domainName },
    },
  );

  // One API per XRD. spec.definition is a $text placeholder rather than an
  // inlined copy of the schema: Backstage resolves it at ingestion, so the API
  // page always shows the XRD as committed and this file stays reviewable.
  for (const xrd of ws.xrds) {
    const usage = usageByKind.get(xrd.xrKind)!;
    entities.push({
      apiVersion: "backstage.io/v1alpha1",
      kind: "API",
      metadata: {
        name: apiName(xrd),
        title: `${xrd.xrKind} (${xrd.apiVersion})`,
        description: xrd.description || `${xrd.xrKind} composite resource.`,
        tags: tags("crossplane", "xrd", xrd.module, ...usage.backends),
        annotations: {
          ...common(xrd.root),
          "platform.example.org/xr-kind": xrd.xrKind,
          "platform.example.org/xr-api-version": xrd.apiVersion,
          "platform.example.org/xr-scope": xrd.scope,
          "platform.example.org/backends": usage.backends.join(", ") || "none",
          "platform.example.org/usage-count": String(usage.total),
          "platform.example.org/usages": `${usage.compositions.length} composition(s), ${usage.examples} example(s), ${usage.childOf.length} parent composite(s), ${usage.devkitRows} devkit row(s)`,
          "platform.example.org/kcl-package": xrd.package,
          ...findingAnnotation(xrd.xrKind),
        },
        links: [{ url: `${blob}/${xrd.file}`, title: "XRD" }],
      },
      spec: {
        type: "crossplane-xrd",
        // Every XRD in the tree is served at a v1alpha1-style version; a
        // portal that called them production would be lying about the API
        // stability its own group name declares.
        lifecycle: xrd.apiVersion.includes("alpha") ? "experimental" : "production",
        owner,
        system: entityName(xrd.module),
        definition: { $text: `${blob}/${xrd.file}` },
      },
    });
  }

  // One Component per Composition package: the implementation of an API on one
  // backend. providesApis is the XRD it composes; consumesApis are the child
  // XRs it renders (a composite of composites); dependsOn are the generated
  // provider schema packages it imports.
  for (const comp of ws.compositions) {
    const pkg = pkgByName.get(comp.package);
    const xrd = xrdByKind.get(comp.compositeKind);
    const consumes = comp.childKinds
      .map((k) => xrdByKind.get(k))
      .filter((x) => x !== undefined)
      .map((x) => `api:default/${apiName(x)}`);
    entities.push({
      apiVersion: "backstage.io/v1alpha1",
      kind: "Component",
      metadata: {
        name: entityName(comp.package),
        title: comp.package,
        description: `Composition of ${comp.compositeKind}${comp.backend ? ` on ${comp.backend}` : ""}, rendered by ${comp.functions.join(" → ") || "function-kcl"}.`,
        tags: tags("crossplane", "composition", comp.backend, comp.module),
        annotations: {
          ...common(comp.root),
          "platform.example.org/kcl-package": comp.package,
          "platform.example.org/composite-kind": comp.compositeKind,
          "platform.example.org/backend": comp.backend || "single-implementation",
          "platform.example.org/oci-image": comp.sourceImage,
          "platform.example.org/composition-pin": comp.pinnedTag || "unpinned",
          "platform.example.org/package-version": comp.packageVersion,
          "platform.example.org/child-xrs": comp.childKinds.join(", ") || "none",
          "platform.example.org/usage-count": String((pkg?.dependents.length ?? 0) + comp.childKinds.length),
          ...findingAnnotation(comp.package),
        },
        links: [
          { url: `${blob}/${comp.file}`, title: "Composition" },
          { url: `${tree}/${comp.root}`, title: "Module" },
        ],
      },
      spec: {
        type: "crossplane-composition",
        lifecycle: "experimental",
        owner,
        system: entityName(pkg?.module || xrd?.module || toolingSystem),
        ...(xrd ? { providesApis: [`api:default/${apiName(xrd)}`] } : {}),
        ...(consumes.length > 0 ? { consumesApis: consumes } : {}),
        ...(pkg && pkg.pathDeps.length > 0
          ? { dependsOn: pkg.pathDeps.map((d) => `component:default/${entityName(d)}`) }
          : {}),
      },
    });
  }

  // Every other KCL package is a Component too: without them the dependency
  // graph stops at the Composition and the provider schema fan-in — the thing
  // a refactor actually needs to see — is invisible.
  for (const pkg of ws.packages) {
    if (pkg.kind === "function") continue;
    const xrd = ws.xrds.find((x) => x.package === pkg.name);
    const system = xrd ? entityName(xrd.module) : pkg.kind === "provider" ? providerSystem : toolingSystem;
    const type = pkg.kind === "provider" ? "kcl-provider-schema" : pkg.kind === "xrd" ? "crossplane-xrd-package" : pkg.kind === "cli" ? "kcl-manifest-package" : "kcl-library";
    entities.push({
      apiVersion: "backstage.io/v1alpha1",
      kind: "Component",
      metadata: {
        name: entityName(pkg.name),
        title: pkg.name,
        description: `${type} ${pkg.name} ${pkg.version}, imported by ${pkg.dependents.length} package(s).`,
        tags: tags("kcl", pkg.kind, pkg.area, pkg.module),
        annotations: {
          ...common(pkg.root),
          "platform.example.org/kcl-package": pkg.name,
          "platform.example.org/package-version": pkg.version,
          "platform.example.org/usage-count": String(pkg.dependents.length),
          "platform.example.org/usages": pkg.dependents.join(", ") || "none",
          "platform.example.org/has-tests": String(pkg.hasTests),
          ...findingAnnotation(pkg.name),
        },
      },
      spec: {
        type,
        lifecycle: "experimental",
        owner,
        system,
        ...(xrd ? { providesApis: [`api:default/${apiName(xrd)}`] } : {}),
        ...(pkg.pathDeps.length > 0 ? { dependsOn: pkg.pathDeps.map((d) => `component:default/${entityName(d)}`) } : {}),
      },
    });
  }

  // One Resource per example XR: the only instances this repo can prove exist.
  // They are what "how is this used" looks like for someone who has never
  // claimed one — a working spec, with the backend it selects.
  for (const ex of ws.examples) {
    const xrd = xrdByKind.get(ex.kind);
    const impl = ws.compositions.find((c) => c.compositeKind === ex.kind && (!ex.backend || c.backend === ex.backend));
    entities.push({
      apiVersion: "backstage.io/v1alpha1",
      kind: "Resource",
      metadata: {
        // One example file can hold several XRs (the gcp-platform
        // WorkloadIdentity set is seven), so the XR's own name is part of the
        // entity name; the file stem alone would collide.
        name: entityName(`xr-${ex.module}-${ex.file.slice(ex.file.lastIndexOf("/") + 1).replace(/\.ya?ml$/, "")}-${ex.name}`),
        title: `${ex.kind}/${ex.name}`,
        description: `Example ${ex.kind}${ex.backend ? ` on ${ex.backend}` : ""} (${ex.file}).`,
        tags: tags("crossplane", "example", ex.module, ex.backend),
        annotations: {
          ...common(ex.file.slice(0, ex.file.lastIndexOf("/"))),
          "platform.example.org/xr-api-version": ex.apiVersion,
          "platform.example.org/xr-kind": ex.kind,
          "platform.example.org/backend": ex.backend || "default",
        },
        links: [{ url: `${blob}/${ex.file}`, title: "Example XR" }],
      },
      spec: {
        type: "crossplane-xr",
        owner,
        system: entityName(ex.module),
        ...(xrd ? { dependsOn: [`api:default/${apiName(xrd)}`] } : {}),
        ...(impl ? { dependencyOf: [`component:default/${entityName(impl.package)}`] } : {}),
      },
    });
  }

  return entities;
}

// ── the human view ───────────────────────────────────────────────────────────

const mermaidId = (raw: string): string => raw.replace(/[^A-Za-z0-9_]/g, "_");

function capabilityDiagram(ws: Workspace, usageByKind: Map<string, Usage>): string {
  const lines = ["```mermaid", "flowchart LR"];
  const areas = [...new Set(ws.xrds.map((x) => x.root.split("/")[1] ?? ""))].sort();
  for (const area of areas) {
    lines.push(`  subgraph ${mermaidId(area)}["packages/${area}"]`);
    for (const xrd of ws.xrds.filter((x) => (x.root.split("/")[1] ?? "") === area)) {
      const usage = usageByKind.get(xrd.xrKind)!;
      lines.push(`    ${mermaidId(xrd.xrKind)}(["${xrd.xrKind}<br/>${usage.total} uses"])`);
      for (const comp of usage.compositions) {
        lines.push(`    ${mermaidId(comp)}["${comp}"]`);
        lines.push(`    ${mermaidId(xrd.xrKind)} --> ${mermaidId(comp)}`);
      }
    }
    lines.push("  end");
  }
  // Child edges cross modules, so they are drawn after every subgraph closes.
  for (const comp of ws.compositions) {
    for (const child of comp.childKinds) {
      lines.push(`  ${mermaidId(comp.package)} -.->|composes| ${mermaidId(child)}`);
    }
  }
  lines.push("```");
  return lines.join("\n");
}

function usageTable(ws: Workspace): string {
  const rows = [...ws.usage].sort((a, b) => b.total - a.total || a.xrKind.localeCompare(b.xrKind));
  const out = [
    "| XR kind | module | backends | compositions | examples | composed by | devkit rows | uses |",
    "|---|---|---|---|---|---|---|---|",
  ];
  for (const u of rows) {
    const xrd = ws.xrds.find((x) => x.xrKind === u.xrKind)!;
    out.push(
      `| \`${u.xrKind}\` | ${xrd.module} | ${u.backends.join(", ") || "—"} | ${u.compositions.length} | ${u.examples} | ${u.childOf.join(", ") || "—"} | ${u.devkitRows} | **${u.total}** |`,
    );
  }

  return out.join("\n");
}

function providerTable(packages: KclPackage[]): string {
  const providers = packages
    .filter((p) => p.kind === "provider")
    .sort((a, b) => b.dependents.length - a.dependents.length || a.name.localeCompare(b.name));
  const out = ["| provider schema | importers | imported by |", "|---|---|---|"];
  for (const p of providers) {
    out.push(`| \`${p.name}\` | ${p.dependents.length} | ${p.dependents.join(", ") || "—"} |`);
  }
  return out.join("\n");
}

function childTable(compositions: CompositionInfo[]): string {
  const parents = compositions.filter((c) => c.childKinds.length > 0);
  if (parents.length === 0) return "None: every Composition renders managed resources only.";
  const out = ["| composition | composite | child XRs |", "|---|---|---|"];
  for (const c of parents) {
    out.push(`| \`${c.package}\` | \`${c.compositeKind}\` | ${c.childKinds.map((k) => `\`${k}\``).join(", ")} |`);
  }
  return out.join("\n");
}

function findingTable(findings: Finding[]): string {
  if (findings.length === 0) return "None.";
  const out = ["| severity | rule | subject | suggestion | evidence |", "|---|---|---|---|---|"];
  for (const f of findings) {
    out.push(`| ${f.severity} | \`${f.rule}\` | \`${f.subject}\` | ${f.detail} | \`${f.evidence}\` |`);
  }
  return out.join("\n");
}

export function buildGraphDoc(ws: Workspace): string {
  const usageByKind = new Map(ws.usage.map((u) => [u.xrKind, u]));
  const counts = {
    high: ws.findings.filter((f) => f.severity === "high").length,
    medium: ws.findings.filter((f) => f.severity === "medium").length,
    low: ws.findings.filter((f) => f.severity === "low").length,
  };
  return `# Crossplane estate

<!-- GENERATED by \`just crossplane-catalog\` (tools/catalog/src/catalog.ts) from packages/**. Do not edit. -->

${ws.xrds.length} XRDs, ${ws.compositions.length} Compositions, ${ws.examples.length} example XRs and
${ws.packages.filter((p) => p.kind === "provider").length} generated provider schema packages, scanned from
\`packages/**\`. The same model is served to Backstage as \`catalog/crossplane.yaml\` and to
agents over MCP (\`just mcp\`).

## Capabilities

A rounded node is an XRD (the portable API) with its total use count; a box is the
Composition that implements it on one backend. A dashed edge is a composite of
composites: a Composition that renders another XR instead of a managed resource.

${capabilityDiagram(ws, usageByKind)}

## Usage

\`uses\` = Compositions implementing the API + example XRs + Compositions that render it
as a child. \`devkit rows\` is how many \`devkit.toml\` rows install the module, i.e.
whether the e2e cluster ever sees it.

${usageTable(ws)}

## Composites of composites

${childTable(ws.compositions)}

## Provider schema fan-in

Generated packages under \`packages/providers\`, by how many Compositions import them
(\`kcl.mod\` \`path = "…"\` deps — the edges nx draws).

${providerTable(ws.packages)}

## Refactor findings

${counts.high} high, ${counts.medium} medium, ${counts.low} low. Every row is produced by a rule in
\`tools/catalog/src/findings.ts\` and names the file that proves it.

${findingTable(ws.findings)}
`;
}

function write(root: string, rel: string, content: string, check: boolean): boolean {
  const path = join(root, rel);
  if (check) {
    let current = "";
    try {
      current = readFileSync(path, "utf8");
    } catch {
      // missing artifact is stale
    }
    if (current !== content) {
      console.error(`${relative(root, path)} is stale: run \`just crossplane-catalog\``);
      return false;
    }
    return true;
  }
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
  console.log(`wrote ${rel}`);
  return true;
}

const ws = scan(repoRoot);
const entities = buildEntities(ws);
const yaml = entities.map((e) => stringifyYaml(e, { lineWidth: 0 })).join("---\n");
const header = `# GENERATED by \`just crossplane-catalog\` (tools/catalog/src/catalog.ts) from packages/**. Do not edit.\n# ${entities.length} entities: ${ws.xrds.length} XRDs, ${ws.compositions.length} Compositions, ${ws.examples.length} example XRs, ${ws.packages.length} KCL packages.\n`;

const check = process.argv.includes("--check");
const ok = [write(ws.root, entitiesOut, header + yaml, check), write(ws.root, graphOut, buildGraphDoc(ws), check)];
if (!ok.every(Boolean)) process.exit(1);
