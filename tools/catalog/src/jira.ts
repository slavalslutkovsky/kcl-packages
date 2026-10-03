/**
 * Jira Cloud issues for the catalog MCP server.
 *
 * Plain `fetch` against the Cloud REST API rather than a client library: the
 * whole surface used here is one search call. Credentials come from the
 * environment — an Atlassian API token is a user secret and must never be
 * committed or defaulted.
 *
 *   JIRA_BASE_URL     https://<site>.atlassian.net
 *   JIRA_EMAIL        Atlassian account email (Basic auth username)
 *   JIRA_API_TOKEN    https://id.atlassian.com/manage-profile/security/api-tokens
 *   JIRA_PROJECT_KEY  default project for the default JQL, e.g. PLAT
 *
 * `/rest/api/3/search` is deprecated on Cloud; `/rest/api/3/search/jql` is the
 * replacement and is the only search endpoint called here.
 */

export interface JiraIssue {
  key: string;
  summary: string;
  status: string;
  assignee: string;
  updated: string;
  url: string;
}

interface JiraSearchResponse {
  issues?: {
    key: string;
    fields?: {
      summary?: string;
      status?: { name?: string } | null;
      assignee?: { displayName?: string; emailAddress?: string } | null;
      updated?: string;
    } | null;
  }[];
}

const REQUIRED = ["JIRA_BASE_URL", "JIRA_EMAIL", "JIRA_API_TOKEN", "JIRA_PROJECT_KEY"] as const;

/**
 * Issues matching `jql`, defaulting to everything still open in
 * JIRA_PROJECT_KEY, most recently touched first.
 */
export async function jiraIssues(opts: { jql?: string; limit?: number }): Promise<JiraIssue[]> {
  const missing = REQUIRED.filter((name) => !process.env[name]?.trim());
  if (missing.length > 0) {
    throw new Error(`Jira is not configured: ${missing.join(", ")} ${missing.length === 1 ? "is" : "are"} unset. Set ${REQUIRED.join(", ")} in the environment (API token: https://id.atlassian.com/manage-profile/security/api-tokens).`);
  }

  const base = process.env.JIRA_BASE_URL!.trim().replace(/\/+$/, "");
  const email = process.env.JIRA_EMAIL!.trim();
  const token = process.env.JIRA_API_TOKEN!.trim();
  const project = process.env.JIRA_PROJECT_KEY!.trim();

  const jql = opts.jql?.trim() || `project = ${project} AND statusCategory != Done ORDER BY updated DESC`;
  const url = new URL(`${base}/rest/api/3/search/jql`);
  url.searchParams.set("jql", jql);
  url.searchParams.set("maxResults", String(opts.limit ?? 5));
  // Ask for exactly the fields the JiraIssue shape needs; the default response
  // carries every field on the issue, which is megabytes on a busy project.
  url.searchParams.set("fields", "summary,status,assignee,updated");

  const res = await fetch(url, {
    headers: {
      authorization: `Basic ${Buffer.from(`${email}:${token}`).toString("base64")}`,
      accept: "application/json",
    },
  });
  if (!res.ok) {
    const head = (await res.text().catch(() => "")).slice(0, 300);
    throw new Error(`Jira search failed: ${res.status} ${res.statusText} from ${url.pathname}${head ? ` — ${head}` : ""}`);
  }

  // Boundary cast: the response is validated only by the field list requested
  // above, and every read below is optional-chained and defaulted.
  const body = (await res.json()) as JiraSearchResponse;
  return (body.issues ?? []).map((issue) => ({
    key: issue.key,
    summary: issue.fields?.summary ?? "",
    status: issue.fields?.status?.name ?? "",
    assignee: issue.fields?.assignee?.displayName ?? issue.fields?.assignee?.emailAddress ?? "",
    updated: issue.fields?.updated ?? "",
    url: `${base}/browse/${issue.key}`,
  }));
}
