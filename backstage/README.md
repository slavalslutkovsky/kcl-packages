# `backstage/` — portal wiring for the Crossplane estate

This repo has no Backstage app. It has a **generator** (`tools/catalog`) and a
**config fragment** (this directory) for an app that already exists —
`packages/manager/examples/values.yaml` installs the stock `backstage` 2.10.1
chart, and a chart's image cannot grow plugins. Adding the cards below means
editing that app's `package.json` and `EntityPage.tsx`; this directory tells you
exactly what to add and what config it needs.

| file | role |
|---|---|
| `app-config.crossplane.yaml` | drop-in config: catalog Locations + rules, GitHub integration, Jira proxy, every XR plural for the Kubernetes plugin, the rag-ai `ai:` block |
| `mcp.json` | MCP client config for `tools/catalog/src/mcp.ts` — the same data, for agents instead of browsers |
| `README.md` | this file |

The generator writes exactly two artifacts, both committed:

| artifact | contents |
|---|---|
| `catalog/crossplane.yaml` | Backstage entities: one `Domain`, one `System` per capability module, one `API` per XRD (`spec.definition` is a `$text` placeholder pointing at the committed `xrd.yaml`, so the API page always shows the XRD as it is on `main` and the entity file stays reviewable), one `Component` per Composition package and per KCL package, one `Resource` per example XR — 261 entities today |
| `docs/crossplane-graph.md` | generated Mermaid graph of XRD → Composition → child XR, the usage table, the refactor findings table |

Nothing else is generated. `just crossplane-catalog` rewrites both;
`just crossplane-catalog-check` fails if they are stale, which is what CI runs.

## Using the fragment

Backstage takes repeated `--config`:

```
backstage-backend --config app-config.yaml --config app-config.crossplane.yaml
```

Configs deep-merge per key but **replace** arrays. If your app already declares
`catalog.locations`, `proxy.endpoints` or `kubernetes.customResources`, merge
those lists by hand rather than stacking two files.

`catalog.rules` is not decoration: the default rules do not include `Resource`,
so without the `allow` list the example-XR entities are rejected at ingestion
with a "not allowed" error, not silently skipped.

## Plugins to add

Versions below were resolved with `npm view <pkg> version` on 2026-09-20.

| package | version | card / what it shows |
|---|---|---|
| `@roadiehq/backstage-plugin-github-pull-requests` | 3.7.1 | latest PRs with review state, per entity, from `github.com/project-slug`; `EntityGithubPullRequestsOverviewCard` for the overview tab, `EntityGithubPullRequestsContent` for a full tab. Cap it at 5 with the card's own props; `roadie-backstage-pull-requests/default-filter` on an entity sets a default GitHub search filter |
| `@backstage-community/plugin-github-issues` | 1.4.0 | open issues per entity, ordered by `UPDATED_AT DESC`; `GithubIssuesCard` takes `itemsPerPage` / `filterBy` props, so "5 open issues" is a prop, not config. **`@roadiehq/backstage-plugin-github-issues` does not exist on npm** — the issues card lives in the community collection (`@backstage/plugin-github-issues` 0.4.2 is the pre-move name) |
| `@roadiehq/backstage-plugin-jira` | 2.14.0 | `EntityJiraOverviewCard` — issue counts by type and an activity stream for the entity's `jira/project-key`, through the proxy endpoint in the fragment |
| `@backstage/plugin-kubernetes` | 0.12.23 | the Kubernetes tab: live XRs, for the 31 custom resources declared in the fragment |
| `@backstage/plugin-kubernetes-backend` | 0.21.11 | the backend half of the above; the frontend plugin is useless without it |
| `@roadiehq/rag-ai` | 1.3.0 | the ask-a-question UI (sidebar / page) |
| `@roadiehq/rag-ai-backend` | 3.0.1 | the RAG backend; `supportedSources: ['catalog']` makes the generated entities the corpus |
| `@roadiehq/rag-ai-node` | 0.4.0 | shared types both halves import |
| `@roadiehq/rag-ai-backend-retrieval-augmenter` | 2.0.2 | the default retrieval pipeline `rag-ai-backend` requires as an argument |
| `@roadiehq/rag-ai-backend-embeddings-openai` | 0.8.0 | the embeddings module. **`@roadiehq/rag-ai-backend-embeddings-catalog` does not exist** — "catalog" is a *source* (`ai.supportedSources`), embeddings modules are per provider: this one, or `@roadiehq/rag-ai-backend-embeddings-aws` 2.1.0 for Bedrock |
| `@roadiehq/rag-ai-storage-pgvector` | 3.0.1 | vector store in Backstage's own Postgres; needs the `vector` and `uuid-ossp` extensions |

rag-ai ships with a warning from its authors that it is a reference
implementation under minimal maintenance; a community fork exists
(`@alithya-oss/backstage-plugin-rag-ai-backend`). The fragment targets the Roadie
packages above because they are the ones whose config schema it matches. The MCP
server here covers the same ground for agents, so the portal half is the
optional one.

## Annotations

The emitter writes these; nothing has to be hand-maintained per entity:

| annotation | on | used by |
|---|---|---|
| `backstage.io/source-location` | every entity | the "view source" link, and how the GitHub plugins resolve which host/repo an entity belongs to |
| `github.com/project-slug` | every entity (`slavalslutkovsky/kcl-packages`) | PR card, issues card |
| `jira/project-key` | every entity | the Jira card |
| `platform.example.org/usage-count`, `/usages` | XRD APIs, Composition Components | how often a capability is actually referenced (compositions + backends + examples + child XRs + devkit rows) |
| `platform.example.org/backends` / `/backend` | XRD APIs / Composition Components | which clouds implement this XR, and which one a given Composition is |
| `platform.example.org/findings` | whatever a finding is about | the refactor findings, so a problem shows on the page it belongs to |
| `platform.example.org/kcl-package` | Components | the `kcl.mod` package name, i.e. what `kcl run` and nx targets call it |
| `platform.example.org/oci-image`, `/composition-pin` | Composition Components | the published `oci://` image and the tag the Composition pins — drift between repo and cluster is visible without a cluster |

Add by hand if you want them, because they are judgement calls, not facts about
the repo: `jira/component` and `jira/label` (narrower Jira cards),
`roadie-backstage-pull-requests/default-filter` (default PR search),
`backstage.io/techdocs-ref`. Also **`backstage.io/kubernetes-id` is not written
on Crossplane entities** — that annotation is the `packages/app` /
`packages/manager` id contract (docs/backstage.md § The id contract). The
fragment declares the XR kinds so the Kubernetes plugin *can* show them, but an
entity needs a `backstage.io/kubernetes-id` or
`backstage.io/kubernetes-label-selector` of your choosing before live XRs appear
on its page.

## Environment

Backstage's half:

| var | needed by |
|---|---|
| `GITHUB_TOKEN` | `integrations.github` — private-repo Locations, PR card, issues card |
| `JIRA_BASE_URL` | the `/jira/api` proxy target, e.g. `https://acme.atlassian.net` |
| `JIRA_TOKEN` | the proxy's `Authorization: Basic …` header — **already base64 of `<email>:<api-token>`**, not the raw token |
| `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_EMBEDDINGS_MODEL` | rag-ai embeddings; `OPENAI_BASE_URL` points at any OpenAI-compatible endpoint (Ollama, vLLM, a gateway) |

The MCP server (`mcp.json`) takes the un-encoded Jira pair instead, because it
talks to Jira directly rather than through Backstage's proxy, and it reads no
GitHub variable at all — `github_pull_requests` and `github_issues` shell out to
`gh`, so the requirement there is an authenticated CLI (`gh auth login`; `gh`
itself honours `GH_TOKEN` / `GITHUB_TOKEN` if you prefer a token in the env):

| var | needed by |
|---|---|
| `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` | the `jira_issues` tool; the server builds the Basic header itself |
| `JIRA_PROJECT_KEY` | default project for Jira queries |

`mcp.json` writes `${VAR}` as the value. Clients that expand shell variables
(Claude Code, Codex) resolve them; clients that do not (Claude Desktop) need the
literal values pasted in. A missing credential or a missing `gh` is an explicit
error from the server — it never answers from sample data.

`node tools/catalog/src/mcp.ts` is the whole command: stdio, newline-delimited
JSON-RPC, no flags, `cwd` must be the repo root. It serves six tools —
`crossplane_graph`, `crossplane_usage`, `refactor_findings`,
`github_pull_requests`, `github_issues`, `jira_issues` — and two resources,
`catalog://crossplane/graph` (`docs/crossplane-graph.md`) and
`catalog://crossplane/entities` (`catalog/crossplane.yaml`), both of which tell
you to run `just crossplane-catalog` when the artifact is missing.

## Which surface answers which question

| ask | surface |
|---|---|
| what Crossplane resources exist | `catalog/crossplane.yaml` — `API` per XRD, `Component` per Composition, `Resource` per example XR |
| the graph and dependencies | entity relations (`providesApis` / `consumesApis` / `dependsOn`) drawn by Backstage's catalog graph, the Mermaid diagram in `docs/crossplane-graph.md`, and the MCP `crossplane_graph` tool |
| usage counts | `platform.example.org/usage-count` / `/usages` on the entity, the usage table in `docs/crossplane-graph.md`, and the MCP `crossplane_usage` tool |
| refactor findings | `platform.example.org/findings` on the subject entity, the findings table in `docs/crossplane-graph.md`, and the MCP `refactor_findings` tool; `just crossplane-catalog-check` keeps the artifacts current |
| latest 5 PRs with review state | `@roadiehq/backstage-plugin-github-pull-requests` card in the portal, **and** the MCP `github_pull_requests` tool for agents |
| 5 open issues | `@backstage-community/plugin-github-issues` card, **and** the MCP `github_issues` tool |
| Jira | `@roadiehq/backstage-plugin-jira` card via the `/jira/api` proxy, **and** the MCP `jira_issues` tool against the same board |
| AI over all of it | `@roadiehq/rag-ai` in the portal (catalog embeddings), and `mcp.json` for coding agents |

## What this does NOT do

- **No Backstage app in this repo.** No `packages/app`/`packages/backend`
  Backstage scaffold, no `EntityPage.tsx`, no plugin lockfile. The fragment and
  this README are instructions for an app you run elsewhere.
- **No scaffolder templates.** A Software Template is a repo of skeleton files
  plus a `template.yaml`; the entities here describe what exists.
- **No controller ingesting live XRs into the catalog.** Entities come from git
  Locations, generated from the repo. Live XR state reaches the portal only
  through the Kubernetes plugin's tab, never as catalog entities.
- **No pushing to Backstage.** The flow is render → commit → Backstage polls.
- **No secrets in git.** Every credential above is an env reference.
