/**
 * Render the cluster install DAG as Mermaid, from the two files that define it:
 *
 *   devkit.toml `[[deps]]`             what `devkit cluster deps` installs on the
 *                                      e2e Kind cluster, ordered by `wave`
 *   packages/manager values            what Flux keeps installed afterwards,
 *                                      ordered by HelmRelease `dependsOn`
 *
 * A wave is a barrier, not an edge: every row in wave N waits for all of wave
 * N-1. The diagram draws exactly that — each `wave N` node is the barrier the
 * previous wave's rows fan in to and this wave's rows fan out of — so the
 * ordering the file actually enforces is what the reader sees, not the finer
 * per-module ladder the row names suggest. Manager dependencies are real edges
 * and are drawn as such.
 *
 *   node tools/graph/src/install-graph.ts            # write docs/install-graph.md
 *   node tools/graph/src/install-graph.ts --check    # exit 1 if the doc is stale
 */
import { readFileSync, writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { parse as parseToml } from "smol-toml";
import { parse as parseYaml } from "yaml";

const root = resolve(import.meta.dirname, "../../..");
const devkitPath = resolve(root, "devkit.toml");
const managerPath = resolve(root, "packages/manager/examples/values.yaml");
const outPath = resolve(root, "docs/install-graph.md");

interface DevkitDep {
  name: string;
  repo?: string;
  chart?: string;
  version?: string;
  manifest?: string;
  wave?: number;
}

interface ManagerDep {
  name: string;
  type: "manager" | "application";
  version?: string;
  dependsOn?: string[];
}

const id = (name: string): string => name.replace(/[^A-Za-z0-9_]/g, "_");

/** Which module a devkit row belongs to: packages/<area>/<module>/… → module. */
function moduleOf(dep: DevkitDep): string {
  if (!dep.manifest) return "chart";
  const m = /^packages\/[^/]+\/([^/]+)\//.exec(dep.manifest);
  if (m) return m[1];
  if (dep.manifest.startsWith("manifests/")) return "crossplane";
  return "external";
}

function devkitLabel(dep: DevkitDep): string {
  if (dep.repo) return `${dep.name} ${dep.version ?? "*"}`;
  const m = dep.manifest ?? "";
  if (m.endsWith("/")) return `${dep.name} (dir)`;
  return dep.name;
}

const palette = ["#dbeafe", "#dcfce7", "#fef9c3", "#fce7f3", "#ede9fe", "#ffedd5", "#e0f2fe", "#f1f5f9", "#fee2e2", "#ecfccb"];

function renderDevkit(deps: DevkitDep[], overlap: Set<string>): string {
  const waves = new Map<number, DevkitDep[]>();
  for (const d of deps) {
    const w = d.wave ?? 0;
    (waves.get(w) ?? waves.set(w, []).get(w)!).push(d);
  }
  const order = [...waves.keys()].sort((a, b) => a - b);
  const modules = [...new Set(deps.map(moduleOf))];

  // A wave is a barrier, so draw it as one: every row of wave N-1 fans in to
  // the `wave N` node, which fans out to every row of wave N. Subgraphs would
  // read nicer but Mermaid drops a subgraph's own layout direction as soon as
  // the subgraph has edges, and the ladder collapses into a single row.
  const lines = ["flowchart TB"];
  for (const w of order) {
    for (const d of waves.get(w)!) {
      const label = devkitLabel(d);
      const shape = d.repo ? `(["${label}"])` : d.manifest?.endsWith("/") ? `[["${label}"]]` : `["${label}"]`;
      lines.push(`  ${id(d.name)}${shape}`);
    }
  }
  for (let i = 1; i < order.length; i++) {
    const barrier = `wave${order[i]}`;
    lines.push(`  ${barrier}(("wave ${order[i]}"))`);
    for (const d of waves.get(order[i - 1])!) lines.push(`  ${id(d.name)} --> ${barrier}`);
    for (const d of waves.get(order[i])!) lines.push(`  ${barrier} --> ${id(d.name)}`);
  }
  modules.forEach((m, i) => {
    lines.push(`  classDef mod_${id(m)} fill:${palette[i % palette.length]},stroke:#64748b`);
  });
  lines.push("  classDef overlap stroke:#b3261e,stroke-width:3px");
  for (const d of deps) {
    const classes = [`mod_${id(moduleOf(d))}`];
    if (overlap.has(d.name)) classes.push("overlap");
    lines.push(`  class ${id(d.name)} ${classes.join(",")}`);
  }
  return lines.join("\n");
}

function renderManager(deps: ManagerDep[], overlap: Set<string>): string {
  const lines = ["flowchart LR"];
  lines.push('  flux2{{"flux2 (devkit wave 0)"}}');
  for (const d of deps) {
    lines.push(`  ${id(d.name)}(["${d.name} ${d.version ?? "*"}"])`);
  }
  for (const d of deps) {
    const on = d.dependsOn ?? [];
    if (on.length === 0) lines.push(`  flux2 -.-> ${id(d.name)}`);
    for (const dep of on) lines.push(`  ${id(dep)} --> ${id(d.name)}`);
  }
  lines.push("  classDef type_manager fill:#dbeafe,stroke:#64748b");
  lines.push("  classDef type_application fill:#dcfce7,stroke:#64748b");
  lines.push("  classDef overlap stroke:#b3261e,stroke-width:3px");
  for (const d of deps) {
    const classes = [`type_${d.type}`];
    if (overlap.has(d.name)) classes.push("overlap");
    lines.push(`  class ${id(d.name)} ${classes.join(",")}`);
  }
  return lines.join("\n");
}

function render(): string {
  const devkit = parseToml(readFileSync(devkitPath, "utf8")) as { deps?: DevkitDep[] };
  const manager = parseYaml(readFileSync(managerPath, "utf8")) as { dependencies?: ManagerDep[] };
  const devkitDeps = devkit.deps ?? [];
  const managerDeps = manager.dependencies ?? [];

  const helmByName = new Set(devkitDeps.filter((d) => d.repo).map((d) => d.name));
  const overlap = new Set(managerDeps.map((d) => d.name).filter((n) => helmByName.has(n)));

  const rel = (p: string) => relative(root, p);
  const out = [
    "# Install graph",
    "",
    `<!-- GENERATED by \`just graph\` from ${rel(devkitPath)} and ${rel(managerPath)}. Do not edit. -->`,
    "",
    "## `devkit cluster deps` — waves",
    "",
    `Rows from \`${rel(devkitPath)}\`. Stadium = Helm chart, box = manifest, double box = directory of`,
    "manifests. Colour = module (`packages/*/<module>/`). A wave is a barrier: every row of a wave",
    "waits for the whole previous wave (the circle it fans in to), and one failed row aborts every",
    "later wave. The file has no finer edges than this.",
    "",
    "```mermaid",
    renderDevkit(devkitDeps, overlap),
    "```",
    "",
    "## `manager` — Flux `dependsOn`",
    "",
    `Charts from \`${rel(managerPath)}\`, edges are \`HelmRelease.spec.dependsOn\`. Dotted edges are the`,
    "implicit root: helm-controller (installed by devkit wave 0) must exist before any of these reconcile.",
    "Blue = `type: manager` (manager clusters only — what manages other clusters and cloud resources),",
    "green = `type: application` (every cluster that runs apps; a manager cluster too). `role: workload`",
    "renders green only, so an application chart never depends on a manager one.",
    "",
    "```mermaid",
    renderManager(managerDeps, overlap),
    "```",
    "",
  ];
  if (overlap.size > 0) {
    out.push(
      "## Conflicts",
      "",
      "Installed by both devkit (helm CLI) and manager (helm-controller); the two fight over the release.",
      "Outlined in red above.",
      "",
      ...[...overlap].map((n) => `- \`${n}\``),
      "",
    );
  }
  return out.join("\n");
}

const check = process.argv.includes("--check");
const next = render();
if (check) {
  let current = "";
  try {
    current = readFileSync(outPath, "utf8");
  } catch {
    // missing doc is stale
  }
  if (current !== next) {
    console.error(`${relative(root, outPath)} is stale: run \`just graph\``);
    process.exit(1);
  }
} else {
  writeFileSync(outPath, next);
  console.log(`wrote ${relative(root, outPath)}`);
}
