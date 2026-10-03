# Tests for the cncf package: the two charts as Flux objects, the runner
# presets, the local CA chain and the wildcard certificate.
# Run: kcl test
import yaml
import file
import app.lib as app

_kinds = lambda items: [any] -> [str] {
    [m.kind for m in items]
}
_named = lambda items: [any], name: str -> any {
    [t for t in items if t.metadata.name == name][0]
}
_release = lambda items: [any], name: str -> any {
    [t for t in items if t.kind == "HelmRelease" and t.metadata.name == name][0]
}

# ── kind: hostPort on the ingress-ready control-plane ────────────────────────
test_kind_render = lambda {
    c = Cncf {**yaml.decode("""\
name: dev
runner: kind
""")}
    out = render(c)
    assert _kinds(out) == ["HelmRepository", "HelmRepository", "HelmRelease", "HelmRelease", "ClusterIssuer", "ClusterIssuer", "Certificate", "Certificate"], "two charts, two issuers, two certificates, Flux objects first: ${_kinds(out)}"

    ctrl = _release(out, "ingress-nginx").spec.values.controller
    assert ctrl.hostPort.enabled == True and ctrl.service.type == "NodePort", "kind exposes the controller through hostPort, not a LoadBalancer"
    assert ctrl.nodeSelector["ingress-ready"] == "true", "the controller must land on the node whose 80/443 kind published"
    assert ctrl.tolerations[0].key == "node-role.kubernetes.io/control-plane", "that node is the control-plane"
    assert ctrl.extraArgs["publish-status-address"] == "localhost"
    assert ctrl.extraArgs["default-ssl-certificate"] == "ingress-nginx/wildcard-tls", "every dev Ingress serves the wildcard without its own Certificate"
    assert ctrl.ingressClass == "nginx" and ctrl.ingressClassResource.name == "nginx" and ctrl.ingressClassResource.default == True

    cm = _release(out, "cert-manager")
    assert cm.spec.values.crds.enabled == True, "the chart skips its CRDs by default and startupapicheck then fails"
    assert cm.spec.targetNamespace == "cert-manager"
    assert all_true([o.metadata.labels["platform.example.org/type"] == "application" for o in out if o.kind in ["HelmRepository", "HelmRelease"]]), "a developer cluster is a workload cluster: everything is application-typed"
    assert all_true([o.metadata.namespace == "flux-system" for o in out if o.kind in ["HelmRepository", "HelmRelease"]])
}

# ── k3d: a LoadBalancer Service behind the serverlb ──────────────────────────
test_k3d_render = lambda {
    out = render(Cncf {**yaml.decode("""\
name: dev
runner: k3d
""")})
    ctrl = _release(out, "ingress-nginx").spec.values.controller
    assert ctrl.service.type == "LoadBalancer", "k3s servicelb + the k3d serverlb publish 80/443, no hostPort needed"
    assert "hostPort" not in ctrl, "the kind preset must not leak into k3d: ${ctrl}"
    assert "nodeSelector" not in ctrl, "k3d has no ingress-ready node label"
    assert ctrl.extraArgs["default-ssl-certificate"] == "ingress-nginx/wildcard-tls", "the default certificate is runner-independent"
}

# ── The local PKI: self-signed root → CA issuer → wildcard ───────────────────
test_ca_chain = lambda {
    out = render(Cncf {**yaml.decode("""\
name: dev
runner: kind
""")})
    root = _named([o for o in out if o.kind == "ClusterIssuer"], "local-root")
    assert root.spec?.selfSigned != Undefined and root.spec?.ca == Undefined, "the root signs itself"
    ca = _named([o for o in out if o.kind == "ClusterIssuer"], "local-ca")
    assert ca.spec.ca.secretName == "local-ca-tls", "the ca issuer signs with the keypair the root produced"

    caCert = _named([o for o in out if o.kind == "Certificate"], "local-ca")
    assert caCert.spec.isCA == True and caCert.spec.secretName == "local-ca-tls"
    assert caCert.metadata.namespace == "cert-manager", "a ClusterIssuer only reads secrets from cert-manager's namespace"
    assert caCert.spec.issuerRef.name == "local-root" and caCert.spec.issuerRef.kind == "ClusterIssuer" and caCert.spec.issuerRef.group == "cert-manager.io", "issued by the self-signed root, cluster-scoped"
    assert caCert.spec.commonName == "dev local CA"

    wildcard = _named([o for o in out if o.kind == "Certificate"], "wildcard")
    assert wildcard.metadata.namespace == "ingress-nginx", "the default-ssl-certificate secret must live with the controller"
    assert wildcard.spec.dnsNames == ["*.localtest.me", "localtest.me"], "the wildcard and the apex: ${wildcard.spec.dnsNames}"
    assert wildcard.spec.secretName == "wildcard-tls"
    assert wildcard.spec.issuerRef.name == "local-ca", "issued by the local CA, not the root"

    # Custom names flow through every reference.
    custom = render(Cncf {**yaml.decode("""\
name: lab
runner: k3d
domain: 127.0.0.1.sslip.io
ingress: {namespace: edge}
certs: {namespace: pki, rootIssuer: r, caIssuer: c, caSecret: s}
""")})
    assert [o.metadata.name for o in custom if o.kind == "ClusterIssuer"] == ["r", "c"]
    assert _named([o for o in custom if o.kind == "ClusterIssuer"], "c").spec.ca.secretName == "s"
    customCa = _named([o for o in custom if o.kind == "Certificate"], "c")
    assert customCa.metadata.namespace == "pki" and customCa.spec.secretName == "s" and customCa.spec.issuerRef.name == "r"
    customWild = _named([o for o in custom if o.kind == "Certificate"], "wildcard")
    assert customWild.metadata.namespace == "edge" and customWild.spec.issuerRef.name == "c"
    assert customWild.spec.dnsNames == ["*.127.0.0.1.sslip.io", "127.0.0.1.sslip.io"]
    assert _release(custom, "ingress-nginx").spec.values.controller.extraArgs["default-ssl-certificate"] == "edge/wildcard-tls", "the default certificate follows the ingress namespace"
    assert _release(custom, "cert-manager").spec.targetNamespace == "pki"
}

# ── ingress.values is an overlay on the preset, not a replacement ────────────
test_ingress_values_override = lambda {
    out = render(Cncf {**yaml.decode("""\
runner: kind
ingress:
  values:
    controller:
      replicaCount: 2
      extraArgs:
        enable-ssl-passthrough: "true"
""")})
    ctrl = _release(out, "ingress-nginx").spec.values.controller
    assert ctrl.replicaCount == 2
    assert ctrl.hostPort.enabled == True, "an overlay must not drop the runner preset"
    assert ctrl.extraArgs["enable-ssl-passthrough"] == "true" and ctrl.extraArgs["publish-status-address"] == "localhost", "extraArgs deep-merges: ${ctrl.extraArgs}"
    assert ctrl.extraArgs["default-ssl-certificate"] == "ingress-nginx/wildcard-tls"
}

# ── Extra charts are passthrough Dependencies, after the two built-ins ───────
test_extra_dependencies = lambda {
    out = render(Cncf {**yaml.decode("""\
runner: kind
dependencies:
  - name: metrics-server
    type: application
    repo: https://kubernetes-sigs.github.io/metrics-server
""")})
    assert [o.metadata.name for o in out if o.kind == "HelmRelease"] == ["ingress-nginx", "cert-manager", "metrics-server"], "extras come after what the package owns"
    assert _release(out, "metrics-server").spec.targetNamespace == "metrics-server"
    assert _kinds(out)[-2::] == ["Certificate", "Certificate"], "the certificates stay last"
}

# ── openshift: no ingress-nginx, the router serves the wildcard ──────────────
test_openshift_render = lambda {
    out = render(Cncf {**yaml.decode("""\
name: dev
runner: openshift
domain: apps-crc.testing
""")})
    assert _kinds(out) == ["HelmRepository", "HelmRelease", "ClusterIssuer", "ClusterIssuer", "Certificate", "Certificate", "IngressController"], "one chart, two issuers, two certificates, then the router patch: ${_kinds(out)}"
    assert [o.metadata.name for o in out if o.kind == "HelmRelease"] == ["cert-manager"], "the OpenShift router is the ingress: ingress-nginx must not be delivered"

    wildcard = _named([o for o in out if o.kind == "Certificate"], "wildcard")
    assert wildcard.metadata.namespace == "openshift-ingress", "IngressController.spec.defaultCertificate is read from the router's namespace"
    assert wildcard.spec.secretName == "wildcard-tls"
    assert wildcard.spec.dnsNames == ["*.apps-crc.testing", "apps-crc.testing"], "the apps domain wildcard and its apex: ${wildcard.spec.dnsNames}"
    caCert = _named([o for o in out if o.kind == "Certificate"], "local-ca")
    assert caCert.metadata.namespace == "cert-manager", "the CA stays where a ClusterIssuer reads secrets, whatever the runner"

    ic = out[-1]
    assert ic.apiVersion == "operator.openshift.io/v1" and ic.kind == "IngressController"
    assert ic.metadata.name == "default" and ic.metadata.namespace == "openshift-ingress-operator", "the pre-existing singleton kubectl apply merges into"
    assert ic.spec.defaultCertificate.name == "wildcard-tls", "the router serves the wildcard the local CA signed"

    assert all_true([o.metadata.labels["platform.example.org/type"] == "application" for o in out if o.kind in ["HelmRepository", "HelmRelease"]]), "cert-manager is still a dependency, so the issuers render workload-typed"

    extra = render(Cncf {**yaml.decode("""\
runner: openshift
dependencies:
  - name: metrics-server
    type: application
    repo: https://kubernetes-sigs.github.io/metrics-server
""")})
    assert [o.metadata.name for o in extra if o.kind == "HelmRelease"] == ["cert-manager", "metrics-server"], "extras come after what the package owns"
    assert _kinds(extra)[-1] == "IngressController", "the router patch stays last"
}

# ── The shipped example and its k3d / openshift overlays ─────────────────────
test_example_valid = lambda {
    base = yaml.decode(file.read("examples/values.yaml"))
    c = Cncf {**base}
    out = render(c)
    assert _kinds(out) == ["HelmRepository", "HelmRepository", "HelmRelease", "HelmRelease", "ClusterIssuer", "ClusterIssuer", "Certificate", "Certificate"], "the example renders the documented stream: ${_kinds(out)}"
    assert c.name == "dev" and c.runner == "kind" and c.domain == "localtest.me"

    k3d = render(Cncf {**app.mergeValues(base, yaml.decode(file.read("examples/values.k3d.yaml")))})
    assert _kinds(k3d) == _kinds(out), "the overlay changes how ingress is exposed, nothing else"
    ctrl = _release(k3d, "ingress-nginx").spec.values.controller
    assert ctrl.service.type == "LoadBalancer" and "hostPort" not in ctrl, "runner: k3d swaps the preset wholesale"

    oc = Cncf {**app.mergeValues(base, yaml.decode(file.read("examples/values.openshift.yaml")))}
    assert oc.domain == "apps-crc.testing", "the overlay moves the wildcard onto the cluster's apps domain"
    assert _kinds(render(oc)) == ["HelmRepository", "HelmRelease", "ClusterIssuer", "ClusterIssuer", "Certificate", "Certificate", "IngressController"], "the openshift overlay drops ingress-nginx and appends the router patch: ${_kinds(render(oc))}"
}

# invalid inputs — a `domain` with a scheme, a wildcard, a port or a trailing
# dot, an extra dependency of type `manager`, an extra dependency named
# cert-manager or ingress-nginx, rootIssuer == caIssuer, `ingress.values` on
# runner openshift, a missing `runner` — are rejected by the schema `check`
# blocks.
test_kind_render()
test_k3d_render()
test_ca_chain()
test_ingress_values_override()
test_extra_dependencies()
test_openshift_render()
test_example_valid()
