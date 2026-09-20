import file
import yaml
import models.v1alpha1.cloud_example_org_v1alpha1_landing_page as landing

# The shipped example XRs are instances of the generated schema: a field the
# XRD does not declare, or a mistyped one, fails here before it fails on the
# cluster — and proves models/ is in step with xrd.yaml.
test_examples_are_landing_pages = lambda {
    _files = ["examples/landing-aws.yaml", "examples/landing-azure.yaml", "examples/landing-gcp.yaml", "examples/landing-onprem.yaml"]
    _xrs = [landing.LandingPage {**yaml.decode(file.read(f))} for f in _files]
    assert len(_xrs) == 4
    assert all x in _xrs {x.kind == "LandingPage" and x.apiVersion == "cloud.example.org/v1alpha1"}
    assert all x in _xrs {x.spec.region != ""}, "region is required on every backend, even where it is ignored"
    assert all x in _xrs {x.spec.content.html != ""}, "a landing page without content is not a landing page"
    assert all x in _xrs {x.spec.crossplane.compositionSelector.matchLabels.provider != ""}, "each example must pick its backend"
}

# The azure example is the one that carries the Azure-only field, and its XR
# name must satisfy the storage-account naming rule the backend asserts.
test_azure_example_carries_resource_group = lambda {
    p = landing.LandingPage {**yaml.decode(file.read("examples/landing-azure.yaml"))}
    assert p.spec.resourceGroup == "platform-rg", "the azure backend cannot create the group, so the example must name an existing one"
    assert p.metadata.name == "acmelanding", "the XR name becomes the storage account name: 3-24 lowercase alphanumerics"
}

# The onprem example is the one that carries the in-cluster fields.
test_onprem_example_carries_cluster_fields = lambda {
    p = landing.LandingPage {**yaml.decode(file.read("examples/landing-onprem.yaml"))}
    assert p.spec.ingressClassName == "nginx" and p.spec.replicas == 2
    assert p.spec.tls.issuer == "letsencrypt-prod", "onprem TLS comes from a cert-manager issuer, not from a cloud"
    assert p.spec.cdn.ttlSeconds == 300, "ttlSeconds is the served Cache-Control here"
}

# Files may leave contentType out — the backends derive it from the extension —
# and every path is relative to the site root.
test_content_files_shape = lambda {
    p = landing.LandingPage {**yaml.decode(file.read("examples/landing-aws.yaml"))}
    paths = [f.path for f in p.spec.content.files]
    assert paths == ["styles.css", "404.html"]
    assert all f in p.spec.content.files {not f.path.startswith("/")}, "no leading slash: the path is the object key"
    assert all f in p.spec.content.files {f.contentType == Undefined}, "the shipped example relies on extension-derived MIME types"
}

test_defaults_match_xrd = lambda {
    # XRD defaults come through the generated schema, so a composer that omits a
    # field renders exactly what the API server would have filled in.
    p = landing.LandingPage {
        spec = {region = "us-east-1", content.html = "<h1>hi</h1>"}
    }
    assert p.spec.content.index == "index.html" and p.spec.content.errorDocument == "404.html"
    assert p.spec.ingressClassName == "nginx" and p.spec.replicas == 2
    assert p.spec.deletionPolicy == "Delete"

    # An absent OBJECT gets no defaults: the API server only fills fields of a
    # block that is present. That is why every backend re-defaults cdn/tls
    # itself instead of trusting the schema.
    assert p.spec.cdn == Undefined and p.spec.tls == Undefined
    q = landing.LandingPage {
        spec = {region = "us-east-1", content.html = "x", cdn = {}, tls = {}}
    }
    assert q.spec.cdn.enabled == True and q.spec.cdn.ttlSeconds == 3600 and q.spec.cdn.priceClass == "cheapest"
    assert q.spec.tls.enabled == True and q.spec.tls.issuer == "letsencrypt-prod"
}
