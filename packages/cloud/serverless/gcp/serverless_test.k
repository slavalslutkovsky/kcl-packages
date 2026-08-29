# Contract: ServerlessApp (gcp) renders a Cloud Run v2 Service named after
# the XR (external-name pinned), plus an allUsers invoker IAM binding when
# public, and surfaces the serving URI back onto the composite.
import .serverless

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "ServerlessApp", metadata.name = "demo", spec = _spec}
}

_by_kind = lambda _items, _k {
    _hits = [_i for _i in _items if _i.kind == _k]
    _hits[0] if _hits else Undefined
}

# The V2Service forProvider block from a render() of the given spec.
_fp = lambda _spec {
    serverless.render(_build(_spec))[0].spec.forProvider
}

# ---- render: shape ----------------------------------------------------------

# Minimal spec is public by default: V2Service + invoker binding, in order.
test_render_minimal = lambda {
    items = serverless.render(_build({image = "gcr.io/demo/app", region = "us-central1"}))
    assert len(items) == 2, "minimal (public) render must emit the service and the invoker binding"
    assert items[0].apiVersion == "cloudrun.gcp.m.upbound.io/v1beta1", "wrong service apiVersion"
    assert items[0].kind == "V2Service", "first MR must be the V2Service"
    assert items[1].kind == "ServiceIAMMember", "second MR must be the invoker binding"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "service must be the managed resource"
    fp = items[0].spec.forProvider
    assert fp.location == "us-central1", "region must map to location"
    assert fp.template.containers[0].image == "gcr.io/demo/app", "image must be carried"
}

# The service name must be deterministic (the XR name), or the IAM member
# could never address it by coordinates.
test_external_name_pinned = lambda {
    items = serverless.render(_build({image = "gcr.io/demo/app", region = "us-central1"}))
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "external-name must pin the service name to the XR name"
}

# ---- render: container ------------------------------------------------------
test_port_mapping = lambda {
    assert _fp({image = "i", region = "r"}).template.containers[0].ports.containerPort == 8080, "port must default to 8080"
    assert _fp({image = "i", region = "r", port = 3000}).template.containers[0].ports.containerPort == 3000, "port must be carried"
}

# Cloud Run resource limits are k8s quantity strings, not numbers.
test_resources = lambda {
    limits = _fp({image = "i", region = "r"}).template.containers[0].resources.limits
    assert limits.cpu == "1", "cpu must default to 1 and render as a string"
    assert limits.memory == "512Mi", "memory must default to 512Mi"
    custom = _fp({image = "i", region = "r", cpu = 2, memoryMb = 2048}).template.containers[0].resources.limits
    assert custom.cpu == "2", "cpu must render as a string"
    assert custom.memory == "2048Mi", "memoryMb maps to Mi verbatim"
}

# env renders in sorted key order so the diff is stable across reconciles.
test_env_sorted = lambda {
    c = _fp({image = "i", region = "r", env = {B = "2", A = "1"}}).template.containers[0]
    assert len(c.env) == 2, "every env entry must be carried"
    assert c.env[0].name == "A" and c.env[0].value == "1", "env must be sorted by key"
    assert c.env[1].name == "B" and c.env[1].value == "2", "env values must be carried"
    assert _fp({image = "i", region = "r"}).template.containers[0]?.env == Undefined, "no env block unless asked for"
}

# ---- render: scaling ---------------------------------------------------------

# Unset maxInstances must leave Cloud Run's own quota-derived default.
test_scaling = lambda {
    s = _fp({image = "i", region = "r"}).template.scaling
    assert s.minInstanceCount == 0, "minInstances must default to 0"
    assert s?.maxInstanceCount == Undefined, "no max cap unless asked for"
    set = _fp({image = "i", region = "r", minInstances = 1, maxInstances = 5}).template.scaling
    assert set.minInstanceCount == 1, "minInstances must be carried"
    assert set.maxInstanceCount == 5, "maxInstances must be carried"
}

# ---- render: timeout and identity -------------------------------------------
test_timeout = lambda {
    assert _fp({image = "i", region = "r"}).template.timeout == "60s", "timeout must default to 60s as a duration string"
    assert _fp({image = "i", region = "r", timeoutSeconds = 300}).template.timeout == "300s", "timeoutSeconds must be carried"
}

test_service_account = lambda {
    assert _fp({image = "i", region = "r"})?.template?.serviceAccount == Undefined, "no runtime identity unless asked for"
    assert _fp({image = "i", region = "r", serviceAccount = "sa@p.iam.gserviceaccount.com"}).template.serviceAccount == "sa@p.iam.gserviceaccount.com", "serviceAccount must be carried"
}

# ---- render: exposure --------------------------------------------------------

# public flips both knobs: ingress AND the allUsers invoker binding.
test_public_default = lambda {
    items = serverless.render(_build({image = "i", region = "r"}))
    assert items[0].spec.forProvider.ingress == "INGRESS_TRAFFIC_ALL", "public must open ingress"
    member = _by_kind(items, "ServiceIAMMember")
    assert member != Undefined, "public must add the invoker binding"
    assert member.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "invoker", "invoker must have a stable resource name"
    assert member.spec.forProvider.service == "demo", "binding must address the pinned service name"
    assert member.spec.forProvider.location == "r", "binding must live in the service's region"
    assert member.spec.forProvider.role == "roles/run.invoker", "binding must grant the invoker role"
    assert member.spec.forProvider.member == "allUsers", "public means allUsers"
}

test_private = lambda {
    items = serverless.render(_build({image = "i", region = "r", public = False}))
    assert len(items) == 1, "private render must not emit an invoker binding"
    assert items[0].spec.forProvider.ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY", "private must close ingress"
}

# ---- render: deletion policy -------------------------------------------------

# Orphan must reach the invoker too, or deleting the XR still drops the
# public binding out from under an orphaned service.
test_deletion_policy_orphan = lambda {
    items = serverless.render(_build({image = "i", region = "r", deletionPolicy = "Orphan"}))
    assert items[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies"
    assert _by_kind(items, "ServiceIAMMember").spec.managementPolicies == _orphan, "Orphan must reach companions"
}

test_deletion_policy_delete_default = lambda {
    items = serverless.render(_build({image = "i", region = "r"}))
    assert items[0].spec.managementPolicies != _orphan, "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = serverless.status(_build({image = "i", region = "us-central1"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "ServerlessApp", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status?.url == Undefined, "no url before the service exists"
    assert dxr.status?.host == Undefined, "no host before the service exists"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/run/detail/us-central1/demo", "cloud-url is known ahead of creation, without a project qualifier"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = "projects/my-proj/locations/us-central1/services/demo"
                        uri = "https://demo-abc123-uc.a.run.app"
                        location = "us-central1"
                        project = "my-proj"
                    }
                }
            }
        }
    }
    dxr = serverless.status(_build({image = "i", region = "us-central1"}), ocds)
    assert dxr.status.ready == True, "an observed uri must mark the app ready"
    assert dxr.status.url == "https://demo-abc123-uc.a.run.app", "uri must be the url"
    assert dxr.status.host == "demo-abc123-uc.a.run.app", "host must drop the https scheme"
    assert dxr.status.id == "projects/my-proj/locations/us-central1/services/demo", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/run/detail/us-central1/demo?project=my-proj", "observed project must qualify the console url"
}

test_render_minimal()
test_external_name_pinned()
test_port_mapping()
test_resources()
test_env_sorted()
test_scaling()
test_timeout()
test_service_account()
test_public_default()
test_private()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_observed()
