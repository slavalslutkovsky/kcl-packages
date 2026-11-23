"""
gha-tekton — one GitHub Actions workflow in, one Tekton Pipelines-as-Code
PipelineRun out, plus a report of everything that did not translate 1:1.

  workflow.yml ──► Workflow (typed subset, unknown keys fail)
                     │
                     ├─ on:            ──► pipelinesascode.tekton.dev/on-cel-expression
                     ├─ jobs.<id>      ──► pipelineSpec.tasks[] (taskSpec inline)
                     │    needs        ──► runAfter
                     │    if           ──► when (event / branch conditions only)
                     │    strategy     ──► matrix (beta: enable-api-fields: beta)
                     │    services     ──► sidecars
                     │    runs-on      ──► every step's image (Config.runners)
                     └─ steps[]
                          run          ──► step script (shell semantics kept)
                          uses         ──► Config.actions mapping, or unsupported
                          \${{ }}      ──► params / PaC {{ }} / env from Secret or ConfigMap

THE TRANSLATION IS STRICT. A construct with no faithful Tekton equivalent is
an `unsupported` report item, and `render` fails while any exist unless
`allowPartial` is set. Constructs whose loss does not change what a run does
on success (`permissions`, `workflow_dispatch`, matrix `fail-fast`) are
`ignored` items with the reason; mapped actions are `mapped` items.

ONE JOB, ONE TASK, ONE WORKSPACE SUBPATH. GitHub runs every job on a fresh
machine; here every task gets `source` at subPath <job>, so parallel jobs
never share a checkout. `actions/checkout` becomes a git step fed by the PaC
`{{ git_auth_secret }}` (workspace `basic-auth`).

EXPRESSIONS are substituted where GitHub substitutes them, textually:
`matrix.*` -> `$(params.*)` (Tekton), `github.*` -> PaC `{{ }}` variables;
`secrets.*` and `vars.*` become env vars from Config.secretName /
Config.varsConfigMap (`secrets.GITHUB_TOKEN` from the PaC git auth Secret).
In scripts those land as shell variables, so an expression inside single
quotes would stop expanding: that is reported unsupported, not emitted.
"""

import regex
import tekton.models.v1 as tk

# ── Input: the GitHub Actions workflow keys this package reads ──────────────
schema Defaults:
  run?: {str:str}

  check:
    all_true([_k in ["shell", "working-directory"] for _k in run or {}]), "defaults.run takes shell and working-directory"

schema Step:
  id?: str
  name?: str
  uses?: str
  run?: str
  shell?: str
  "with"?: {str:any}
  env?: {str:any}
  "if"?: any
  "working-directory"?: str
  "continue-on-error"?: bool | str
  "timeout-minutes"?: int | float | str

  check:
    bool(uses) != bool(run), "a step has exactly one of `uses` and `run`"

schema Strategy:
  matrix?: any
  "fail-fast"?: bool | str
  "max-parallel"?: int | str

schema Job:
  name?: str
  permissions?: any
  needs?: str | [str]
  "if"?: any
  "runs-on"?: any
  environment?: any
  concurrency?: any
  outputs?: {str:str}
  env?: {str:any}
  defaults?: Defaults
  steps?: [Step]
  "timeout-minutes"?: int | float | str
  strategy?: Strategy
  "continue-on-error"?: bool | str
  container?: any
  services?: {str:any}
  uses?: str
  "with"?: {str:any}
  secrets?: any

schema Workflow:
  name?: str
  "run-name"?: str
  "on": any
  env?: {str:any}
  defaults?: Defaults
  concurrency?: any
  permissions?: any
  jobs: {str:Job}

# ── Configuration ────────────────────────────────────────────────────────────
schema ActionMapping:
  """
    What a `uses: <owner>/<repo>[/<path>]@<ref>` step becomes (key without `@ref`).

      checkout  the built-in git step (actions/checkout semantics, this repo)
      drop      no step; `reason` says why that is safe (the runner image
                already carries the tool the action would install)
      step      one step: `image` running `script`; the action's `with:`
                inputs arrive as INPUT_<NAME> env vars, as the Actions
                runtime passes them. A script that should honour a step
                `if:` must be POSIX shell (the guard goes after its #! line).
    """
  kind: "checkout" | "drop" | "step"
  reason?: str
  image?: str
  script?: str

  check:
    kind != "drop" or reason, "a `drop` mapping states why dropping the action is safe (`reason`)"
    kind != "step" or (image and script), "a `step` mapping needs `image` and `script`"

schema Config:
  """
    name           PipelineRun name; default: the workflow file's stem or `name:`
    runners        runs-on label -> step image
    gitImage       image of the checkout step (needs git and a POSIX shell)
    actions        action mappings, see ActionMapping
    secretName     Secret holding the workflow's `secrets.*` (key = secret name)
    varsConfigMap  ConfigMap holding its `vars.*` (key = variable name)
    """
  name?: str
  runners: {str:str} = {
    "ubuntu-latest" = "docker.io/library/ubuntu:24.04"
    "ubuntu-24.04" = "docker.io/library/ubuntu:24.04"
    "ubuntu-22.04" = "docker.io/library/ubuntu:22.04"
  }
  gitImage: str = "cgr.dev/chainguard/git:latest-dev"
  actions: {str:ActionMapping} = {
    "actions/checkout" = {kind = "checkout"}
  }
  secretName: str = "gha-secrets"
  varsConfigMap: str = "gha-vars"
  serviceAccountName: str = "builder"
  workspaceSize: str = "1Gi"
  pipelineTimeout: str = "6h"
  maxKeepRuns: int = 5
  allowPartial: bool = False

# ── Small helpers ────────────────────────────────────────────────────────────
_EXPR = r"\$\{\{.*?\}\}"
_ID = r"[A-Za-z_][A-Za-z0-9_-]*"
_WS = "$(workspaces.source.path)"

_item = lambda path: str, construct: str, status: str, detail: str {
  {path = path, construct = construct, status = status, detail = detail}
}

_unsupported = lambda path: str, construct: str, detail: str {
  _item(path, construct, "unsupported", detail)
}

_ignored = lambda path: str, construct: str, detail: str {
  _item(path, construct, "ignored", detail)
}

# A DNS label: lower-case, [a-z0-9-], at most `n` characters.
_slug = lambda s: str, n: int -> str {
  _s = regex.replace(s.lower(), r"[^a-z0-9-]+", "-").strip("-")
  _s[:n:].strip("-") or "x"
}

# YAML scalars as GitHub stringifies them (booleans lower-case).
_scalar = lambda v: any -> str {
  ("true" if v else "false") if typeof(v) == "bool" else (str(v) if _isScalar(v) else "")
}

_isScalar = lambda v: any -> bool {
  typeof(v) in ["str", "int", "float", "bool"]
}

_envName = lambda prefix: str, key: str -> str {
  prefix + regex.replace(key.upper(), r"[^A-Z0-9_]", "_")
}

# ── Expressions ──────────────────────────────────────────────────────────────
_GITHUB = {
  "github.sha" = "{{ revision }}"
  "github.event_name" = "{{ event_type }}"
  "github.repository" = "{{ repo_owner }}/{{ repo_name }}"
  "github.repository_owner" = "{{ repo_owner }}"
  "github.base_ref" = "{{ target_branch }}"
  "github.head_ref" = "{{ source_branch }}"
  "github.workspace" = _WS
}

_inner = lambda e: str -> str {
  e[3:-2:].strip()
}

# One `${{ <inner> }}`: what it becomes. kind: text (substitute `text`),
# secret / var (an env var named `name` from `ref`), env (shell variable
# `name`), none (no faithful translation; `detail` says why).
_resolve = lambda inner: str, matrix: [str] -> {str:} {
  _ns = inner.split(".")[0] if regex.match(inner, r"^(matrix|secrets|vars|env)\." + _ID + r"$") else ""
  _key = inner[len(_ns) + 1::] if _ns else ""
  _r = {kind = "text", text = "$(params.${_key})"} if _ns == "matrix" and _key in matrix else {
    kind = "secret"
    name = "GITHUB_TOKEN"
    ref = {
      secretKeyRef = {name = "{{ git_auth_secret }}", key = "git-provider-token"}
    }
  } if _ns == "secrets" and _key == "GITHUB_TOKEN" else {
    kind = "secret"
    name = _envName("GHA_SECRET_", _key)
    ref = {
      secretKeyRef = {name = "", key = _key}
    }
  } if _ns == "secrets" else {
    kind = "var"
    name = _envName("GHA_VAR_", _key)
    ref = {
      configMapKeyRef = {name = "", key = _key}
    }
  } if _ns == "vars" else {kind = "env", name = _key} if _ns == "env" else {kind = "text", text = _GITHUB[inner]} if inner in _GITHUB else {
    kind = "none"
    detail = "matrix key not in this job's matrix" if _ns == "matrix" else "no Tekton/PaC equivalent for this expression"
  }
  _r
}

# Fill the Config-dependent ref names of a secret/var resolution.
_envFrom = lambda cfg: Config, r: {str:} -> {str:} {
  {
    name = r.name
    valueFrom = {
      secretKeyRef = {name = r.ref.secretKeyRef.name or cfg.secretName, key = r.ref.secretKeyRef.key}
    } if r.kind == "secret" else {
      configMapKeyRef = {name = cfg.varsConfigMap, key = r.ref.configMapKeyRef.key}
    }
  }
}

# Substitute every `${{ }}` of `text`. mode "script": secrets, vars and env
# become shell variables (`env` lists the env vars that feeds); mode "value":
# only textual substitutions are allowed (env values, `with:` inputs, paths).
_subst = lambda cfg: Config, text: str, matrix: [str], mode: str -> {str:} {
  _ms = regex.findall(text, _EXPR)
  _ps = regex.split(text, _EXPR)
  _rs = [_resolve(_inner(_m), matrix) for _m in _ms]
  # the line text before match i, to tell whether it sits in single quotes
  _before = ["".join([_ps[_j] + _ms[_j] for _j in range(_i)]) + _ps[_i] for _i in range(len(_ms))]
  _quoted = [_b.split("\n")[-1].count("'") % 2 == 1 for _b in _before]
  _shellVar = lambda r: {str:} -> bool {
    r.kind in ["secret", "var", "env"]
  }
  _ok = [_rs[_i].kind == "text" or (mode == "script" and _shellVar(_rs[_i]) and not _quoted[_i]) for _i in range(len(_ms))]
  _out = [("$" + "{" + _rs[_i].name + "}") if _shellVar(_rs[_i]) else (_rs[_i].text or "") for _i in range(len(_ms))]
  {
    text = "".join([_ps[_i] + (_out[_i] if _ok[_i] else _ms[_i]) for _i in range(len(_ms))]) + _ps[-1] if all_true(_ok) else text
    env = [_envFrom(cfg, _r) for _r in _rs if _r.kind in ["secret", "var"]]
    issues = ["${_ms[_i]}: " + ("inside single quotes, where the shell variable it becomes would not expand" if _shellVar(_rs[_i]) and mode == "script" else "secrets, vars and env are allowed only as a whole env value or in a run script" if _shellVar(_rs[_i]) else _rs[_i].detail) for _i in range(len(_ms)) if not _ok[_i]]
  }
}

# A step/job env map -> Tekton env list. A value that is exactly one
# secrets.*/vars.* expression becomes valueFrom; others substitute textually.
_env = lambda cfg: Config, vars: {str:any}, matrix: [str] -> {str:} {
  _one = lambda name: str, raw: any -> {str:} {
    _s = _scalar(raw)
    _whole = regex.match(_s, r"^\s*\$\{\{[^}]*\}\}\s*$")
    _r = _resolve(_inner(_s.strip()), matrix) if _whole else {kind = "text"}
    _t = _subst(cfg, _s, matrix, "value")
    _from = _r.kind in ["secret", "var"]
    _bad = _r.kind in ["env", "none"]
    {
      env = [{name = name, valueFrom = _envFrom(cfg, _r).valueFrom}] if _from else [] if _bad or _t.issues else [{name = name, value = _t.text}]
      issues = (["env ${name}: " + _s.strip() + ": " + (_r.detail if _r.kind == "none" else "env.* inside env does not translate")] if _bad else [] if _from else ["env ${name}: " + _i for _i in _t.issues])
    }
  }
  _all = [_one(_k, _v) for _k, _v in vars or {}]
  {
    env = sum([_a.env for _a in _all], [])
    issues = sum([_a.issues for _a in _all], [])
  }
}

# Later lists win by name; first-seen order kept.
_mergeEnv = lambda lists: [[{str:}]] -> [{str:}] {
  _flat = sum(lists, [])
  _last = {_e.name: _e for _e in _flat}
  _names = [_flat[_i].name for _i in range(len(_flat)) if _flat[_i].name not in [_f.name for _f in _flat[:_i:]]]
  [_last[_n] for _n in _names]
}

# ── Conditions (`if:`) ──────────────────────────────────────────────────────
# Only event and branch tests translate: they are known before the run
# starts, from PaC's {{ event_type }} and {{ target_branch }}. A job gets
# `when` expressions; a step gets a shell guard (`... || exit 0`, a skipped
# step succeeds as it does on GitHub).
_cond = lambda raw: any -> {str:} {
  _s0 = _scalar(raw).strip() if typeof(raw) in ["str", "int", "float"] else ""
  _s = _inner(_s0) if regex.match(_s0, r"^\$\{\{.*\}\}$") else _s0
  _compound = "||" in _s or "(" in _s.replace("success()", "") or "!" in _s.replace("!=", "")
  _atoms = [_a.strip() for _a in _s.split("&&")] if _s and not _compound else []
  _parse = lambda a: str -> {str:} {
    _ev = regex.match(a, r"^github\.event_name\s*(==|!=)\s*'[^']*'$")
    _ref = regex.match(a, r"^github\.ref\s*==\s*'refs/heads/[^']*'$")
    _val = a.split("'")[1] if _ev or _ref else ""
    _branch = _val[len("refs/heads/")::] if _ref else ""
    _neg = "!=" in a
    {} if a == "success()" else {
      when = [{input = "{{ event_type }}", operator = "notin" if _neg else "in", values = [_val]}]
      guard = ["[ \"{{ event_type }}\" " + ("!=" if _neg else "=") + " \"${_val}\" ]"]
    } if _ev else {
      when = [{input = "{{ event_type }}", operator = "in", values = ["push"]}, {input = "{{ target_branch }}", operator = "in", values = [_branch]}]
      guard = ["[ \"{{ event_type }}\" = \"push\" ]", "[ \"{{ target_branch }}\" = \"${_branch}\" ]"]
    } if _ref else {issue = a}
  }
  _ps = [_parse(_a) for _a in _atoms]
  _bad = [_p.issue for _p in _ps if _p.issue] + ([_s] if _compound else []) + (["false"] if raw == False else [])
  _guards = sum([_p.guard or [] for _p in _ps], [])
  {
    when = sum([_p.when or [] for _p in _ps], [])
    guard = "( " + " && ".join(_guards) + " ) || exit 0\n" if _guards else ""
    issues = ["if: ${_b}: only success(), github.event_name ==/!= '<x>' and github.ref == 'refs/heads/<b>' joined by && translate" for _b in _bad]
  }
}

# ── Triggers (`on:`) → PaC CEL ──────────────────────────────────────────────
_celStr = lambda s: str -> str {
  "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}

# A GitHub branch filter -> CEL on target_branch.
_branchCel = lambda b: str -> str {
  _re = "^" + regex.replace(regex.replace(regex.replace(regex.replace(b, r"([.+()^$|{}\\])", r"\$1"), r"\*\*", "<DSTAR>"), r"\*", "[^/]*"), "<DSTAR>", ".*").replace("?", ".") + "$"
  "target_branch.matches(${_celStr(_re)})" if regex.match(b, r"[*?]") else "target_branch == ${_celStr(b)}"
}

_anyOf = lambda parts: [str] -> str {
  parts[0] if len(parts) == 1 else "(" + " || ".join(parts) + ")"
}

_DEFAULT_PR_TYPES = ["opened", "synchronize", "reopened"]

_trigger = lambda event: str, f: any -> {str:} {
  _f = f if typeof(f) == "dict" else {}
  _known = ["branches", "branches-ignore", "paths"] + (["types"] if event == "pull_request" else [])
  _badKeys = [_k for _k in _f if _k not in _known]
  _badBranch = [_b for _b in (_f.branches or []) + (_f["branches-ignore"] or []) if regex.match(_b, r"^!|\[")]
  _badTypes = [_t for _t in (_f.types or []) if _t not in _DEFAULT_PR_TYPES]
  _parts = ["event == ${_celStr(event)}"] + ([_anyOf([_branchCel(_b) for _b in _f.branches])] if _f.branches else []) + (["!" + _anyOf([_branchCel(_b) for _b in _f["branches-ignore"]])] if _f["branches-ignore"] else []) + ([_anyOf(["${_celStr(_p)}.pathChanged()" for _p in _f.paths])] if _f.paths else [])
  {
    cel = "(" + " && ".join(_parts) + ")" if len(_parts) > 1 else _parts[0]
    issues = ["on.${event}.${_k}: no PaC equivalent" for _k in _badKeys] + ["on.${event}: branch pattern ${_b}: negation and character classes do not translate" for _b in _badBranch] + ["on.${event}.types: ${_t}: PaC runs pull requests on opened, synchronize and reopened only" for _t in _badTypes]
  }
}

_triggers = lambda on: any -> {str:} {
  _events = {_e: None for _e in [on]} if typeof(on) == "str" else {_e: None for _e in on} if typeof(on) == "list" else on or {}
  _t = {_e: _trigger(_e, _events[_e]) for _e in _events if _e in ["push", "pull_request"]}
  {
    cel = " || ".join([_t[_e].cel for _e in _t])
    items = sum([[_unsupported("on.${_e}", "trigger", _i) for _i in _t[_e].issues] for _e in _t], []) + [_ignored("on.workflow_dispatch", "trigger", "manual runs: `tkn pac start` or `/test <name>` on a pull request") for _e in _events if _e == "workflow_dispatch"] + [_unsupported("on.${_e}", "trigger", "PaC triggers on push and pull_request only" + ("; schedule: a CronJob or Tekton Triggers" if _e == "schedule" else "")) for _e in _events if _e not in ["push", "pull_request", "workflow_dispatch"]]
  }
}

# ── Matrix ───────────────────────────────────────────────────────────────────
_matrix = lambda m: any, path: str -> {str:} {
  _d = m if typeof(m) == "dict" else {}
  _axes = {_k: _v for _k, _v in _d if _k not in ["include", "exclude"]}
  _okAxis = {_k: _v for _k, _v in _axes if typeof(_v) == "list" and all_true([_isScalar(_x) for _x in _v])}
  _inc = [_e for _e in (_d.include or []) if typeof(_e) == "dict" and all_true([_isScalar(_v) for _, _v in _e])]
  _incKeys = sum([[_k for _k in _e] for _e in _inc], [])
  _keys = [_k for _k in _okAxis] + [_k for _i, _k in _incKeys if _k not in _okAxis and _k not in _incKeys[:_i:]]
  {
    keys = _keys
    spec = {
      params = [{name = _k, value = [_scalar(_x) for _x in _v]} for _k, _v in _okAxis] or Undefined
      include = [{name = "include-${_i}", params = [{name = _k, value = _scalar(_v)} for _k, _v in _inc[_i]]} for _i in range(len(_inc))] or Undefined
    } if _keys else Undefined
    items = ([_unsupported(path, "strategy.matrix", "a matrix from an expression is only known at run time")] if m and typeof(m) != "dict" else []) + [_unsupported("${path}.${_k}", "strategy.matrix", "axis values must be a list of scalars") for _k in _axes if _k not in _okAxis] + ([_unsupported("${path}.exclude", "strategy.matrix", "Tekton matrices have no exclude")] if _d.exclude else []) + ([_unsupported("${path}.include", "strategy.matrix", "include entries must map keys to scalars")] if len(_inc) != len(_d.include or []) else [])
  }
}

# ── Steps ────────────────────────────────────────────────────────────────────
_SHELLS = {
  "" = "#!/usr/bin/env bash\nset -e\n"
  bash = "#!/usr/bin/env bash\nset -eo pipefail\n"
  sh = "#!/bin/sh\nset -e\n"
  python = "#!/usr/bin/env python3\n"
}

_CHECKOUT_OK = ["fetch-depth", "filter", "submodules", "path", "ref"]
_CHECKOUT_IGNORED = ["persist-credentials", "clean", "show-progress", "set-safe-directory"]

_checkoutScript = lambda w: {str:}, path: str, ref: str -> str {
  _depth = _scalar(w["fetch-depth"]) if _isScalar(w["fetch-depth"]) else "1"
  _sub = _scalar(w.submodules) if _isScalar(w.submodules) else "false"
  """#!/bin/sh
set -eu
umask 077
cp "$(workspaces.basic-auth.path)/.git-credentials" "$HOME/.git-credentials"
cp "$(workspaces.basic-auth.path)/.gitconfig" "$HOME/.gitconfig"
git config --global --add safe.directory '*'
mkdir -p "${path}" && cd "${path}"
git init -q .
git remote add origin "{{ repo_url }}" 2>/dev/null || git remote set-url origin "{{ repo_url }}"
git fetch -q${"" if _depth == "0" else " --depth=" + _depth}${" --filter=" + _scalar(w.filter) if w.filter else ""} origin "${ref}"
git checkout -q --detach FETCH_HEAD
""" + ("git submodule update -q --init" + (" --recursive" if _sub == "recursive" else "") + "\n" if _sub in ["true", "recursive"] else "")
}

_step = lambda cfg: Config, ctx: {str:}, i: int, s: Step -> {str:} {
  _path = "${ctx.path}.steps[${i}]"
  _uses = s.uses or ""
  _key = _uses.split("@")[0]
  _map = cfg.actions[_key] if _uses and not _uses.startswith("./") and not _uses.startswith("docker://") else None
  _w = s["with"] or {}
  _wdRaw = s["working-directory"] or ctx.workingDirectory
  _wd = _subst(cfg, _wdRaw, ctx.matrix, "value") if _wdRaw else {text = "", env = [], issues = []}
  _dir = _WS + ("/" + _wd.text if _wd.text else "")
  _cnd = _cond(s["if"])
  _shell = (s.shell or ctx.shell or "") if s.run else "sh"
  _senv = _env(cfg, s.env, ctx.matrix)
  _inputs = _env(cfg, {_envName("INPUT_", _k): _v for _k, _v in _w}, ctx.matrix) if _map and _map.kind == "step" else {env = [], issues = []}
  _run = _subst(cfg, s.run, ctx.matrix, "script") if s.run else {text = "", env = [], issues = []}
  _coe = s["continue-on-error"]
  _tmo = s["timeout-minutes"]
  _base = s.name or s.id or _key.split("/")[-1] or "run"
  _name = "${_slug(_base, 55)}-${i}"
  _ckPath = _subst(cfg, _scalar(_w.path), ctx.matrix, "value") if _w.path else {text = "", env = [], issues = []}
  _ckRef = _subst(cfg, _scalar(_w.ref), ctx.matrix, "value") if _w.ref else {text = "{{ revision }}", env = [], issues = []}
  _common = {
    name = _name
    image = ctx.image
    workingDir = _dir
    onError = "continue" if _coe == True else Undefined
    timeout = "${_scalar(_tmo)}m" if typeof(_tmo) in ["int", "float"] else Undefined
  }
  _guarded = lambda script: str -> str {
    _lines = script.split("\n")
    "\n".join([_lines[0], _cnd.guard.rstrip("\n")] + _lines[1::]) if _cnd.guard and script.startswith("#!") else _cnd.guard + script
  }
  _steps = [_common | {
    script = _guarded((_SHELLS[_shell] or "") + _run.text)
    env = _mergeEnv([_run.env, _senv.env]) or Undefined
  }] if s.run else [_common | {
    image = cfg.gitImage
    workingDir = _WS
    script = _guarded(_checkoutScript(_w, _WS + ("/" + _ckPath.text if _ckPath.text else ""), _ckRef.text))
    env = [{name = "HOME", value = "/tekton/home"}]
  }] if _map and _map.kind == "checkout" else [_common | {
    image = _map.image
    script = _guarded(_map.script)
    env = _mergeEnv([_inputs.env, _senv.env]) or Undefined
  }] if _map and _map.kind == "step" else [_common | {image = _uses[len("docker://")::]}] if _uses.startswith("docker://") and not _w else []
  _usesIssue = "local actions are not in the repository at translation time" if _uses.startswith("./") else "`with` on a docker:// step (entrypoint/args) does not translate" if _uses.startswith("docker://") and _w else "no mapping for action ${_key}; add one under `actions`" if _uses and not _uses.startswith("docker://") and not _map else ""
  _ckBad = [_k for _k in _w if _k not in _CHECKOUT_OK + _CHECKOUT_IGNORED] if _map and _map.kind == "checkout" else []
  _scriptBad = [_v for _v in ["GITHUB_ENV", "GITHUB_PATH", "GITHUB_STATE"] if s.run and _v in s.run]
  _shellBad = s.run and _shell not in _SHELLS
  _items = ([_unsupported(_path, "uses: ${_uses}", _usesIssue)] if _usesIssue else []) + ([_item(_path, "uses: ${_uses}", "mapped", "dropped: ${_map.reason}" if _map.kind == "drop" else "${_map.kind} mapping")] if _map and not _ckBad else []) + [_unsupported(_path, "uses: ${_uses} with.${_k}", "checkout input without a translation (only the workflow's own repository is cloned)") for _k in _ckBad] + [_unsupported(_path, "run", "\$${_v} propagates state across steps, which separate step containers do not share") for _v in _scriptBad] + ([_unsupported(_path, "shell: ${_shell}", "bash, sh and python translate")] if _shellBad else []) + ([_unsupported(_path, "if", "a guard needs a sh/bash step")] if _cnd.guard and s.run and _shell == "python" else []) + [_unsupported(_path, "expression", _i) for _i in _run.issues + _senv.issues + _inputs.issues + _wd.issues + _ckPath.issues + _ckRef.issues] + [_unsupported(_path, "if", _i) for _i in _cnd.issues] + ([_unsupported(_path, "continue-on-error", "only a literal true/false translates")] if typeof(_coe) == "str" else []) + ([_unsupported(_path, "timeout-minutes", "only a literal number translates")] if typeof(_tmo) == "str" else [])
  {
    steps = _steps
    items = _items
    auth = bool(_map and _map.kind == "checkout")
  }
}

# ── Jobs ─────────────────────────────────────────────────────────────────────
_runnerImage = lambda cfg: Config, job: Job -> {str:} {
  _ro = job["runs-on"]
  _label = _ro if typeof(_ro) == "str" else _ro[0] if typeof(_ro) == "list" and len(_ro) == 1 else None
  _c = job.container
  _cImage = _c if typeof(_c) == "str" else _c.image if typeof(_c) == "dict" else None
  _image = _cImage or (cfg.runners[_label] if _label else None)
  {
    image = _image or "unresolved"
    issues = ([] if _image else ["runs-on: ${_scalar(_ro) if _isScalar(_ro) else _ro}: no image for this runner (Config.runners)"]) + (["container.${_k}: no translation" for _k in _c if _k not in ["image", "env"]] if typeof(_c) == "dict" else [])
  }
}

_job = lambda cfg: Config, wf: Workflow, id: str, job: Job, names: {str:str} -> {str:} {
  _path = "jobs.${id}"
  _m = _matrix(job.strategy.matrix if job.strategy else None, "${_path}.strategy.matrix")
  _runner = _runnerImage(cfg, job)
  _defaults = (wf.defaults.run if wf.defaults else None) or {}
  _jdefaults = (job.defaults.run if job.defaults else None) or {}
  _ctx = {
    path = _path
    matrix = _m.keys
    image = _runner.image
    shell = _jdefaults.shell or _defaults.shell or ""
    workingDirectory = _jdefaults["working-directory"] or _defaults["working-directory"] or ""
  }
  _steps = [_step(cfg, _ctx, _i, (job.steps or [])[_i]) for _i in range(len(job.steps or []))]
  _container = job.container if typeof(job.container) == "dict" else {}
  _tplEnv = _env(cfg, (wf.env or {}) | (_container.env or {}) | (job.env or {}), _m.keys)
  _jc = _cond(job["if"])
  _needs = [job.needs] if typeof(job.needs) == "str" else job.needs or []
  _auth = any_true([_s.auth for _s in _steps])
  _svc = job.services or {}
  _svcOk = {_k: _v for _k, _v in _svc if (typeof(_v) == "dict" and _v.image and all_true([_f in ["image", "env", "ports"] for _f in _v]))}
  _svcEnv = {_k: _env(cfg, _v.env, _m.keys) for _k, _v in _svcOk}
  _coe = job["continue-on-error"]
  _tmo = job["timeout-minutes"]
  _strategy: {str:} = {_k: _v for _k, _v in job.strategy} if job.strategy else {}
  _runtime = [
    {name = "CI", value = "true"}
    {name = "GITHUB_SHA", value = "{{ revision }}"}
    {name = "GITHUB_EVENT_NAME", value = "{{ event_type }}"}
    {name = "GITHUB_REPOSITORY", value = "{{ repo_owner }}/{{ repo_name }}"}
    {name = "GITHUB_REPOSITORY_OWNER", value = "{{ repo_owner }}"}
    {name = "GITHUB_WORKSPACE", value = _WS}
    {name = "GITHUB_OUTPUT", value = "/tmp/github_output"}
    {name = "GITHUB_STEP_SUMMARY", value = "/tmp/github_step_summary"}
    {name = "RUNNER_TEMP", value = "/tmp"}
  ]
  _taskSpec: tk.TaskV1Spec = {
    params = [{name = _k, $type = "string"} for _k in _m.keys] or Undefined
    workspaces = [{name = "source"}] + ([{name = "basic-auth", readOnly = True}] if _auth else [])
    stepTemplate = {env = _mergeEnv([_runtime, _tplEnv.env])}
    sidecars = [{name = _slug(_k, 63), image = _v.image, env = _svcEnv[_k].env or Undefined} for _k, _v in _svcOk] or Undefined
    steps = sum([_s.steps for _s in _steps], [])
  }
  _task = {
    name = names[id]
    displayName = job.name or Undefined
    runAfter = [names[_n] for _n in _needs if _n in names] or Undefined
    when = _jc.when or Undefined
    matrix = _m.spec
    onError = "continue" if _coe == True else Undefined
    timeout = "${_scalar(_tmo)}m" if typeof(_tmo) in ["int", "float"] else "360m"
    workspaces = [{name = "source", workspace = "source", subPath = names[id]}] + ([{name = "basic-auth", workspace = "basic-auth"}] if _auth else [])
    taskSpec = _taskSpec
  }
  _items = ([_unsupported(_path, "uses: ${job.uses}", "reusable workflows do not translate")] if job.uses else []) + [_unsupported(_path, "runs-on", _i) for _i in _runner.issues if not job.uses] + _m.items + [_unsupported("${_path}.needs", _n, "no such job") for _n in _needs if _n not in names] + [_unsupported(_path, "if", _i) for _i in _jc.issues] + [_unsupported(_path, "expression", _i) for _i in _tplEnv.issues + sum([_e.issues for _, _e in _svcEnv], [])] + ([_unsupported(_path, "environment", "deployment environments (protection rules, scoped secrets) have no Tekton equivalent")] if job.environment else []) + ([_unsupported(_path, "concurrency", "set concurrency_limit on the PaC Repository instead")] if job.concurrency else []) + ([_unsupported(_path, "outputs", "job outputs need step outputs, which do not translate")] if job.outputs else []) + [_unsupported("${_path}.services.${_k}", "service", "only image, env and ports translate") for _k in _svc if _k not in _svcOk] + [_ignored("${_path}.services.${_k}.ports", "service", "sidecars share the pod network: reach the service on localhost:<container port>") for _k, _v in _svcOk if _v.ports] + ([_ignored(_path, "permissions", "the token's scope is the PaC GitHub App's")] if job.permissions else []) + ([_ignored("${_path}.strategy", "fail-fast", "Tekton does not cancel the other matrix runs when one fails")] if _m.spec and _strategy["fail-fast"] != False else []) + ([_ignored("${_path}.strategy", "max-parallel", "all matrix runs start at once")] if _strategy["max-parallel"] else []) + ([_unsupported(_path, "continue-on-error", "only a literal true/false translates")] if typeof(_coe) == "str" else []) + ([_unsupported(_path, "timeout-minutes", "only a literal number translates")] if typeof(_tmo) == "str" else []) + sum([_s.items for _s in _steps], [])
  {
    task = _task
    auth = _auth
    steps = len(_task.taskSpec.steps or [])
    items = _items
  }
}

# ── Entry points ─────────────────────────────────────────────────────────────
translate = lambda cfg: Config, wf: Workflow, source: str -> {str:} {
  _ids = [_k for _k in wf.jobs]
  _names = {_k: _slug(_k, 63) for _k in _ids}
  _clash = [_k for _i, _k in _ids if _names[_k] in [_names[_o] for _o in _ids[:_i:]]]
  assert not _clash, "job ids ${_clash} collide once made DNS labels"
  _jobs = [_job(cfg, wf, _k, wf.jobs[_k], _names) for _k in _ids]
  _auth = any_true([_j.auth for _j in _jobs])
  _trig = _triggers(wf["on"])
  _name = _slug(cfg.name or wf.name or "workflow", 63)
  _pipeline: tk.PipelineV1Spec = {
    workspaces = [{name = "source"}] + ([{name = "basic-auth"}] if _auth else [])
    tasks = [_j.task for _j in _jobs]
  }
  _run: tk.PipelineRunV1 = {
    metadata = {
      name = _name
      annotations = {_k: _v for _k, _v in {
        "pipelinesascode.tekton.dev/on-cel-expression" = _trig.cel
        "pipelinesascode.tekton.dev/max-keep-runs" = str(cfg.maxKeepRuns)
        "gha-tekton.shluviza.com/source" = source
      } if _v}
    }
    spec = {
      taskRunTemplate = {serviceAccountName = cfg.serviceAccountName}
      timeouts = {pipeline = cfg.pipelineTimeout}
      workspaces = [{
        name = "source"
        volumeClaimTemplate = {
          spec = {accessModes = ["ReadWriteOnce"], resources = {
            requests = {storage = cfg.workspaceSize}
          }}
        }
      }] + ([{name = "basic-auth", secret = {secretName = "{{ git_auth_secret }}"}}] if _auth else [])
      pipelineSpec = _pipeline
    }
  }
  _items = _trig.items + ([_ignored("permissions", "permissions", "the token's scope is the PaC GitHub App's")] if wf.permissions else []) + ([_unsupported("concurrency", "concurrency", "set concurrency_limit on the PaC Repository instead")] if wf.concurrency else []) + ([_ignored("run-name", "run-name", "PaC names runs <name>-<random>")] if wf["run-name"] else []) + sum([_j.items for _j in _jobs], [])
  {
    pipelineRun = _run
    report = {
      kind = "TranslationReport"
      workflow = _name
      source = source or Undefined
      summary = {
        jobs = len(_jobs)
        steps = sum([_j.steps for _j in _jobs])
        mapped = len([_i for _i in _items if _i.status == "mapped"])
        ignored = len([_i for _i in _items if _i.status == "ignored"])
        unsupported = len([_i for _i in _items if _i.status == "unsupported"])
      }
      items = _items
    }
  }
}

# The PipelineRun, refusing a partial translation unless cfg.allowPartial.
render = lambda cfg: Config, wf: Workflow, source: str -> [any] {
  _t = translate(cfg, wf, source)
  _bad = [_i for _i in _t.report.items if _i.status == "unsupported"]
  assert cfg.allowPartial or not _bad, "${len(_bad)} construct(s) do not translate (render with -D report=true for the list): " + "; ".join(["${_i.path}: ${_i.construct}: ${_i.detail}" for _i in _bad])
  [_t.pipelineRun]
}
