"""
The addon catalog: one `Addon` row per installable platform component, and
the API groups and kinds that pull it in.

Data only. Every chart version and default value is the one gitops installs on
mgmt today (vendor/gitops/platform/<op>/release.yaml and values/*.yaml), so a
client cluster runs what the platform team already runs and upgrades with it.
Lines that only make sense on mgmt are dropped, not guessed: `${VAR}`
substitutions from cluster-config, the HTTPRoutes and hostnames on
main-gateway, and Secrets that gitops generates beside the release
(README, "Dropped from gitops").

Crossplane providers are split per cloud and family (contract §5), so a
client only gets the providers of its main cloud. The platform XR APIs map
`spec.provider` to the operator it selects (`providers`), so an XCanary on
Flagger never installs Argo Rollouts.
"""
import yaml

# ── Schemas ──────────────────────────────────────────────────────────────────
schema Trigger:
    """
    What detection pulls an addon in. `group` matches one API group exactly,
    `suffix` every group ending in it (`.gatekeeper.sh`). `kinds` narrows
    either to those kinds; empty means every kind of the group.
    """
    group?: str
    suffix?: str
    kinds: [str] = []

    check:
        (group and not suffix) or (suffix and not group), "a trigger names exactly one of group or suffix"

schema Helm:
    """
    One Helm release. `id` tells the releases of one addon apart: the object
    is `<addon>-<id>`, or `<addon>` without one. `releaseName` is the Helm
    release (Service names hang off it, e.g. cert-manager-istio-csr); it
    defaults to the object name. `dependsOn` names sibling units by id.
    """
    id?: str
    repo: str
    chart: str
    version: str
    values: {str:any} = {}
    releaseName?: str
    dependsOn: [str] = []
    # Dapr's operator patches its own CRDs at startup, so gitops leaves them
    # alone on upgrade; every other chart keeps them in step.
    upgradeCrds: "CreateReplace" | "Skip" = "CreateReplace"

schema Kustomize:
    """
    One kustomize package. `platformPath` is a path in the platform repo
    (config.platformSource); otherwise `url` + `ref` + `path` is a git or
    oci:// source of its own. `substitute` feeds config.crossplane.vars to
    Flux postBuild / the flux-envsubst Argo CD plugin.
    """
    id?: str
    platformPath?: str
    url?: str
    ref?: str
    path?: str
    substitute: bool = False
    dependsOn: [str] = []
    # Nothing outside the addon waits for a leaf. A ClusterProviderConfig
    # needs the CRD its family Provider installs, so `config/<cloud>` comes
    # after the families; a family waiting on it would never start.
    leaf: bool = False

    check:
        (platformPath and not url) or (url and ref and path and not platformPath), "kustomize needs platformPath, or url + ref + path"

schema Manifests:
    """A plain YAML directory (no kustomization.yaml) at `url`@`ref`."""
    id?: str
    url: str
    ref: str
    path: str = "./"
    dependsOn: [str] = []

schema Addon:
    name: str
    namespace: str
    triggers: [Trigger] = []
    helm: [Helm] = []
    kustomize: [Kustomize] = []
    manifests: [Manifests] = []
    requires: [str] = []
    # Crossplane providers of one cloud: never installed unless the cloud is
    # config.cloud or in crossplane.extraClouds.
    cloud?: "gcp" | "aws" | "azure"
    # Platform XRs: spec.provider value -> addons it needs.
    providers: {str:[str]} = {}
    # Platform XRs whose Composition picks resources by runtime: cloud ->
    # addons it needs on that cloud.
    cloudRequires: {str:[str]} = {}

    check:
        len(helm) + len(kustomize) + len(manifests) > 0, "addon ${name} installs nothing"
        len([u.id for u in helm + kustomize + manifests if not u.id]) <= 1, "addon ${name}: at most one unit without an id"

# ── Constants ────────────────────────────────────────────────────────────────
platform_group = "platform.shluviza.com"

# Provider families per cloud (contract §5, platform/crossplane/providers).
families: {str:[str]} = {
    gcp = ["cloudplatform", "storage", "sql", "opentofu"]
    aws = ["s3", "glue", "iam"]
    azure = ["storage", "managedidentity", "authorization"]
}

# ── Helm-delivered operators ─────────────────────────────────────────────────
_operators: [Addon] = [
    {
        name = "kyverno"
        namespace = "kyverno"
        triggers = [{group = "kyverno.io"}, {group = "wgpolicyk8s.io"}, {suffix = ".kyverno.io"}]
        helm = [{
            repo = "https://kyverno.github.io/kyverno/"
            chart = "kyverno"
            version = "3.9.1"
            values = yaml.decode("""\
admissionController:
  replicas: 3
backgroundController:
  replicas: 2
  resources:
    limits: {memory: 512Mi}
    requests: {cpu: 100m, memory: 128Mi}
cleanupController:
  replicas: 2
reportsController:
  replicas: 2
  resources:
    limits: {memory: 512Mi}
    requests: {cpu: 100m, memory: 128Mi}
features:
  policyExceptions:
    enabled: true
    namespace: kyverno
""")
        }]
    }
    {
        name = "gatekeeper"
        namespace = "gatekeeper-system"
        triggers = [{suffix = ".gatekeeper.sh"}]
        helm = [{
            repo = "https://open-policy-agent.github.io/gatekeeper/charts"
            chart = "gatekeeper"
            version = "3.23.1"
            values = yaml.decode("""\
replicas: 2
validatingWebhookFailurePolicy: Ignore
validatingWebhookCheckIgnoreFailurePolicy: Ignore
validatingWebhookExemptNamespacesLabels:
  shluviza.com/tier: [platform]
  kubernetes.io/metadata.name:
    - kube-system
    - kube-public
    - kube-node-lease
    - flux-system
    - ci
    - flows
    - tekton-pipelines
    - tekton-pipelines-resolvers
    - gmp-system
    - gmp-public
    - gke-managed-system
    - gke-managed-cim
    - gke-managed-filestorecsi
    - gke-managed-networking-dra-driver
    - gke-managed-volumepopulator
disableMutation: true
upgradeCRDs:
  enabled: false
postInstall:
  labelNamespace:
    enabled: false
  probeWebhook:
    enabled: false
controllerManager:
  resources:
    requests: {cpu: 25m, memory: 256Mi}
    limits: {memory: 1Gi}
audit:
  resources:
    requests: {cpu: 300m, memory: 512Mi}
    limits: {memory: 1Gi}
""")
        }]
    }
    {
        name = "flagger"
        namespace = "flagger-system"
        triggers = [{group = "flagger.app"}]
        # meshProvider istio: Flagger routes canaries with Istio
        # VirtualServices (gitops: Kustomization flagger dependsOn istio).
        requires = ["istio"]
        helm = [
            {
                repo = "https://flagger.app"
                chart = "flagger"
                version = "1.45.0"
                values = {meshProvider = "istio"}
            }
            {
                id = "loadtester"
                repo = "https://flagger.app"
                chart = "loadtester"
                version = "0.39.0"
                releaseName = "loadtester"
            }
        ]
    }
    {
        name = "argo-rollouts"
        namespace = "argo-rollouts"
        triggers = [{group = "argoproj.io", kinds = ["Rollout", "AnalysisTemplate", "ClusterAnalysisTemplate", "AnalysisRun", "Experiment"]}]
        helm = [{
            repo = "https://argoproj.github.io/argo-helm"
            chart = "argo-rollouts"
            version = "2.43.12"
            values = yaml.decode("""\
controller:
  replicas: 1
  resources:
    requests: {cpu: 25m, memory: 128Mi}
    limits: {memory: 512Mi}
dashboard:
  enabled: true
  readonly: false
  resources:
    requests: {cpu: 10m, memory: 64Mi}
    limits: {memory: 256Mi}
""")
        }]
    }
    {
        name = "chaos-mesh"
        namespace = "chaos-mesh"
        triggers = [{group = "chaos-mesh.org"}]
        # webhook.certManager: the webhook and daemon certificates come from
        # cert-manager (gitops: chaos-mesh dependsOn cert-manager).
        requires = ["cert-manager"]
        helm = [{
            repo = "https://charts.chaos-mesh.org"
            chart = "chaos-mesh"
            version = "2.8.8"
            values = yaml.decode("""\
controllerManager:
  enableFilterNamespace: true
  replicaCount: 1
  resources:
    requests: {cpu: 25m, memory: 256Mi}
    limits: {memory: 512Mi}
chaosDaemon:
  runtime: containerd
  socketPath: /run/containerd/containerd.sock
  resources:
    requests: {cpu: 25m, memory: 64Mi}
    limits: {memory: 512Mi}
dashboard:
  securityMode: false
  service:
    type: ClusterIP
  resources:
    requests: {cpu: 10m, memory: 128Mi}
    limits: {memory: 512Mi}
dnsServer:
  create: false
webhook:
  certManager:
    enabled: true
""")
        }]
    }
    {
        name = "litmus"
        namespace = "litmus"
        triggers = [{group = "litmuschaos.io"}]
        # The chaos operator and its CRDs only; ChaosCenter (the UI, with its
        # MongoDB and generated admin Secret) stays on mgmt.
        helm = [{
            repo = "https://litmuschaos.github.io/litmus-helm/"
            chart = "litmus-core"
            version = "3.31.1"
            releaseName = "litmus-core"
            values = yaml.decode("""\
fullnameOverride: chaos-operator
operator:
  image:
    pullPolicy: IfNotPresent
runner:
  image:
    tag: 3.31.0
operatorMode: standard
resources:
  requests: {cpu: 25m, memory: 64Mi}
  limits: {memory: 128Mi}
policies:
  monitoring:
    disabled: true
""")
        }]
    }
    {
        name = "k6"
        namespace = "k6-system"
        triggers = [{group = "k6.io"}]
        helm = [{
            repo = "https://grafana.github.io/helm-charts"
            chart = "k6-operator"
            version = "4.7.0"
            releaseName = "k6-operator"
            # namespace.create stays false: the HelmRelease creates it.
            values = yaml.decode("""\
namespace:
  create: false
manager:
  logging:
    development: false
  podSecurityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containerSecurityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop: [ALL]
""")
        }]
    }
    {
        name = "testkube"
        namespace = "testkube"
        triggers = [{group = "testkube.io"}, {suffix = ".testkube.io"}]
        # Results go to a CloudNativePG Cluster the chart renders
        # (postgresqlOperatorCluster), reconciled by the cnpg operator.
        requires = ["cnpg"]
        helm = [{
            repo = "https://kubeshop.github.io/helm-charts"
            chart = "testkube"
            version = "2.15.3"
            values = yaml.decode("""\
testkube-api:
  nats:
    embedded: true
    enabled: false
  next:
    controllers:
      enabled: true
  analyticsEnabled: false
  resources:
    requests: {cpu: 50m, memory: 128Mi}
    limits: {memory: 512Mi}
  mongodb:
    enabled: false
  postgresql:
    enabled: true
    secretName: testkube-postgresql-app
    secretKey: uri
  minio:
    storage: 10Gi
    resources:
      requests: {cpu: 25m, memory: 128Mi}
      limits: {memory: 512Mi}
mongodb:
  enabled: false
cloudnative-pg:
  enabled: false
postgresqlOperatorCluster:
  enabled: true
  cluster:
    instances: 1
    enableSuperuserAccess: false
    resources:
      requests: {cpu: 50m, memory: 256Mi}
      limits: {memory: 1Gi}
    storage:
      size: 10Gi
    postgresql:
      parameters:
        max_connections: "100"
        shared_buffers: "64MB"
""")
        }]
    }
    {
        name = "kafka"
        namespace = "kafka"
        triggers = [{group = "kafka.strimzi.io"}]
        # platform/kafka/operator: Strimzi only. The `shluviza` Kafka
        # (../instance) and kafka-ui are mgmt's own.
        helm = [{
            repo = "https://strimzi.io/charts/"
            chart = "strimzi-kafka-operator"
            version = "1.3.1"
            releaseName = "strimzi"
            values = yaml.decode("""\
replicas: 1
extraEnvs:
  - name: STRIMZI_POD_SECURITY_PROVIDER_CLASS
    value: restricted
resources:
  requests:
    cpu: 50m
""")
        }]
    }
    {
        name = "nats"
        namespace = "nats"
        triggers = [{group = "jetstream.nats.io"}]
        # The server, and NACK, which owns jetstream.nats.io. NUI (the UI)
        # and the per-tenant accounts, whose passwords ESO generates, are
        # mgmt's own.
        helm = [
            {
                repo = "https://nats-io.github.io/k8s/helm/charts/"
                chart = "nats"
                version = "2.15.3"
                values = yaml.decode("""\
config:
  cluster:
    enabled:
      $tplYaml: "{{ gt (int .Values.config.cluster.replicas) 1 }}"
  jetstream:
    enabled: true
    fileStore:
      pvc:
        size: 20Gi
      maxSize: 18Gi
container:
  env:
    GOMEMLIMIT: 400MiB
  resources:
    requests: {cpu: 25m, memory: 128Mi}
    limits: {memory: 512Mi}
  merge:
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
reloader:
  merge:
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
    resources:
      requests: {cpu: 5m, memory: 16Mi}
      limits: {memory: 64Mi}
podTemplate:
  topologySpreadConstraints:
    kubernetes.io/hostname:
      maxSkew: 1
      whenUnsatisfiable: DoNotSchedule
  merge:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
natsBox:
  enabled: false
""")
            }
            {
                id = "nack"
                repo = "https://nats-io.github.io/k8s/helm/charts/"
                chart = "nack"
                version = "0.36.0"
                releaseName = "nack"
                dependsOn = ["nats"]
                values = yaml.decode("""\
jetstream:
  controlLoop: true
namespaced: true
resources:
  requests: {cpu: 10m, memory: 32Mi}
  limits: {memory: 128Mi}
""")
            }
        ]
    }
    {
        name = "cnpg"
        namespace = "cnpg-system"
        triggers = [{group = "postgresql.cnpg.io"}]
        helm = [{
            repo = "https://cloudnative-pg.github.io/charts"
            chart = "cloudnative-pg"
            version = "0.29.1"
            values = {replicaCount = 2}
        }]
    }
    {
        name = "cert-manager"
        namespace = "cert-manager"
        triggers = [{group = "cert-manager.io"}, {group = "acme.cert-manager.io"}]
        helm = [{
            repo = "https://charts.jetstack.io"
            chart = "cert-manager"
            version = "v1.21.2"
            values = {crds.enabled = True}
        }]
    }
    {
        name = "external-secrets"
        namespace = "external-secrets"
        triggers = [{group = "external-secrets.io"}, {suffix = ".external-secrets.io"}]
        helm = [{
            repo = "https://charts.external-secrets.io"
            chart = "external-secrets"
            version = "2.11.0"
        }]
    }
    {
        name = "keda"
        namespace = "keda"
        triggers = [{group = "keda.sh"}, {group = "eventing.keda.sh"}]
        helm = [{
            repo = "https://kedacore.github.io/charts"
            chart = "keda"
            version = "2.21.0"
            values = yaml.decode("""\
resources:
  operator:
    requests: {cpu: 20m, memory: 64Mi}
  metricServer:
    requests: {cpu: 20m, memory: 64Mi}
  webhooks:
    requests: {cpu: 10m, memory: 64Mi}
""")
        }]
    }
    {
        name = "dapr"
        namespace = "dapr-system"
        triggers = [{group = "dapr.io"}]
        helm = [{
            repo = "https://dapr.github.io/helm-charts/"
            chart = "dapr"
            version = "1.18.4"
            upgradeCrds = "Skip"
            values = yaml.decode("""\
global:
  ha:
    enabled: true
  logAsJson: true
  seccompProfile: RuntimeDefault
dapr_sidecar_injector:
  sidecarDropALLCapabilities: true
""")
        }]
    }
    {
        name = "istio"
        namespace = "istio-system"
        triggers = [{group = g} for g in ["networking.istio.io", "security.istio.io", "telemetry.istio.io", "extensions.istio.io"]]
        # istio-csr serves the mesh CA from cert-manager Issuers.
        requires = ["cert-manager"]
        # istiod first: it is the release `version`/`values` overrides reach.
        # Order is base -> csr -> istiod -> cni, ztunnel, by dependsOn.
        helm = [
            {
                id = "istiod"
                repo = "https://istio-release.storage.googleapis.com/charts"
                chart = "istiod"
                version = "1.30.5"
                releaseName = "istiod"
                dependsOn = ["base", "csr"]
                values = yaml.decode("""\
profile: ambient
global:
  caAddress: cert-manager-istio-csr.istio-system.svc:443
env:
  ENABLE_CA_SERVER: "false"
resources:
  requests: {cpu: 50m, memory: 256Mi}
gateways:
  seccompProfile:
    type: RuntimeDefault
pilot:
  cni:
    enabled: true
""")
            }
            {
                id = "base"
                repo = "https://istio-release.storage.googleapis.com/charts"
                chart = "base"
                version = "1.30.5"
                releaseName = "istio-base"
            }
            {
                id = "csr"
                repo = "https://charts.jetstack.io"
                chart = "cert-manager-istio-csr"
                version = "v0.18.0"
                releaseName = "cert-manager-istio-csr"
                dependsOn = ["base"]
                values = yaml.decode("""\
app:
  server:
    caTrustedNodeAccounts: istio-system/ztunnel
  tls:
    certificateDNSNames:
      - cert-manager-istio-csr.istio-system.svc
extraObjects:
  - |
    apiVersion: cert-manager.io/v1
    kind: Issuer
    metadata:
      name: selfsigned
      namespace: istio-system
    spec:
      selfSigned: {}
  - |
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: istio-ca
      namespace: istio-system
    spec:
      isCA: true
      commonName: istio-ca
      secretName: istio-ca
      duration: 87600h
      privateKey:
        algorithm: ECDSA
        size: 256
      subject:
        organizations:
          - cluster.local
          - cert-manager
      issuerRef:
        name: selfsigned
        kind: Issuer
        group: cert-manager.io
  - |
    apiVersion: cert-manager.io/v1
    kind: Issuer
    metadata:
      name: istio-ca
      namespace: istio-system
    spec:
      ca:
        secretName: istio-ca
""")
            }
            {
                id = "cni"
                repo = "https://istio-release.storage.googleapis.com/charts"
                chart = "cni"
                version = "1.30.5"
                releaseName = "istio-cni"
                dependsOn = ["istiod"]
                values = yaml.decode("""\
profile: ambient
resources:
  requests: {cpu: 20m, memory: 64Mi}
""")
            }
            {
                id = "ztunnel"
                repo = "https://istio-release.storage.googleapis.com/charts"
                chart = "ztunnel"
                version = "1.30.5"
                releaseName = "ztunnel"
                dependsOn = ["istiod"]
                values = yaml.decode("""\
caAddress: cert-manager-istio-csr.istio-system.svc:443
resources:
  requests: {cpu: 20m, memory: 64Mi}
""")
            }
        ]
    }
]

# ── Kustomize / manifests ────────────────────────────────────────────────────
_packages: [Addon] = [
    {
        name = "tekton"
        namespace = "tekton-pipelines"
        # gitops vendors Tekton Pipelines v1.16.0 and runs Pipelines-as-Code
        # on it; it installs no Tekton Triggers (README).
        triggers = [{group = "tekton.dev"}, {group = "triggers.tekton.dev"}]
        kustomize = [{platformPath = "./platform/tekton/pipelines"}]
    }
    {
        name = "gateway-api"
        namespace = "default"
        triggers = [{group = "gateway.networking.k8s.io"}]
        # v1.5.1: what Istio 1.30 requires (gitops README). The standard
        # channel's CRDs, a plain directory.
        manifests = [{
            url = "https://github.com/kubernetes-sigs/gateway-api"
            ref = "v1.5.1"
            path = "./config/crd/standard"
        }]
    }
    {
        name = "crossplane"
        namespace = "crossplane-system"
        triggers = [{group = g} for g in ["pkg.crossplane.io", "apiextensions.crossplane.io", "ops.crossplane.io", "protection.crossplane.io"]]
        helm = [{
            repo = "https://charts.crossplane.io/stable"
            chart = "crossplane"
            version = "2.4.0"
            values = yaml.decode("""\
resourcesCrossplane:
  requests: {cpu: 100m, memory: 1Gi}
  limits: {memory: 2Gi}
resourcesRBACManager:
  requests: {cpu: 10m, memory: 64Mi}
""")
        }]
        kustomize = [{id = "functions", platformPath = "./platform/crossplane/functions", dependsOn = ["crossplane"]}]
    }
    {
        name = "crossplane-keycloak"
        namespace = "crossplane-system"
        triggers = [{group = "keycloak.crossplane.io"}, {suffix = ".keycloak.crossplane.io"}, {suffix = ".keycloak.m.crossplane.io"}]
        requires = ["crossplane"]
        kustomize = [
            {platformPath = "./platform/crossplane/providers/keycloak", substitute = True}
            {id = "config", platformPath = "./platform/crossplane/config/keycloak", substitute = True, leaf = True, dependsOn = ["crossplane-keycloak"]}
        ]
    }
]

# ── Crossplane providers, per cloud and family ──────────────────────────────
# `crossplane-<cloud>` is the cloud's DeploymentRuntimeConfig (runtime/) and
# ClusterProviderConfig `default` (config/<cloud>): once per cloud, however
# many families it runs.
_clouds: [Addon] = [
    {
        name = "crossplane-${c}"
        namespace = "crossplane-system"
        cloud = c
        requires = ["crossplane"]
        kustomize = [
            {id = "runtime", platformPath = "./platform/crossplane/providers/${c}/runtime", substitute = True}
            {id = "config", platformPath = "./platform/crossplane/config/${c}", substitute = True, leaf = True}
        ]
    }
    for c in ["gcp", "aws", "azure"]
]

_families: [Addon] = [
    {
        name = "crossplane-${c}-${f}"
        namespace = "crossplane-system"
        cloud = c
        triggers = [{group = "opentofu.m.upbound.io"}, {group = "opentofu.upbound.io"}] if f == "opentofu" else [{group = "${f}.${c}.m.upbound.io"}, {group = "${f}.${c}.upbound.io"}]
        requires = ["crossplane", "crossplane-${c}"]
        kustomize = [{platformPath = "./platform/crossplane/providers/${c}/${f}", substitute = True}] + ([{id = "config", platformPath = "./platform/crossplane/config/opentofu", substitute = True, leaf = True, dependsOn = ["crossplane-${c}-${f}"]}] if f == "opentofu" else [])
    }
    for c, fs in families
    for f in fs
]

# ── Platform XR APIs (vendor/gitops/api/<x>) ────────────────────────────────
_api = lambda kind: str, requires: [str], providers: {str:[str]}, cloudRequires: {str:[str]} -> Addon {
    Addon {
        name = "api-${kind.lower()}"
        namespace = "crossplane-system"
        triggers = [{group = platform_group, kinds = [kind]}]
        requires = ["crossplane"] + requires
        providers = providers
        cloudRequires = cloudRequires
        kustomize = [{platformPath = "./api/${kind.lower()}"}]
    }
}

# spec.provider enums from each definition.yaml; `both` runs both operators.
# XDataLake composes, per runtime (platform-api packages/xdatalake/<cloud>):
# gcp Bucket + BucketIAMMember + OpenTofu Workspace; aws S3, Glue, IAM;
# azure Storage, ManagedIdentity, Authorization. XTenant composes XClusters
# and an External Secrets ClusterSecretStore.
_apis: [Addon] = [
    _api("XCanary", [], {"flagger" = ["flagger"], "argo-rollouts" = ["argo-rollouts"]}, {})
    _api("XChaosExperiment", [], {"chaos-mesh" = ["chaos-mesh"], litmus = ["litmus"], both = ["chaos-mesh", "litmus"]}, {})
    _api("XPolicy", [], {kyverno = ["kyverno"], gatekeeper = ["gatekeeper"], both = ["kyverno", "gatekeeper"]}, {})
    _api("XLoadTest", [], {k6 = ["k6"], testkube = ["testkube"]}, {})
    _api("XStream", [], {kafka = ["kafka"], nats = ["nats"]}, {})
    _api("XPostgres", [], {cnpg = ["cnpg"], cloudsql = ["crossplane-gcp-sql", "api-xpostgresinstance"]}, {})
    _api("XPostgresInstance", ["crossplane-gcp-sql"], {}, {})
    _api("XDataLake", [], {}, {
        gcp = ["crossplane-gcp-storage", "crossplane-gcp-opentofu"]
        aws = ["crossplane-aws-s3", "crossplane-aws-glue", "crossplane-aws-iam"]
        azure = ["crossplane-azure-storage", "crossplane-azure-managedidentity", "crossplane-azure-authorization"]
    })
    _api("XProject", ["crossplane-gcp-cloudplatform"], {}, {})
    _api("XTenant", ["external-secrets"], {}, {})
]

catalog: [Addon] = _operators + _packages + _clouds + _families + _apis
