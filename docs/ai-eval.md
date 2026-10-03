# AI output validation and evaluation (proposal)

Status: draft, not implemented. Nothing in `ci.yml` or `release.yml` today
validates or evaluates AI-produced output; this document proposes what would.

## Where we are

| Layer | What runs | AI-aware? |
| --- | --- | --- |
| `ci.yml` (PR, push to main) | `nx affected -t build test lint` | no |
| `release.yml` (push to main) | same targets, then `nx release` → OCI push | no |
| lefthook pre-commit / pre-push | `just fmt-files lint-files yaml-check mod-check secrets-check graph-check typecheck`, `just check` | no |
| `.claude/hooks/*` | kcl-gate, manifest-gate, guard-generated, guard-delivery on every Claude edit | yes, but local-only |

The Claude Code hooks are the only AI-specific gate, and they run on the
laptop of whoever has the session open. A change that reaches GitHub from any
other path (a different agent, a hook disabled with `LEFTHOOK=0`, a hand
edit) is checked by nothing beyond `kcl` build/test/lint. Provenance is also
invisible: none of the 68 commits on `main` carries a `Co-Authored-By`
trailer, so CI cannot tell an AI-authored change from a human one.

## What "AI output" means in this repo

Three things could be meant. The first two are in scope; the third has one
implementation and its own containment.

1. **AI-authored changes to the repo.** KCL packages, Compositions, XRDs and
   example values that Claude (or another agent) writes. This is the bulk of
   the risk and the only thing the hooks already try to cover.
2. **Rendered manifests.** Whatever `kcl run <package>` emits for the built-in
   demo and for each `examples/values-*.yaml`. The `*_test.k` suites assert
   logical contracts (70 test files), but nothing asserts the output is a
   valid Kubernetes object against the real CRD schema, or passes a policy.
3. **Runtime AI in the manager cluster.** `rust/crates/kcl-agent` (`kclx
   agent`) is the one component that calls a model: an OpenAI-compatible
   tool-calling loop over the `KclModule` service layer and the Crossplane
   composites. Its containment is structural rather than evaluative — no
   write tools unless the caller approved the run, a mandatory dry run
   (`preview_module` / `validate_resource` with `dryRun=All`) before anything
   is proposed or applied, and CRD schemas fetched with `describe_kind` so a
   hallucinated field is the API server's rejection rather than a write.
   Evaluating the *quality* of its answers is out of scope here; `.vals.yaml`
   holds the OpenAI and Anthropic refs it and `manager-secrets` draw from.

## Proposal: two stages, one always on, one opt-in

### Stage 1 — deterministic output conformance (always on)

A new `just conform` recipe that renders every hand-written package and
validates the YAML it produces. It reuses what the repo already has:

- `kcl run` for each package root, and once more per `examples/values-*.yaml`
  via `-D values=<file>`, the same invocation the package docstrings show.
- **kubeconform** against the built-in Kubernetes schemas plus the datree
  CRD catalog, which `tools/datree-crd.sh` already treats as the source of
  truth for CRDs that ship no YAML. Unknown kinds fail rather than skip, so a
  hallucinated `apiVersion` or field name is caught at the schema.
- **kyverno apply** (CLI is already installed locally via mise, 1.19) with a
  small policy set under `policies/`: pod-security baseline, required
  `app.kubernetes.io/*` labels, no `:latest` images, resource requests set,
  no `hostPath`. These are the mistakes a model makes most often when it
  guesses a manifest shape.

Wiring:

- `justfile`: `conform` (whole tree) and `conform-files <paths>` (staged
  scope), following the existing `check` / `lint-files` split.
- `lefthook.yml` pre-push: add `conform` next to `check`. Not pre-commit; it
  downloads schemas once and takes tens of seconds.
- `.github/workflows/ci.yml`: a second job `conform` that `needs: validate`
  and runs `just conform` over `nx affected` projects only.
- `.github/workflows/release.yml`: run `just conform` before `nx release`.
  The publish already gates on test and lint; this makes it gate on the
  rendered output too, so a package that renders invalid objects never
  reaches OCI.
- `.claude/hooks/manifest-gate.sh`: call `conform-files` for a touched
  `main.k` or `examples/*.yaml`, so the failure surfaces in the same turn.

Exclusions match the rest of the repo: `tag:area:providers` (generated) and
the `render` target (needs docker, stays local).

### Stage 2 — agent evaluation suite (opt-in, scheduled)

Stage 1 says whether a given output is acceptable. Stage 2 says whether the
agent setup (hooks, skills, `CLAUDE.md`, model) reliably produces acceptable
output. It is an eval of the tooling, not a PR gate.

- `tools/eval/cases/*.yaml`: one case per file, each a task prompt plus the
  checks that define success. Cases come from real work in this repo, for
  example "add a CronJob task to the `app` package with a values example",
  "give the cnpg postgres XRD a `backup` field wired to the velero package",
  "bump the kubevirt provider without hand-editing `packages/providers/`".
- `tools/eval/run.ts`: for each case, check out a clean worktree, run
  `claude -p "<prompt>"` headless with the repo's own `.claude/` config, then
  score:
  1. `just check` and `just conform` pass (hard requirement),
  2. the case's own assertions pass (`kcl test` names, files that must or
     must not change, `guard-generated` not bypassed),
  3. optionally a rubric judge: a second model call that reads the diff and
     answers fixed yes/no questions (follows the package's values contract,
     no duplicated helpers, examples updated). Rubric scores are advisory
     and reported, never gating, because they are not reproducible.
- Output: a JSON report plus pass-rate per case, in the same shape
  `tools/bench` already uses for its HTML report so the two can share a page.
- `.github/workflows/eval.yml`: `workflow_dispatch` and a weekly schedule.
  Needs `ANTHROPIC_API_KEY` as a repository secret. Never runs on
  `pull_request`: it costs money per run and a flaky model call must not
  block a human's PR. A drop in pass rate below a threshold fails the run
  and opens an issue rather than blocking merges.

### Provenance

Cheap and worth doing first: a CI step that reads the PR's commits for a
`Co-Authored-By: Claude` trailer (the attribution this repo's sessions are
configured to add) and applies an `ai-authored` label. That label can then
require the `conform` job and one human review via branch protection, and
it gives the Stage 2 suite a corpus of real AI-authored PRs to turn into
cases.

## Order of work

1. Provenance label step in `ci.yml`. One step, no new tooling.
2. `just conform` + kubeconform + a first `policies/` set, wired into
   pre-push and a `conform` CI job. This is the actual output validator.
3. `just conform` in `release.yml` before `nx release`.
4. `conform-files` in `manifest-gate.sh`.
5. `tools/eval` with three to five cases and the `eval.yml` workflow.

## Not covered

- Runtime validation of model calls inside the manager cluster (nothing
  makes such calls yet).
- Crossplane `render` (function pipeline) output in CI, which needs docker;
  it stays in `just render` locally and in the kind e2e recipes.
