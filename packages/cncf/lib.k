"""
CNCF application-management layer for a local developer cluster — typed
schemas + renderers (single source of truth).

Where `manager` describes any cluster's platform charts, `cncf` describes the
one cluster a developer runs on a laptop: ingress and TLS, and nothing that a
laptop cannot serve. One values.yaml, three concerns:

  • ingress → ingress-nginx, the controller every dev Ingress routes through,
    exposed the way the local runner can expose it. `runner` picks that:
      kind → the controller runs on the `ingress-ready` control-plane node with
             hostPort 80/443, which packages/cluster binds to the host when
             `ingress = true` in devkit.toml.
      k3d  → a LoadBalancer Service; k3s' servicelb claims node ports 80/443
             and the k3d serverlb container (`-p 80:80@loadbalancer`) proxies
             the host ports onto them. Disable traefik at cluster creation.
      openshift → OpenShift Local (CRC); the router already serves 80/443, so
             ingress-nginx is not rendered and the wildcard becomes the
             router's default certificate.
    `ingress.values` is deep-merged over the runner preset (right wins), so a
    values file can change anything in the chart without forking the preset.
  • certs → cert-manager plus the local PKI it exists for here. A self-signed
    ClusterIssuer (`rootIssuer`) signs a CA certificate into `caSecret` in
    cert-manager's own namespace — the only namespace a ClusterIssuer reads
    secrets from — and a `ca` ClusterIssuer (`caIssuer`) issues from that
    keypair. Trust `caSecret`'s tls.crt on the host (`just cncf-ca`) and every
    dev certificate below it is trusted, with no ACME and no public DNS.
  • domain → one wildcard Certificate `*.<domain>` from `caIssuer`, in the
    ingress namespace, set as ingress-nginx's `--default-ssl-certificate`.
    Every Ingress on the dev domain therefore serves a trusted certificate
    without naming an issuer or owning a Certificate of its own. The default
    `localtest.me` resolves `*.localtest.me` to 127.0.0.1 with no /etc/hosts.

On `openshift` the wildcard Certificate lives in `openshift-ingress` (the
router's namespace, where `IngressController.spec.defaultCertificate` is read
from) and the render ends with a partial `operator.openshift.io/v1`
IngressController named `default` in `openshift-ingress-operator` that sets
`defaultCertificate.name` to the wildcard secret; `kubectl apply` merges it
into the existing singleton. The domain must be the cluster's apps domain
(`apps-crc.testing` on CRC). Trusting the CA cluster-wide
(`proxy/cluster.spec.trustedCA`) needs the CA bytes and is done by
`just cncf-apply`, not the render.

Delivery is `manager`'s: the charts are `manager.Dependency` rows rendered as
Flux HelmRepository + HelmRelease pairs, the issuers are `manager.Issuer`
rows, and `manager.render` produces them in that order. Flux (source-controller
+ helm-controller) must already be on the cluster, exactly as for `manager`.
A developer cluster runs apps, so the Manager is `role: workload` and every
dependency — including the extra charts a values file adds under
`dependencies:` — is `type: application`.

Apply the render twice on a bare cluster: the ClusterIssuers and the two
Certificates are instances of CRDs the cert-manager chart installs, so the
first pass takes only what Flux understands and the second lands once
helm-controller reports both releases Ready. `just cncf-apply` does exactly
that; `just cncf-check` asserts what the package promises.

Rendered like `app` and `manager`:
`kcl run packages/cncf -D values=<file> [-D env=<env>]`, or in code
`import cncf.lib as cncf; cncf.render(cncf.Cncf {**values})`.
"""

import regex
import app.lib as app
import manager.lib as manager
import cert_manager.models.v1.cert_manager_io_v1_certificate as cmcert

# ── Schemas ──────────────────────────────────────────────────────────────────
schema Ingress:
    """ingress-nginx: the controller every dev Ingress routes through. `values` is deep-merged (right wins) over the runner preset. Ignored on runner: openshift except as documented on Cncf."""
    # chart version, https://kubernetes.github.io/ingress-nginx
    version: str = "4.15.1"
    namespace: str = "ingress-nginx"
    # → controller.ingressClassResource.name and controller.ingressClass
    className: str = "nginx"
    # → controller.ingressClassResource.default: an Ingress with no class uses it
    default: bool = True
    # deep-merged over the runner preset
    values: {str:} = {}

schema Certs:
    """cert-manager plus the local PKI: `rootIssuer` (self-signed) signs the CA in `caSecret`; `caIssuer` issues from it."""
    version: str = "1.21.1"
    # also cert-manager's cluster-resource namespace, where a ClusterIssuer's CA secret must live
    namespace: str = "cert-manager"
    rootIssuer: str = "local-root"
    caIssuer: str = "local-ca"
    caSecret: str = "local-ca-tls"
    values: {str:} = {}

    check:
        rootIssuer != caIssuer, "rootIssuer and caIssuer must be different ClusterIssuers"

schema Cncf:
    """One local developer cluster."""
    name: str = "cncf"

    # How ingress-nginx reaches the host: kind's hostPort on the ingress-ready
    # node, or k3d's LoadBalancer through the serverlb. openshift → OpenShift
    # Local (CRC); the router already serves 80/443, so ingress-nginx is not
    # rendered and the wildcard becomes the router's default certificate.
    runner: "kind" | "k3d" | "openshift"
    # the dev domain the wildcard certificate covers; *.localtest.me → 127.0.0.1
    domain: str = "localtest.me"
    # where the HelmRepository / HelmRelease objects live
    namespace: str = "flux-system"
    ingress: Ingress = Ingress {}
    certs: Certs = Certs {}
    # extra charts, any manager.Dependency; always application type
    dependencies: [manager.Dependency] = []

    check:
        regex.match(domain, r"^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$"), "domain must be a bare DNS name (no scheme, wildcard, port or trailing dot), got '${domain}'"
        all_true([d.$type == "application" for d in dependencies]), "cncf dependencies are application charts: a developer cluster is a workload cluster, set type: application"
        all_true([d.name not in ["ingress-nginx", "cert-manager"] for d in dependencies]), "ingress-nginx and cert-manager are rendered from `ingress:` / `certs:`; do not list them under dependencies"
        runner != "openshift" or ingress.values == {}, "ingress-nginx is not rendered on openshift (the router already serves 80/443): drop ingress.values"

# ── ingress-nginx values: one preset per runner ──────────────────────────────
# kind: the controller runs on the ingress-ready control-plane with hostPort
# 80/443 (packages/cluster binds them to the host when ingress = true). Same
# shape as kind's historical deploy-ingress-nginx.yaml.
_kindIngress = {
    controller = {
        hostPort = {enabled = True}
        service = {"type" = "NodePort"}
        nodeSelector = {"ingress-ready" = "true", "kubernetes.io/os" = "linux"}
        tolerations = [{key = "node-role.kubernetes.io/control-plane", operator = "Equal", effect = "NoSchedule"}]
        publishService = {enabled = False}
        extraArgs = {"publish-status-address" = "localhost"}
        terminationGracePeriodSeconds = 0
        updateStrategy = {"type" = "RollingUpdate", rollingUpdate = {maxUnavailable = 1}}
    }
}

# k3d: k3s servicelb gives the LoadBalancer Service node ports 80/443, and the
# k3d serverlb container (-p 80:80@loadbalancer -p 443:443@loadbalancer)
# proxies the host ports to them. traefik is disabled at cluster creation
# (`just cncf-up k3d`).
_k3dIngress = {
    controller = {
        service = {"type" = "LoadBalancer"}
    }
}

# openshift: no preset — the router is the ingress. See _manager.
_ingressValues = lambda c: Cncf -> {str:} {
    _preset = _kindIngress if c.runner == "kind" else _k3dIngress
    _common = {
        controller = {
            ingressClass = c.ingress.className
            ingressClassResource = {name = c.ingress.className, default = c.ingress.default}
            # every Ingress on the dev domain gets the wildcard without its own Certificate
            extraArgs = {"default-ssl-certificate" = "${c.ingress.namespace}/wildcard-tls"}
        }
    }
    app.mergeValues(app.mergeValues(_preset, _common), c.ingress.values)
}

# ── The Manager this package composes ────────────────────────────────────────
# The names are load-bearing: manager._issuerType looks for a dependency
# literally named `cert-manager` to decide that the issuers render on a
# workload cluster.
_ingressDependency = lambda c: Cncf -> manager.Dependency {
    manager.Dependency {
        name = "ingress-nginx"
        $type = "application"
        repo = "https://kubernetes.github.io/ingress-nginx"
        version = c.ingress.version
        namespace = c.ingress.namespace
        values = _ingressValues(c)
    }
}

# crds.enabled: the chart skips its CRDs by default and its startupapicheck job
# then fails (same note as packages/manager/examples/values.yaml).
_certsDependency = lambda c: Cncf -> manager.Dependency {
    manager.Dependency {
        name = "cert-manager"
        $type = "application"
        repo = "https://charts.jetstack.io"
        version = c.certs.version
        namespace = c.certs.namespace
        values = app.mergeValues({
            crds = {enabled = True}
        }, c.certs.values)
    }
}

_manager = lambda c: Cncf -> manager.Manager {
    manager.Manager {
        name = c.name
        role = "workload"
        namespace = c.namespace
        dependencies = ([] if c.runner == "openshift" else [_ingressDependency(c)]) + [_certsDependency(c)] + c.dependencies
        issuers = [
            manager.Issuer {name = c.certs.rootIssuer, $type = "self-signed"}
            manager.Issuer {name = c.certs.caIssuer, $type = "ca", caSecret = c.certs.caSecret}
        ]
    }
}

# ── Certificates (cert-manager) ──────────────────────────────────────────────
_labels = lambda c: Cncf -> {str:str} {
    {"app.kubernetes.io/managed-by" = "cncf", "app.kubernetes.io/part-of" = c.name, "platform.example.org/type" = "application"}
}

# Where the wildcard secret must live: with ingress-nginx, or with the router
# (IngressController.spec.defaultCertificate is read from openshift-ingress).
_wildcardNamespace = lambda c: Cncf -> str {
    "openshift-ingress" if c.runner == "openshift" else c.ingress.namespace
}

# The CA the `ca` issuer signs with: self-signed by rootIssuer into caSecret,
# in cert-manager's namespace because that is where a ClusterIssuer reads
# secrets. Ten years: a laptop CA nobody wants to re-trust every quarter.
_caCertificate = lambda c: Cncf -> cmcert.Certificate {
    cmcert.Certificate {
        metadata = {name = c.certs.caIssuer, namespace = c.certs.namespace, labels = _labels(c)}
        spec = {
            isCA = True
            commonName = "${c.name} local CA"
            secretName = c.certs.caSecret
            duration = "87600h"
            privateKey = {algorithm = "ECDSA", size = 256}
            issuerRef = {name = c.certs.rootIssuer, kind = "ClusterIssuer", group = "cert-manager.io"}
        }
    }
}

# *.<domain> from the local CA: ingress-nginx's default-ssl-certificate, or the
# router's defaultCertificate on openshift.
_wildcardCertificate = lambda c: Cncf -> cmcert.Certificate {
    cmcert.Certificate {
        metadata = {name = "wildcard", namespace = _wildcardNamespace(c), labels = _labels(c)}
        spec = {
            secretName = "wildcard-tls"
            dnsNames = ["*.${c.domain}", c.domain]
            issuerRef = {name = c.certs.caIssuer, kind = "ClusterIssuer", group = "cert-manager.io"}
        }
    }
}

# ── OpenShift router (operator.openshift.io) ─────────────────────────────────
# The router's default certificate: a partial IngressController that kubectl
# apply merges into the pre-existing `default` singleton (client-side apply
# patches only the fields listed here). Untyped on purpose: `kcl import -m crd`
# 0.12.10 emits invalid KCL for this CRD (the httpCompression.mimeTypes
# pattern carries unescaped quotes), so packages/providers has no openshift
# row. Revisit when kcl import is fixed.
_ingressController = lambda c: Cncf -> {str:} {
    {
        apiVersion = "operator.openshift.io/v1"
        kind = "IngressController"
        metadata = {name = "default", namespace = "openshift-ingress-operator", labels = _labels(c)}
        spec = {
            defaultCertificate = {name = "wildcard-tls"}
        }
    }
}

# ── Public API ───────────────────────────────────────────────────────────────
render = lambda c: Cncf -> [any] {
    """
    HelmRepositories, HelmReleases and the two ClusterIssuers (from
    manager.render), then the CA and wildcard Certificates.

    Apply twice on a bare cluster: the issuers and the certificates are
    instances of the CRDs the cert-manager chart installs, so the first pass
    can only land the Flux objects. The render is idempotent.

    On openshift the stream ends with the IngressController patch.
    """
    manager.render(_manager(c)) + [_caCertificate(c), _wildcardCertificate(c)] + ([_ingressController(c)] if c.runner == "openshift" else [])
}
