# Tests for the GitHub Actions -> Tekton translation: what translates and how
# (triggers, needs, matrix, conditions, expressions, checkout), and what must be
# reported unsupported instead of emitted.
# Run: kcl test
import runtime

# Test helpers share the package scope with lib.k: every one is prefixed `_fx`.
_fxCfg = Config {
  runners = {"ubuntu-latest" = "r/runner:1"}
  actions = {
    "actions/checkout" = {kind = "checkout"}
    "oven-sh/setup-bun" = {kind = "drop", reason = "the runner image carries bun"}
    "acme/notify" = {kind = "step", image = "r/notify:1", script = "#!/bin/sh\nnotify \"$INPUT_CHANNEL\"\n"}
  }
}

_fxWf = lambda _fxJobs: {str:}, _fxOn: any {
  Workflow {"on" = _fxOn, jobs = _fxJobs}
}

_fxOne = lambda _fxSteps: [{str:}] {
  _fxWf({
    build = {"runs-on" = "ubuntu-latest", steps = _fxSteps}
  }, "push")
}

_fxT = lambda _fxW: Workflow {
  translate(_fxCfg, _fxW, "w.yml")
}

_fxTask = lambda _fxW: Workflow, _fxName: str {
  [_t for _t in _fxT(_fxW).pipelineRun.spec.pipelineSpec.tasks if _t.name == _fxName][0]
}

_fxBad = lambda _fxW: Workflow {
  [_i.detail for _i in _fxT(_fxW).report.items if _i.status == "unsupported"]
}

# ── Triggers ─────────────────────────────────────────────────────────────────
test_triggers_become_pac_cel = lambda {
  _w = _fxWf({
    b = {"runs-on" = "ubuntu-latest", steps = [{run = "true"}]}
  }, {
    push = {branches = ["main", "release/**"]}
    pull_request = {branches = ["main"], paths = ["apps/**"]}
    workflow_dispatch = None
  })
  _t = _fxT(_w)
  assert _t.pipelineRun.metadata.annotations["pipelinesascode.tekton.dev/on-cel-expression"] == '(event == "push" && (target_branch == "main" || target_branch.matches("^release/.*$"))) || (event == "pull_request" && target_branch == "main" && "apps/**".pathChanged())'
  assert [_i.status for _i in _t.report.items] == ["ignored"], "workflow_dispatch is ignored, not unsupported"
}

test_triggers_without_pac_equivalent_are_unsupported = lambda {
  _w = _fxWf({
    b = {"runs-on" = "ubuntu-latest", steps = [{run = "true"}]}
  }, {
    schedule = [{cron = "0 0 * * *"}]
    push = {tags = ["v*"], "paths-ignore" = ["docs/**"]}
    pull_request = {types = ["labeled"]}
  })
  assert len(_fxBad(_w)) == 4, "schedule, push.tags, push.paths-ignore, pull_request.types=labeled: ${_fxBad(_w)}"
}

# ── Jobs ─────────────────────────────────────────────────────────────────────
test_needs_matrix_and_job_conditions = lambda {
  _w = _fxWf({
    lint = {"runs-on" = "ubuntu-latest", steps = [{run = "make lint"}]}
    test = {
      "runs-on" = "ubuntu-latest"
      needs = "lint"
      "timeout-minutes" = 20
      "if" = "github.ref == 'refs/heads/main'"
      strategy = {
        matrix = {os = ["a", "b"], node = [20, 22], include = [{os = "c", experimental = True}]}
      }
      steps = [{run = "test --os=\${{ matrix.os }} --exp=\${{ matrix.experimental }}"}]
    }
  }, "push")
  _task = _fxTask(_w, "test")
  assert _task.runAfter == ["lint"]
  assert _task.timeout == "20m"
  assert [_p.name for _p in _task.matrix.params] == ["os", "node"]
  assert _task.matrix.params[1].value == ["20", "22"]
  assert [[_p.name, _p.value] for _p in _task.matrix.include[0].params] == [["os", "c"], ["experimental", "true"]], "booleans stringify as GitHub does"
  assert [_p.name for _p in _task.taskSpec.params] == ["os", "node", "experimental"]
  assert "test --os=$(params.os) --exp=$(params.experimental)" in _task.taskSpec.steps[0].script
  assert [[_x.input, _x.operator, _x.values] for _x in _task.when] == [["{{ event_type }}", "in", ["push"]], ["{{ target_branch }}", "in", ["main"]]], "refs/heads/main on GitHub is a push to main"
  assert not _fxBad(_w)
}

test_jobs_get_isolated_workspaces = lambda {
  _w = _fxWf({
    a = {"runs-on" = "ubuntu-latest", steps = [{uses = "actions/checkout@v4"}]}
    b = {"runs-on" = "ubuntu-latest", steps = [{run = "true"}]}
  }, "push")
  _a = _fxTask(_w, "a")
  _b = _fxTask(_w, "b")
  assert [[_ws.name, _ws.subPath or ""] for _ws in _a.workspaces] == [["source", "a"], ["basic-auth", ""]]
  assert [_ws.name for _ws in _b.workspaces] == ["source"], "no git credentials for a job without checkout"
  assert _b.workspaces[0].subPath == "b"
}

test_unknown_runner_and_job_features_are_unsupported = lambda {
  _w = _fxWf({
    a = {"runs-on" = "macos-latest", steps = [{run = "true"}]}
    b = {"runs-on" = "ubuntu-latest", environment = "prod", outputs = {x = "\${{ steps.s.outputs.x }}"}, steps = [{run = "true"}]}
    c = {uses = "acme/wf/.github/workflows/x.yml@main"}
  }, "push")
  assert len(_fxBad(_w)) == 4, "${_fxBad(_w)}"
}

test_job_ids_that_collide_as_dns_labels_fail = lambda {
  _e = runtime.catch(lambda {
    _fxT(_fxWf({a_b = {"runs-on" = "ubuntu-latest", steps = [{run = "true"}]}, "a-b" = {"runs-on" = "ubuntu-latest", steps = [{run = "true"}]}}, "push"))
  })
  assert "collide" in _e, _e
}

# ── Steps ────────────────────────────────────────────────────────────────────
test_shell_semantics_are_kept = lambda {
  _s = _fxTask(_fxOne([{run = "a"}, {run = "b", shell = "bash"}, {run = "c", shell = "sh"}, {run = "print(1)", shell = "python"}]), "build").taskSpec.steps
  assert _s[0].script == "#!/usr/bin/env bash\nset -e\na", "GitHub's default: bash -e"
  assert _s[1].script == "#!/usr/bin/env bash\nset -eo pipefail\nb", "explicit bash adds pipefail"
  assert _s[2].script == "#!/bin/sh\nset -e\nc"
  assert _s[3].script == "#!/usr/bin/env python3\nprint(1)"
  assert _fxBad(_fxOne([{run = "x", shell = "pwsh"}]))
}

test_step_condition_becomes_a_guard = lambda {
  _s = _fxTask(_fxOne([{run = "deploy", "if" = "\${{ github.event_name != 'pull_request' }}"}]), "build").taskSpec.steps[0]
  assert _s.script == "#!/usr/bin/env bash\n( [ \"{{ event_type }}\" != \"pull_request\" ] ) || exit 0\nset -e\ndeploy"
  assert len(_fxBad(_fxOne([{run = "x", "if" = "always()"}, {run = "y", "if" = "github.event_name == 'push' || failure()"}, {run = "z", "if" = False}]))) == 3
}

test_secrets_and_vars_come_from_kubernetes = lambda {
  _s = _fxTask(_fxOne([{
    run = "curl -H \"Authorization: \${{ secrets.API_TOKEN }}\" \${{ vars.URL }}"
    env = {GH = "\${{ secrets.GITHUB_TOKEN }}", PLAIN = "sha=\${{ github.sha }}", FLAG = True}
  }]), "build").taskSpec.steps[0]
  assert "curl -H \"Authorization: \${GHA_SECRET_API_TOKEN}\" \${GHA_VAR_URL}" in _s.script
  _env = {_e.name: _e for _e in _s.env}
  assert [_env.GHA_SECRET_API_TOKEN.valueFrom.secretKeyRef.name, _env.GHA_SECRET_API_TOKEN.valueFrom.secretKeyRef.key] == ["gha-secrets", "API_TOKEN"]
  assert [_env.GHA_VAR_URL.valueFrom.configMapKeyRef.name, _env.GHA_VAR_URL.valueFrom.configMapKeyRef.key] == ["gha-vars", "URL"]
  assert [_env.GH.valueFrom.secretKeyRef.name, _env.GH.valueFrom.secretKeyRef.key] == ["{{ git_auth_secret }}", "git-provider-token"], "GITHUB_TOKEN is the PaC git token"
  assert _env.PLAIN.value == "sha={{ revision }}"
  assert _env.FLAG.value == "true"
}

test_expressions_without_a_faithful_translation_are_unsupported = lambda {
  _bad = _fxBad(_fxOne([
    {run = "echo '\${{ secrets.T }}'"}
    {run = "echo \${{ steps.a.outputs.b }}"}
    {run = "echo x", env = {A = "Bearer \${{ secrets.T }}"}}
    {run = "echo hi >> \"$GITHUB_ENV\""}
    {run = "echo \${{ matrix.nope }}"}
  ]))
  assert len(_bad) == 5, "${_bad}"
  assert "single quotes" in _bad[0]
}

test_actions_map_or_fail = lambda {
  _t = _fxT(_fxOne([
    {uses = "actions/checkout@v4", "with" = {"fetch-depth" = 0, submodules = "recursive"}}
    {uses = "oven-sh/setup-bun@v2"}
    {uses = "acme/notify@v1", "with" = {channel = "#ci"}}
  ]))
  _s = _t.pipelineRun.spec.pipelineSpec.tasks[0].taskSpec.steps
  assert [_x.name for _x in _s] == ["checkout-0", "notify-2"], "a dropped action emits no step"
  assert "git fetch -q origin \"{{ revision }}\"" in _s[0].script, "fetch-depth 0 fetches full history"
  assert "git submodule update -q --init --recursive" in _s[0].script
  assert _s[1].image == "r/notify:1" and [[_e.name, _e.value] for _e in _s[1].env] == [["INPUT_CHANNEL", "#ci"]]
  assert [_i.status for _i in _t.report.items] == ["mapped", "mapped", "mapped"]
  assert len(_fxBad(_fxOne([{uses = "acme/unknown@v1"}, {uses = "./local"}, {uses = "actions/checkout@v4", "with" = {repository = "o/r"}}]))) == 3
}

test_render_refuses_partial_translations = lambda {
  _e = runtime.catch(lambda {
    render(_fxCfg, _fxOne([{uses = "acme/unknown@v1"}]), "w.yml")
  })
  assert "1 construct(s) do not translate" in _e and "no mapping for action acme/unknown" in _e, _e
  assert len(render(_fxCfg | {allowPartial = True}, _fxOne([{uses = "acme/unknown@v1"}]), "w.yml")) == 1
}
