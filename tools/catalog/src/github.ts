/**
 * GitHub activity for the catalog MCP server, read through the `gh` CLI.
 *
 * The CLI is used instead of the REST API on purpose: `gh` already holds the
 * user's credentials (keyring / GH_TOKEN), so nothing here has to know about
 * tokens, and the repo stays free of an HTTP client dependency. The cost is a
 * hard requirement on `gh` being installed and authenticated — when it is not,
 * every function below throws with the exact command it tried and the fix.
 * Returning placeholder PRs would be worse than failing: an MCP client cannot
 * tell fabricated review state from real review state.
 */
import { execFileSync } from "node:child_process";

/** A review body is context for an LLM, not an archive; long ones are noise. */
const BODY_LIMIT = 280;

export interface Review {
  author: string;
  state: string;
  submittedAt: string;
  body: string;
}

export interface PullRequest {
  number: number;
  title: string;
  url: string;
  state: string;
  isDraft: boolean;
  author: string;
  updatedAt: string;
  reviewDecision: string;
  reviews: Review[];
}

export interface Issue {
  number: number;
  title: string;
  url: string;
  author: string;
  labels: string[];
  assignees: string[];
  createdAt: string;
  comments: number;
}

/** `gh` JSON shapes, narrowed to the fields requested below. */
interface GhActor {
  login?: string;
  name?: string;
}
interface GhReview {
  author?: GhActor | null;
  state?: string;
  submittedAt?: string;
  body?: string;
}
interface GhPullRequest {
  number: number;
  title?: string;
  url?: string;
  state?: string;
  isDraft?: boolean;
  author?: GhActor | null;
  updatedAt?: string;
  reviewDecision?: string;
  latestReviews?: GhReview[] | null;
}
interface GhIssue {
  number: number;
  title?: string;
  url?: string;
  author?: GhActor | null;
  labels?: { name?: string }[] | null;
  assignees?: GhActor[] | null;
  createdAt?: string;
  comments?: unknown[] | number | null;
}

const actor = (a: GhActor | null | undefined): string => a?.login ?? a?.name ?? "";

const trimBody = (body: string | undefined): string => {
  const text = (body ?? "").trim();
  return text.length > BODY_LIMIT ? `${text.slice(0, BODY_LIMIT - 1)}…` : text;
};

/**
 * Run `gh` and parse stdout as JSON. Both failure modes — binary missing
 * (ENOENT) and non-zero exit (almost always "not authenticated" or "repo not
 * found") — surface as one Error that quotes the command verbatim so the
 * caller can paste it into a shell.
 */
function gh<T>(args: string[]): T {
  const command = `gh ${args.join(" ")}`;
  let stdout: string;
  try {
    stdout = execFileSync("gh", args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 32 * 1024 * 1024,
    });
  } catch (err) {
    // execFileSync decorates the thrown Error with `code` (spawn errno) and
    // `stderr` (captured child output); neither is on the Error type.
    const errno = err instanceof Error && "code" in err ? err.code : undefined;
    if (errno === "ENOENT") {
      throw new Error(`\`${command}\` failed: the \`gh\` CLI is not installed or not on PATH. Install GitHub CLI (https://cli.github.com) and run \`gh auth login\`.`);
    }
    const stderr = err instanceof Error && "stderr" in err ? err.stderr : undefined;
    const detail = String(stderr ?? (err instanceof Error ? err.message : err)).trim();
    throw new Error(`\`${command}\` failed${detail ? `: ${detail}` : ""}. If this is an authentication error, run \`gh auth login\`.`);
  }
  try {
    return JSON.parse(stdout) as T;
  } catch {
    throw new Error(`\`${command}\` returned output that is not JSON: ${stdout.slice(0, 200)}`);
  }
}

const PR_FIELDS = "number,title,url,state,isDraft,author,updatedAt,reviewDecision,latestReviews";
const ISSUE_FIELDS = "number,title,url,author,labels,assignees,createdAt,comments";

/**
 * Most recent pull requests in any state. `latestReviews` is the one review
 * per reviewer that currently counts, which is what a reviewer-load or
 * "is this blocked" question needs; the full review log is not worth the bytes.
 */
export function pullRequests(slug: string, limit: number): PullRequest[] {
  const raw = gh<GhPullRequest[]>(["pr", "list", "--repo", slug, "--state", "all", "--limit", String(limit), "--json", PR_FIELDS]);
  return raw.map((pr) => ({
    number: pr.number,
    title: pr.title ?? "",
    url: pr.url ?? "",
    state: pr.state ?? "",
    isDraft: pr.isDraft === true,
    author: actor(pr.author),
    updatedAt: pr.updatedAt ?? "",
    reviewDecision: pr.reviewDecision ?? "",
    reviews: (pr.latestReviews ?? []).map((r) => ({
      author: actor(r.author),
      state: r.state ?? "",
      submittedAt: r.submittedAt ?? "",
      body: trimBody(r.body),
    })),
  }));
}

export function issues(slug: string, limit: number, state = "open"): Issue[] {
  const raw = gh<GhIssue[]>(["issue", "list", "--repo", slug, "--state", state, "--limit", String(limit), "--json", ISSUE_FIELDS]);
  return raw.map((issue) => ({
    number: issue.number,
    title: issue.title ?? "",
    url: issue.url ?? "",
    author: actor(issue.author),
    labels: (issue.labels ?? []).map((l) => l.name ?? "").filter(Boolean),
    assignees: (issue.assignees ?? []).map(actor).filter(Boolean),
    createdAt: issue.createdAt ?? "",
    // `gh` returns the comment array here; older builds return a count.
    comments: Array.isArray(issue.comments) ? issue.comments.length : typeof issue.comments === "number" ? issue.comments : 0,
  }));
}
