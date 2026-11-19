# Tests for airflow-dags: what the generated Python says. Whether it type-checks
# and loads in Airflow is the workspace's dags project (pyright + DagBag).
# Run: kcl test
import yaml

_parse = lambda text: str -> Spec {
  Spec {**yaml.decode(text)}
}

_has = lambda src: str, line: str -> bool {
  line in src.split("\n")
}

# ── Graph: dependency order, XCom inputs, explicit upstream edges ────────────
test_graph = lambda {
  s = _parse("""\
dags:
  - id: etl.nightly
    tasks:
      - {id: load, callable: "pkg.etl:load", inputs: {rows: extract}}
      - {id: notify, type: bash, command: echo done, upstream: [load]}
      - {id: extract, callable: "pkg.etl:extract", kwargs: {days: 7}}
""")
  out = render(s, "specs/etl.yaml")
  assert [f.path for f in out] == ["generated/etl_nightly.py"], ". in a dag id becomes _ in the file name"
  src = out[0].content
  assert _has(src, "    extract = task(task_id=\"extract\")(pkg.etl.extract)(days=7)")
  assert _has(src, "    load = task(task_id=\"load\")(pkg.etl.load)(rows=cast(Any, extract))"), "an XCom input is passed as Any at run time"
  assert _has(src, "    _load = pkg.etl.load(rows=_extract)"), "and as the upstream's return value in the TYPE_CHECKING block"
  assert src.index("    extract = ") < src.index("    load = "), "inputs are defined before the task that reads them"
  assert _has(src, "    load >> notify")
  assert _has(src, "import pkg.etl")
}

# ── Literals and durations come out as valid Python ─────────────────────────
test_literals = lambda {
  src = render(_parse("""\
dags:
  - id: lit
    schedule: "0 3 * * *"
    startDate: "2026-02-05"
    retryDelay: 90s
    timeout: 2h
    tasks:
      - id: a
        callable: "pkg.m:f"
        kwargs: {flag: true, none: null, ratio: 1.5, names: [x, "y \\"q\\""], opts: {k: 1}}
        retries: 0
"""), "x")[0].content
  assert "flag=True, none=None, ratio=1.5, names=[\"x\", \"y \\\"q\\\"\"], opts={\"k\": 1}" in src, src
  assert "start_date=datetime(2026, 2, 5, tzinfo=UTC)" in src, "no leading-zero int literals"
  assert "\"retry_delay\": timedelta(seconds=90)" in src
  assert "dagrun_timeout=timedelta(hours=2)" in src
  assert "schedule=\"0 3 * * *\"" in src
  assert "retries=0" in src, "an explicit 0 is still written"
}

# ── KubernetesExecutor pod override ──────────────────────────────────────────
test_pod_override = lambda {
  src = render(_parse("""\
dags:
  - id: pod
    tasks:
      - id: heavy
        callable: "pkg.m:f"
        executor: KubernetesExecutor
        image: ghcr.io/acme/airflow:3.2.2
        requests: {cpu: 500m}
        limits: {memory: 1Gi}
"""), "x")[0].content
  assert "from kubernetes.client import models as k8s" in src
  assert "executor=\"KubernetesExecutor\", executor_config={\"pod_override\": k8s.V1Pod(spec=k8s.V1PodSpec(containers=[k8s.V1Container(name=\"base\", image=\"ghcr.io/acme/airflow:3.2.2\", resources=k8s.V1ResourceRequirements(requests={\"cpu\": \"500m\"}, limits={\"memory\": \"1Gi\"}))]))}" in src, src
}
