"""
Airflow DAGs from typed specs: KCL validates the graph, Python's type checker
validates the code.

  specs/*.yaml ──► Spec ──► render ──► [{path, content}] ──► generated/<dag>.py
                   (kcl run: ids, references, cycles, executors, durations)
                                       (pyright: arguments vs. the task functions)

A spec never contains Python. A `python` task names a plain, typed function
(`package.module:function`) importable from the DAGs folder, plus the literal
keyword arguments it is called with; `inputs` maps a parameter to the upstream
task whose return value it receives over XCom. The generated file wraps that
function with Airflow 3's TaskFlow decorator in its typed form,

    task(task_id="x")(module.fn)(arg=1)

so the type checker matches every literal argument against the function's
signature. XCom values are `XComArg` objects at DAG-parse time and match no
parameter type, so the runtime call passes them as `Any`. The edges are checked
instead in an `if TYPE_CHECKING:` block that replays the graph as direct calls
— `transform(rows=extract(...))` — where an upstream return type that does not
fit the downstream parameter is a type error. Nothing in that block runs.

What KCL rejects before any Python exists: duplicate dag / task ids, task ids
that are not Python names or shadow one the file imports (each task's variable
is its id, as ruff's AIR001 wants), upstream / inputs naming no task, inputs
from a non-python task, dependency cycles, an executor the cluster does not
run, pod overrides on a non-Kubernetes task, malformed cron / dates / durations.

Rendered by the DAGs project's writer (dags/scripts/generate.py in the
workspace), which runs ruff over the output and writes generated/:

  kcl run packages/airflow-dags -D values=<spec.yaml> --format json
  # in code:
  import airflow_dags.lib as dags; dags.render(dags.Spec {**values}, "specs/x.yaml")
"""

import json
import regex

# The mgmt cluster's Airflow: `executor: CeleryExecutor,KubernetesExecutor`
# (vendor/gitops platform/airflow/release/values/airflow.yaml). The first is the
# default; a task opts into another with `executor`.
default_executors = ["CeleryExecutor", "KubernetesExecutor"]

# KubernetesExecutor's task pod: pod_override patches the container named "base".
kubernetes_executor = "KubernetesExecutor"

# Airflow's KEY_REGEX for dag ids, and its 250-character limit.
_id_pattern = r"^[A-Za-z0-9_.-]{1,250}$"
_identifier = r"^[A-Za-z_][A-Za-z0-9_]*$"

# A task's variable is its id, so it may not be a keyword or a name the file
# imports (callable module roots are checked per DAG).
_reserved = ["DAG", "task", "BashOperator", "k8s", "datetime", "timedelta", "UTC", "TYPE_CHECKING", "Any", "cast"] + ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"]
_callable_pattern = r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*:[A-Za-z_][A-Za-z0-9_]*$"
_duration_pattern = r"^[0-9]+[smhd]$"
_date_pattern = r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
_presets = ["@once", "@continuous", "@hourly", "@daily", "@weekly", "@monthly", "@quarterly", "@yearly"]
_cron_pattern = r"^\S+(\s+\S+){4}$"

# ── Schemas ──────────────────────────────────────────────────────────────────
schema Resources:
  """Kubernetes quantities for the task pod's container."""
  cpu?: str
  memory?: str

  check:
    cpu or memory, "resources need cpu or memory"

schema Task:
  """
    One task. `python` (default) calls `callable` with `kwargs` + `inputs`;
    `bash` runs `command` through the standard provider's BashOperator.
    """
  id: str
  $type: "python" | "bash" = "python"

  # python: "package.module:function", a plain typed function (not @task-decorated)
  callable?: str
  # python: literal keyword arguments, checked against the signature
  kwargs: {str:} = {}
  # python: parameter → id of the python task whose return value it receives
  inputs: {str:str} = {}

  # bash
  command?: str
  # bash: added to the worker's environment (append_env)
  env: {str:str} = {}

  # ordering edges on top of the ones `inputs` already implies
  upstream: [str] = []
  # unset → the cluster's default executor
  executor?: str
  retries?: int
  # execution_timeout: <n>s | <n>m | <n>h | <n>d
  timeout?: str
  # KubernetesExecutor only: pod_override of the task pod's "base" container.
  # A custom image must still contain Airflow and this DAGs folder's imports.
  image?: str
  requests?: Resources
  limits?: Resources

  check:
    regex.match(id, _identifier) and len(id) <= 250, "task id '${id}' must be a Python identifier: it is also the task's variable in the generated file"
    id not in _reserved, "task id '${id}' would shadow a Python keyword or a name the generated file imports"
    $type != "python" or callable, "task ${id}: a python task needs `callable` (package.module:function)"
    not callable or regex.match(callable, _callable_pattern), "task ${id}: callable '${callable}' must be package.module:function"
    $type != "bash" or command, "task ${id}: a bash task needs `command`"
    $type == "bash" or not command, "task ${id}: `command` is a bash field"
    $type == "bash" or not env, "task ${id}: `env` is a bash field"
    $type == "python" or not (callable or kwargs or inputs), "task ${id}: callable / kwargs / inputs are python fields"
    all k in kwargs {regex.match(k, _identifier)}, "task ${id}: kwargs keys must be Python identifiers: ${[k for k in kwargs]}"
    all k in inputs {regex.match(k, _identifier)}, "task ${id}: inputs keys must be Python identifiers: ${[k for k in inputs]}"
    not any k in inputs {k in kwargs}, "task ${id}: a parameter is either a literal (kwargs) or an XCom input, not both"
    not timeout or regex.match(timeout, _duration_pattern), "task ${id}: timeout '${timeout}' must be <n>s|m|h|d"
    retries in [None, Undefined] or retries >= 0, "task ${id}: retries must be >= 0"
    executor == kubernetes_executor or not (image or requests or limits), "task ${id}: image / requests / limits patch the KubernetesExecutor's task pod; set executor: ${kubernetes_executor}"

schema Dag:
  """One DAG, one generated file: generated/<id with [.-] as _>.py."""
  id: str
  description?: str
  # cron (5 fields) or an Airflow preset (@daily, …); unset → triggered only
  schedule?: str
  # UTC, YYYY-MM-DD
  startDate: str = "2026-01-01"
  catchup: bool = False
  tags: [str] = []
  # default_args for every task
  owner: str = "airflow"
  retries: int = 0
  retryDelay: str = "5m"
  maxActiveRuns?: int
  # dagrun_timeout
  timeout?: str
  tasks: [Task]

  _ids = {t.id: t for t in tasks}
  _edges: {str:[str]} = {t.id: t.upstream + [s for _, s in t.inputs] for t in tasks}
  _depths: {str:int} = {t.id: _depth(_edges, t.id, len(tasks)) for t in tasks}

  check:
    regex.match(id, _id_pattern), "dag id '${id}' must match ${_id_pattern}"
    len(tasks) > 0, "dag ${id} has no tasks"
    len(tasks) == len(_ids), "dag ${id}: task ids must be unique"
    not any t in tasks {t.id in [_module(c).split(".")[0] for c in tasks if c.callable]}, "dag ${id}: a task id shadows the top-level package of a callable"
    all t in tasks {all u in _edges[t.id] {u in _ids}}, "dag ${id}: upstream / inputs name a task that does not exist: ${[u for t in tasks for u in _edges[t.id] if u not in _ids]}"
    all t in tasks {all _, s in t.inputs {s not in _ids or _ids[s].$type == "python"}}, "dag ${id}: inputs must come from python tasks (their return value is the XCom)"
    all _, d in _depths {d < len(tasks)}, "dag ${id}: dependency cycle in ${_edges}"
    not schedule or schedule in _presets or regex.match(schedule, _cron_pattern), "dag ${id}: schedule '${schedule}' must be a 5-field cron or one of ${_presets}"
    regex.match(startDate, _date_pattern), "dag ${id}: startDate '${startDate}' must be YYYY-MM-DD"
    regex.match(retryDelay, _duration_pattern), "dag ${id}: retryDelay '${retryDelay}' must be <n>s|m|h|d"
    not timeout or regex.match(timeout, _duration_pattern), "dag ${id}: timeout '${timeout}' must be <n>s|m|h|d"
    retries >= 0, "dag ${id}: retries must be >= 0"
    maxActiveRuns in [None, Undefined] or maxActiveRuns >= 1, "dag ${id}: maxActiveRuns must be >= 1"

schema Spec:
  """One spec file: the executors the target Airflow runs, and its DAGs."""
  executors: [str] = default_executors
  dags: [Dag]
  # "<dag>.<task>=<executor>" for every executor this Airflow does not run
  _unknown: [str] = [d.id + "." + t.id + "=" + t.executor for d in dags for t in d.tasks if t.executor and t.executor not in executors]

  check:
    len(dags) == len({d.id: 1 for d in dags}), "dag ids must be unique"
    len(dags) == len({fileName(d): 1 for d in dags}), "dag ids must stay unique as file names (. and - read as _)"
    not _unknown, "unknown executor; this Airflow runs ${executors}: ${_unknown}"

# ── Helpers ──────────────────────────────────────────────────────────────────
_ident = lambda s: str -> str {
  regex.replace(s, r"[^A-Za-z0-9_]", "_")
}

# Longest dependency chain below `n`, the topological rank. `budget` bounds the
# recursion; a cycle exhausts it and returns len(edges), which Dag rejects.
_depth = lambda edges: {str:[str]}, n: str, budget: int -> int {
  _next = [e for e in edges[n] if e in edges] if n in edges else []
  0 if not _next else len(edges) if budget <= 0 else 1 + max([_depth(edges, e, budget - 1) for e in _next])
}

fileName = lambda d: Dag -> str {
  """The generated file's stem."""
  _ident(d.id)
}

# A task's variable is its id; `_<id>` is its return value in the TYPE_CHECKING block.
_result = lambda id: str -> str {
  "_" + _ident(id)
}

# A YAML value as a Python literal. Strings go through JSON, whose escapes are
# all valid Python.
_py = lambda v: any -> str {
  _t = typeof(v)
  "None" if v in [None, Undefined] else ("True" if v else "False") if _t == "bool" else json.encode(v) if _t == "str" else str(v) if _t in ["int", "float"] else "[" + ", ".join([_py(x) for x in v]) + "]" if _t == "list" else "{" + ", ".join([json.encode(k) + ": " + _py(x) for k, x in v]) + "}"
}

_units = {s = "seconds", m = "minutes", h = "hours", d = "days"}

_timedelta = lambda d: str -> str {
  "timedelta(${_units[d[-1]]}=${int(d[:-1])})"
}

# int() drops leading zeros, which a Python int literal may not have.
_datetime = lambda d: str -> str {
  _p = d.split("-")
  "datetime(${int(_p[0])}, ${int(_p[1])}, ${int(_p[2])}, tzinfo=UTC)"
}

_module = lambda t: Task -> str {
  t.callable.split(":")[0]
}

_function = lambda t: Task -> str {
  t.callable.replace(":", ".")
}

_ordered = lambda d: Dag -> [Task] {
  """Tasks in dependency order: a task's inputs are defined before it."""
  [t for rank in range(len(d.tasks)) for t in d.tasks if d._depths[t.id] == rank]
}

_quantities = lambda r: Resources -> str {
  "{" + ", ".join([json.encode(k) + ": " + json.encode(v) for k, v in {cpu = r.cpu, memory = r.memory} if v]) + "}"
}

_podOverride = lambda t: Task -> str {
  _resources = (["requests=" + _quantities(t.requests)] if t.requests else []) + (["limits=" + _quantities(t.limits)] if t.limits else [])
  _container = ['name="base"'] + (["image=" + json.encode(t.image)] if t.image else []) + (["resources=k8s.V1ResourceRequirements(" + ", ".join(_resources) + ")"] if _resources else [])
  '{"pod_override": k8s.V1Pod(spec=k8s.V1PodSpec(containers=[k8s.V1Container(' + ", ".join(_container) + ")]))}"
}

_hasPod = lambda t: Task -> bool {
  bool(t.image or t.requests or t.limits)
}

# Arguments every operator takes, in the order they are written.
_operatorArgs = lambda t: Task -> [str] {
  ["task_id=" + json.encode(t.id)] + (["executor=" + json.encode(t.executor)] if t.executor else []) + (["executor_config=" + _podOverride(t)] if _hasPod(t) else []) + (["retries=${t.retries}"] if t.retries not in [None, Undefined] else []) + (["execution_timeout=" + _timedelta(t.timeout)] if t.timeout else [])
}

_kwargs = lambda t: Task -> [str] {
  ["${k}=${_py(v)}" for k, v in t.kwargs]
}

_taskLine = lambda t: Task -> str {
  _args = ", ".join(_operatorArgs(t))
  _call = ", ".join(_kwargs(t) + ["${k}=cast(Any, ${s})" for k, s in t.inputs])
  "    ${t.id} = task(${_args})(${_function(t)})(${_call})" if t.$type == "python" else "    ${t.id} = BashOperator(${_args}, bash_command=${json.encode(t.command)}" + (", env=${_py(t.env)}, append_env=True" if t.env else "") + ")"
}

_checkLine = lambda t: Task -> str {
  _call = ", ".join(_kwargs(t) + ["${k}=${_result(s)}" for k, s in t.inputs])
  "    ${_result(t.id)} = ${_function(t)}(${_call})"
}

_dagArgs = lambda d: Dag -> [str] {
  _default = '{"owner": ${json.encode(d.owner)}, "retries": ${d.retries}, "retry_delay": ${_timedelta(d.retryDelay)}}'
  ["dag_id=" + json.encode(d.id)] + (["description=" + json.encode(d.description)] if d.description else []) + ["schedule=" + (json.encode(d.schedule) if d.schedule else "None"), "start_date=" + _datetime(d.startDate), "catchup=" + _py(d.catchup), "tags=" + _py(d.tags)] + (["max_active_runs=${d.maxActiveRuns}"] if d.maxActiveRuns not in [None, Undefined] else []) + (["dagrun_timeout=" + _timedelta(d.timeout)] if d.timeout else []) + ["default_args=" + _default]
}

source = lambda d: Dag, origin: str -> str {
  """The Python source of one DAG file (unformatted; the writer runs ruff over it)."""
  _tasks = _ordered(d)
  _python = [t for t in _tasks if t.$type == "python"]
  _hasInputs = any t in _tasks {len(t.inputs) > 0}
  _typing = (["TYPE_CHECKING"] if _python else []) + (["Any", "cast"] if _hasInputs else [])
  _sdk = ["DAG"] + (["task"] if _python else [])
  _modules = sorted({_module(t): 1 for t in _python})
  _imports = ["from datetime import UTC, datetime, timedelta"] + (["from typing import " + ", ".join(_typing)] if _typing else []) + [""] + (["from airflow.providers.standard.operators.bash import BashOperator"] if any t in _tasks {t.$type == "bash"} else []) + ["from airflow.sdk import " + ", ".join(_sdk)] + (["from kubernetes.client import models as k8s"] if any t in _tasks {_hasPod(t)} else []) + ([""] + ["import ${m}" for m in _modules] if _modules else [])
  _check = (["", "", "if TYPE_CHECKING:", "    # The graph as direct calls, never run: every XCom edge is an upstream", "    # return value passed to a downstream parameter, checked by type."] + [_checkLine(t) for t in _python]) if _python else []
  _edges = ["    ${u} >> ${t.id}" for t in _tasks for u in t.upstream]
  _lines = ['"""DAG ${d.id}, generated from ${origin} by the airflow-dags KCL package. Do not edit."""', ""] + _imports + _check + ["", "", "with DAG(" + ", ".join(_dagArgs(d)) + "):"] + [_taskLine(t) for t in _tasks] + _edges
  "\n".join(_lines) + "\n"
}

# ── Public API ───────────────────────────────────────────────────────────────
render = lambda s: Spec, origin: str -> [{str:str}] {
  """One {path, content} per DAG; `path` is relative to the DAGs folder."""
  [{path = "generated/${fileName(d)}.py", content = source(d, origin)} for d in s.dags]
}
