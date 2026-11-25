# Tests for local-platform: the composition of cluster.kind, manager and the
# two generated apps. Run: kcl test
import yaml

_ids = lambda items: [any] -> [str] {
  ["${o.kind}/${o.metadata.name}" for o in items]
}
_one = lambda items: [any], kind: str, name: str -> any {
  [o for o in items if o.kind == kind and o.metadata.name == name][0]
}

# ── Kind: cluster sizing feeds cluster.kind, the database pool feeds postgres ──
test_kind_and_dedicated_postgres = lambda {
  p = Platform {**yaml.decode("""\
cluster: {name: dev, workers: 2, dbWorkers: 1, ingress: true}
""")}
  k = kindConfig(p)
  assert k.name == "dev"
  assert [n.role for n in k.nodes] == ["control-plane", "worker", "worker", "worker"], "1 control plane + 2 workers + 1 database worker"
  assert len(k.nodes[0].extraPortMappings) == 2, "ingress maps 80/443 on the control plane"
  db = _one(render(p), "Cluster", "platform-db")
  assert db.spec.affinity.nodeSelector == {dedicated = "database"}, "a database pool pins the Cluster to it"
  assert db.spec.affinity.tolerations[0].value == "database"
  plain = _one(render(Platform {}), "Cluster", "platform-db")
  assert not plain.spec.affinity, "no pool → no pinning"
}

# ── Flux: role filters manager rows; generated apps install everywhere ───────
test_flux_roles = lambda {
  _values = yaml.decode("""\
bundles: [platform]
dependencies:
  - {name: keda, type: application, repo: "https://kedacore.github.io/charts"}
""")
  releases = lambda p: Platform -> [str] {
    [o.metadata.name for o in render(p) if o.kind == "HelmRelease"]
  }
  assert releases(Platform {**_values, role = "manager"}) == ["keda", "metrics-server", "cloudnative-pg", "crossplane", "backstage", "cert-manager"], "explicit rows, generated apps, then bundle rows"
  assert releases(Platform {**_values, role = "workload"}) == ["keda", "metrics-server", "cloudnative-pg", "cert-manager"], "a workload cluster drops the manager-type rows"
  assert _ids(render(Platform {**_values, role = "workload"}))[-2::] == ["Namespace/platform", "Cluster/platform-db"], "the platform database follows the charts"
}

# ── Overrides: maps merge key by key, lists replace; explicit rows replace generated apps ──
test_overrides = lambda {
  p = Platform {**yaml.decode("""\
metricsServer:
  insecureKubeletTLS: false
  values:
    args: [--metric-resolution=30s]
    resources: {requests: {memory: 100Mi}}
postgres:
  values: {config: {clusterWide: false}}
  database:
    spec: {storage: {storageClass: fast}}
""")}
  ms = _one(render(p), "HelmRelease", "metrics-server").spec.values
  assert ms.args == ["--metric-resolution=30s"], "a list override replaces the generated list"
  assert ms.resources.requests == {cpu = "50m", memory = "100Mi"}, "a map override merges into the generated map"
  assert _one(render(p), "HelmRelease", "cloudnative-pg").spec.values.config.clusterWide == False
  assert _one(render(p), "HelmRelease", "cloudnative-pg").spec.values.crds.create == True, "untouched generated keys stay"
  storage = _one(render(p), "Cluster", "platform-db").spec.storage
  assert storage.size == "1Gi" and storage.storageClass == "fast", "spec override merges into the generated Cluster spec"

  pinned = Platform {**yaml.decode("""\
dependencies:
  - {name: metrics-server, type: application, repo: "https://example.org/charts", version: 3.12.0}
""")}
  hr = _one(render(pinned), "HelmRelease", "metrics-server")
  assert hr.spec.chart.spec.version == "3.12.0" and not hr.spec.values, "an explicit row replaces the generated app"
}

# ── Argo CD: one Application per chart, waves from dependsOn, OCI repo Secrets ──
test_argocd = lambda {
  p = Platform {**yaml.decode("""\
engine: argocd
bundles: [sre]
""")}
  out = render(p)
  assert all_true([o.metadata.namespace == "argocd" for o in out if o.kind in ["Application", "Secret"]]), "engine objects live in the argocd namespace"
  assert not [o for o in out if o.kind in ["HelmRelease", "HelmRepository"]], "no Flux objects under argocd"
  waves = {o.metadata.name: o.metadata.annotations["argocd.argoproj.io/sync-wave"] for o in out if o.kind in ["Application", "Cluster"]}
  assert waves["kube-prometheus-stack"] == "0" and waves["loki"] == "1" and waves["tempo"] == "1", "dependsOn depth → wave: ${waves}"
  assert waves["platform-db"] == str(int(waves["cloudnative-pg"]) + 1), "the Cluster syncs after its operator"
  kps = _one(out, "Application", "kube-prometheus-stack")
  assert kps.spec.source.repoURL == "ghcr.io/prometheus-community/charts", "Argo CD takes an OCI registry without the scheme"
  secret = _one(out, "Secret", "helm-oci-ghcr-io-prometheus-community-charts")
  assert secret.stringData.enableOCI == "true" and secret.metadata.labels["argocd.argoproj.io/secret-type"] == "repository"
}
