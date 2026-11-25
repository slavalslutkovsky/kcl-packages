"""
Entry point for the `airflow-dags` package: one spec file in, one
{path, content} per DAG out.

  kcl run packages/airflow-dags -D values=<spec.yaml> --format json

`path` is relative to the DAGs folder (generated/<dag>.py). The workspace's
dags/scripts/generate.py runs this for every specs/*.yaml, formats the
sources with ruff and writes them; `--check` fails when generated/ is stale.

With no values file (e.g. `nx build airflow-dags`) this renders a built-in
demo so the build still smoke-tests the package.
"""

import .lib
import yaml
import file

_valuesPath = option("values", default="")
assert (not _valuesPath) or file.exists(_valuesPath), "spec file not found: '${_valuesPath}' (relative to current dir ${file.workdir()})."

_demo = {
  dags = [{
    id = "demo"
    tasks = [
      {id = "extract", callable = "demo_tasks.etl:extract", kwargs = {days = 7}}
      {id = "load", callable = "demo_tasks.etl:load", inputs = {rows = "extract"}}
      {id = "done", $type = "bash", command = "echo done", upstream = ["load"]}
    ]
  }]
}

_spec: lib.Spec = lib.Spec {**(yaml.decode(file.read(_valuesPath)) if _valuesPath else _demo)}

files = lib.render(_spec, _valuesPath or "the built-in demo")
