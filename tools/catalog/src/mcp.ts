/**
 * MCP server exposing this workspace's Crossplane estate — the same scan that
 * generates catalog/crossplane.yaml and docs/crossplane-graph.md — plus the
 * GitHub and Jira activity around it.
 *
 * JSON-RPC 2.0 over stdio, newline-delimited, no dependencies: the whole
 * protocol surface an editor needs is `initialize`, `tools/list`, `tools/call`,
 * `resources/list`, `resources/read` and `ping`, which is less code than
 * wiring an SDK. stdout carries protocol frames only — every log line goes to
 * stderr, because one stray `console.log` corrupts the stream and the client
 * drops the connection with no useful error.
 *
 *   node tools/catalog/src/mcp.ts        # speaks MCP on stdin/stdout
 *   just mcp                             # same thing
 *
 * Client entry (Claude Code / Cursor / any mcpServers map):
 *
 *   {
 *     "mcpServers": {
 *       "kcl-packages-catalog": {
 *         "command": "node",
 *         "args": ["tools/catalog/src/mcp.ts"],
 *         "cwd": "/absolute/path/to/kcl-packages",
 *         "env": {
 *           "JIRA_BASE_URL": "https://your-site.atlassian.net",
 *           "JIRA_EMAIL": "you@example.com",
 *           "JIRA_API_TOKEN": "…",
 *           "JIRA_PROJECT_KEY": "PLAT"
 *         }
 *       }
 *     }
 *   }
 *
 * The Jira env block is optional; without it only `jira_issues` fails, and it
 * fails loudly. GitHub tools need an authenticated `gh` CLI (`gh auth login`).
 */
import { readFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { repoRoot, scan } from "./scan.ts";
import type { Finding, Usage, Workspace } from "./scan.ts";
import { issues, pullRequests } from "./github.ts";
import { jiraIssues } from "./jira.ts";

const SERVER_NAME = "kcl-packages-catalog";
const SERVER_VERSION = "0.1.0";
const REPO_SLUG_FALLBACK = "slavalslutkovsky/kcl-packages";
/** Protocol revisions this server implements; the first is what it prefers. */
const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];

const log = (msg: string): void => void process.stderr.write(`[${SERVER_NAME}] ${msg}\n`);

/**
 * The scan walks 133 package directories and parses every XRD, Composition and
 * example XR. That is ~a second, and the answer cannot change while the
 * process lives, so it is done on first use and kept.
 */
let cached: Workspace | undefined;
function workspace(): Workspace {
  if (!cached) {
    const started = Date.now();
    cached = scan();
    log(`scanned ${cached.packages.length} packages in ${Date.now() - started}ms`);
  }
  return cached;
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v.trim() !== "" ? v.trim() : undefined);

/** Tool args arrive from an LLM: a number may be a numeric string. */
function num(v: unknown, fallback: number): number {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

interface Tool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  run: (args: Record<string, unknown>) => unknown | Promise<unknown>;
}

/**
 * The slice of the estate matching a module and/or XR kind: the XRDs that
 * define the API, the Compositions that implement it (each already carrying
 * its backend and the child XRs it composes), and the KCL dependency edges
 * between the packages involved. Everything is name-matched case-insensitively
 * because callers type `Bucket`, `bucket` and `BUCKET` interchangeably.
 */
function graph(module: string | undefined, kind: string | undefined): unknown {
  const ws = workspace();
  const m = module?.toLowerCase();
  const k = kind?.toLowerCase();
  const byName = new Map(ws.packages.map((p) => [p.name, p]));

  const xrds = ws.xrds.filter((x) => (!m || x.module.toLowerCase() === m) && (!k || x.xrKind.toLowerCase() === k));
  const compositions = ws.compositions.filter((c) => {
    const pkgModule = (byName.get(c.package)?.module ?? "").toLowerCase();
    const moduleHit = !m || pkgModule === m;
    const kindHit = !k || c.compositeKind.toLowerCase() === k || c.childKinds.some((ck) => ck.toLowerCase() === k);
    return moduleHit && kindHit;
  });

  const scope = new Set<string>([...xrds.map((x) => x.package), ...compositions.map((c) => c.package)]);
  const edges: { from: string; to: string }[] = [];
  for (const name of scope) {
    for (const dep of byName.get(name)?.pathDeps ?? []) edges.push({ from: name, to: dep });
  }
  const packages = [...scope]
    .map((name) => byName.get(name))
    .filter((p) => p !== undefined)
    .map((p) => ({ name: p.name, kind: p.kind, area: p.area, module: p.module, version: p.version, root: p.root, pathDeps: p.pathDeps, dependents: p.dependents }));

  return { filter: { module: module ?? null, kind: kind ?? null }, xrds, compositions, packages, edges };
}

const tools: Tool[] = [
  {
    name: "crossplane_graph",
    description: "Crossplane XRDs, Compositions (with backend and composed child XRs) and KCL package dependency edges, optionally narrowed to one capability module or one XR kind.",
    inputSchema: {
      type: "object",
      properties: {
        module: { type: "string", description: "Capability module directory, e.g. 'bucket' or 'cluster'. Omit for the whole estate." },
        kind: { type: "string", description: "Composite resource kind, e.g. 'Bucket'. Matches the XRD kind and any Composition that composes it as a child." },
      },
      additionalProperties: false,
    },
    run: (args) => graph(str(args.module), str(args.kind)),
  },
  {
    name: "crossplane_usage",
    description: "How heavily each composite resource kind is used: implementing Compositions, backends, example XRs, parent XRs that compose it, and devkit rows. Sorted by total usage descending.",
    inputSchema: {
      type: "object",
      properties: { xrKind: { type: "string", description: "Restrict to one composite kind, e.g. 'Bucket'." } },
      additionalProperties: false,
    },
    run: (args) => {
      const want = str(args.xrKind)?.toLowerCase();
      const rows: Usage[] = workspace().usage.filter((u) => !want || u.xrKind.toLowerCase() === want);
      return [...rows].sort((a, b) => b.total - a.total || a.xrKind.localeCompare(b.xrKind));
    },
  },
  {
    name: "refactor_findings",
    description: "Consistency and refactor findings raised by the catalog scan (unpinned Composition images, backend parity gaps, missing tests, orphaned XRDs, …).",
    inputSchema: {
      type: "object",
      properties: {
        severity: { type: "string", enum: ["high", "medium", "low"], description: "Only findings at this severity." },
        rule: { type: "string", description: "Only findings from this rule id." },
      },
      additionalProperties: false,
    },
    run: (args) => {
      const severity = str(args.severity)?.toLowerCase();
      const rule = str(args.rule)?.toLowerCase();
      const rows: Finding[] = workspace().findings;
      return rows.filter((f) => (!severity || f.severity === severity) && (!rule || f.rule.toLowerCase() === rule));
    },
  },
  {
    name: "github_pull_requests",
    description: "Recent pull requests on this repository in any state, with their latest review per reviewer. Requires an authenticated `gh` CLI.",
    inputSchema: {
      type: "object",
      properties: { limit: { type: "integer", minimum: 1, maximum: 100, description: "How many pull requests to return. Default 5." } },
      additionalProperties: false,
    },
    run: (args) => pullRequests(workspace().repoSlug || REPO_SLUG_FALLBACK, num(args.limit, 5)),
  },
  {
    name: "github_issues",
    description: "Issues on this repository with labels, assignees and comment counts. Requires an authenticated `gh` CLI.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 100, description: "How many issues to return. Default 5." },
        state: { type: "string", enum: ["open", "closed", "all"], description: "Issue state. Default 'open'." },
      },
      additionalProperties: false,
    },
    run: (args) => issues(workspace().repoSlug || REPO_SLUG_FALLBACK, num(args.limit, 5), str(args.state) ?? "open"),
  },
  {
    name: "jira_issues",
    description: "Jira Cloud issues, by default everything still open in JIRA_PROJECT_KEY ordered by last update. Requires JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN and JIRA_PROJECT_KEY.",
    inputSchema: {
      type: "object",
      properties: {
        jql: { type: "string", description: "Override the default JQL, e.g. \"project = PLAT AND labels = crossplane\"." },
        limit: { type: "integer", minimum: 1, maximum: 100, description: "How many issues to return. Default 5." },
      },
      additionalProperties: false,
    },
    run: (args) => jiraIssues({ jql: str(args.jql), limit: num(args.limit, 5) }),
  },
];

interface Resource {
  uri: string;
  name: string;
  description: string;
  mimeType: string;
  path: string;
}

/** Both resources are generated artifacts, read fresh so a regen is picked up. */
const resources: Resource[] = [
  {
    uri: "catalog://crossplane/graph",
    name: "crossplane-graph",
    description: "Generated Mermaid graph of the Crossplane estate plus usage and findings tables.",
    mimeType: "text/markdown",
    path: resolve(repoRoot, "docs/crossplane-graph.md"),
  },
  {
    uri: "catalog://crossplane/entities",
    name: "crossplane-entities",
    description: "Generated Backstage catalog entities (Domain, Systems, APIs, Components, Resources) for the Crossplane estate.",
    mimeType: "application/yaml",
    path: resolve(repoRoot, "catalog/crossplane.yaml"),
  },
];

function readResource(uri: string): { uri: string; mimeType: string; text: string } {
  const resource = resources.find((r) => r.uri === uri);
  if (!resource) throw new Error(`unknown resource ${uri}; available: ${resources.map((r) => r.uri).join(", ")}`);
  let text: string;
  try {
    text = readFileSync(resource.path, "utf8");
  } catch {
    throw new Error(`${relative(repoRoot, resource.path)} does not exist yet — run \`just crossplane-catalog\` to generate it.`);
  }
  return { uri, mimeType: resource.mimeType, text };
}

/**
 * The single boundary type for an inbound frame. Every field is optional and
 * the interesting leaves are `unknown`, so reading one still forces a check —
 * the client is untrusted, and `params` differs per method.
 */
interface Request {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: {
    protocolVersion?: unknown;
    clientInfo?: { name?: unknown };
    name?: unknown;
    arguments?: Record<string, unknown>;
    uri?: unknown;
  };
}

/** JSON-RPC errors carry a code; plain Errors from a handler are -32603. */
class RpcError extends Error {
  code: number;
  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

const send = (msg: unknown): void => void process.stdout.write(`${JSON.stringify(msg)}\n`);

async function dispatch(req: Request): Promise<unknown> {
  const params = req.params ?? {};
  switch (req.method) {
    case "initialize": {
      const asked = typeof params.protocolVersion === "string" ? params.protocolVersion : "";
      const client = typeof params.clientInfo?.name === "string" ? params.clientInfo.name : "unknown client";
      log(`initialize from ${client} (protocol ${asked || "unspecified"})`);
      return {
        protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
        capabilities: { tools: {}, resources: {} },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      };
    }
    case "ping":
      return {};
    case "tools/list":
      return { tools: tools.map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })) };
    case "tools/call": {
      const name = typeof params.name === "string" ? params.name : "";
      const tool = tools.find((t) => t.name === name);
      if (!tool) throw new RpcError(-32602, `unknown tool ${name || "(missing name)"}; available: ${tools.map((t) => t.name).join(", ")}`);
      const args = params.arguments ?? {};
      try {
        const result = await tool.run(args);
        return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
      } catch (err) {
        // A tool that cannot reach GitHub/Jira is a tool-level failure the
        // model should read and act on, not a protocol error that kills the
        // call, so it comes back as content with isError.
        const message = err instanceof Error ? err.message : String(err);
        log(`tool ${name} failed: ${message}`);
        return { content: [{ type: "text", text: message }], isError: true };
      }
    }
    case "resources/list":
      return { resources: resources.map((r) => ({ uri: r.uri, name: r.name, description: r.description, mimeType: r.mimeType })) };
    case "resources/read": {
      const uri = typeof params.uri === "string" ? params.uri : "";
      try {
        return { contents: [readResource(uri)] };
      } catch (err) {
        throw new RpcError(-32002, err instanceof Error ? err.message : String(err));
      }
    }
    default:
      throw new RpcError(-32601, `method not found: ${req.method}`);
  }
}

async function handle(line: string): Promise<void> {
  let req: Request;
  try {
    // Boundary cast: shape is unvalidated on purpose, every field is optional.
    req = JSON.parse(line) as Request;
  } catch {
    send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error: line is not JSON" } });
    return;
  }
  // No id means a notification: `notifications/initialized` and friends are
  // acknowledged by silence, and answering them is a protocol violation.
  const isNotification = req.id === undefined || req.id === null;
  try {
    const result = await dispatch(req);
    if (!isNotification) send({ jsonrpc: "2.0", id: req.id, result });
  } catch (err) {
    if (isNotification) return;
    const code = err instanceof RpcError ? err.code : -32603;
    send({ jsonrpc: "2.0", id: req.id, error: { code, message: err instanceof Error ? err.message : String(err) } });
  }
}

// Requests are handled one at a time through this chain: the scan is a shared
// lazily-built value, and serialising keeps responses in request order, which
// matters for clients that assume it.
let queue: Promise<void> = Promise.resolve();
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk: string) => {
  buffer += chunk;
  let nl = buffer.indexOf("\n");
  while (nl !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (line !== "") queue = queue.then(() => handle(line));
    nl = buffer.indexOf("\n");
  }
});
process.stdin.on("end", () => {
  const rest = buffer.trim();
  if (rest !== "") queue = queue.then(() => handle(rest));
  queue = queue.then(() => process.exit(0));
});
log(`ready on stdio (${tools.length} tools, ${resources.length} resources)`);
