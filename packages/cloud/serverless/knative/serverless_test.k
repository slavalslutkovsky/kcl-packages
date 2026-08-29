# Contract: render() emits exactly one serving.knative.dev/v1 Service named
# after the XR, with the common ServerlessApp parameters mapped onto the
# revision template (autoscaling annotations as strings, visibility label for
# public=false), and status() reflects the Service's own reported URL.
import .serverless

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "ServerlessApp", metadata.name = "demo", spec = _spec}
}

# The single Service from a render() of the given spec.
_svc = lambda _spec {
    serverless.render(_build(_spec))[0]
}

# The container block of the rendered revision template.
_container = lambda _spec {
    _svc(_spec).spec.template.spec.containers[0]
}

_minimal = {image = "ghcr.io/acme/hello:1.2.0", region = "in-cluster"}

# ---- render: shape ----------------------------------------------------------

# Minimal spec: exactly one Service, named after the XR, carrying the image.
test_render_minimal = lambda {
    items = serverless.render(_build(_minimal))
    assert len(items) == 1, "minimal render must emit exactly one resource"
    assert [_i.kind for _i in items] == ["Service"], "the only resource must be a Service"
    assert items[0].apiVersion == "serving.knative.dev/v1", "wrong apiVersion"
    assert items[0].metadata.name == "demo", "Service name must follow the XR for a deterministic route"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].metadata?.namespace == Undefined, "namespace must be left to Crossplane"
    c = items[0].spec.template.spec.containers[0]
    assert c.image == "ghcr.io/acme/hello:1.2.0", "image must be carried"
}

# ---- render: autoscaling annotations ----------------------------------------

# Knative reads scaling knobs from annotations, so both bounds must be STRINGS.
test_scale_annotations = lambda {
    anno = _svc(_minimal | {minInstances = 2, maxInstances = 5}).spec.template.metadata.annotations
    assert anno["autoscaling.knative.dev/min-scale"] == "2", "min-scale must be the stringified minInstances"
    assert anno["autoscaling.knative.dev/max-scale"] == "5", "max-scale must be the stringified maxInstances"
}

# Unset bounds: min-scale defaults to "0" (scale to zero), max-scale must be
# absent so the autoscaler's own default stays in charge.
test_scale_defaults = lambda {
    anno = _svc(_minimal).spec.template.metadata.annotations
    assert anno["autoscaling.knative.dev/min-scale"] == "0", "min-scale must default to scale-to-zero"
    assert "autoscaling.knative.dev/max-scale" not in anno, "no max-scale unless asked for"
}

# ---- render: container mapping ----------------------------------------------
test_port_mapping = lambda {
    assert _container(_minimal).ports[0].containerPort == 8080, "port must default to 8080"
    assert _container(_minimal | {port = 3000}).ports[0].containerPort == 3000, "port must be carried"
}

# Env must come out sorted: any template diff stamps a new Revision, so map
# iteration order must never cause a spurious rollout.
test_env_mapping = lambda {
    c = _container(_minimal | {
        env = {ZED = "z", ALPHA = "a"}
    })
    assert len(c.env) == 2, "two vars in, two entries out"
    assert [_e.name for _e in c.env] == ["ALPHA", "ZED"], "env must be sorted by name"
    assert [_e.value for _e in c.env] == ["a", "z"], "env values must follow their names"
    assert _container(_minimal)?.env == Undefined, "no env block unless asked for"
}

# cpu/memory map onto container limits as Kubernetes quantities.
test_resource_limits = lambda {
    limits = _container(_minimal).resources.limits
    assert limits.cpu == "1", "cpu must default to 1 vCPU"
    assert limits.memory == "512Mi", "memory must default to 512Mi"
    custom = _container(_minimal | {cpu = 0.5, memoryMb = 256}).resources.limits
    assert custom.cpu == "0.5", "fractional cpu must format as a quantity string"
    assert custom.memory == "256Mi", "memoryMb must carry the Mi suffix"
}

test_timeout_and_service_account = lambda {
    tspec = _svc(_minimal).spec.template.spec
    assert tspec.timeoutSeconds == 60, "timeout must default to 60s"
    assert tspec?.serviceAccountName == Undefined, "no serviceAccountName unless asked for"
    custom = _svc(_minimal | {timeoutSeconds = 30, serviceAccount = "hello-runtime"}).spec.template.spec
    assert custom.timeoutSeconds == 30, "timeoutSeconds must be carried"
    assert custom.serviceAccountName == "hello-runtime", "serviceAccount must map to serviceAccountName"
}

# ---- render: visibility -----------------------------------------------------

# cluster-local is Knative's switch for a cluster-only route; public (the
# default) must leave the Service unlabeled.
test_visibility = lambda {
    private = _svc(_minimal | {public = False})
    assert private.metadata.labels["networking.knative.dev/visibility"] == "cluster-local", "public=false must label the Service cluster-local"
    assert _svc(_minimal).metadata?.labels == Undefined, "public default must leave no labels behind"
    assert _svc(_minimal | {public = True}).metadata?.labels == Undefined, "explicit public must leave no labels behind"
}

# tags become Service labels and must merge with, not replace, the visibility label.
test_tags_merge_with_visibility = lambda {
    labels = _svc(_minimal | {public = False, tags = {team = "platform"}}).metadata.labels
    assert labels["team"] == "platform", "tags must become labels"
    assert labels["networking.knative.dev/visibility"] == "cluster-local", "visibility must survive the tag merge"
}

# ---- render: deletion policy ------------------------------------------------

# In-cluster there are no managementPolicies to set: the Service lives and
# dies with the XR, so Orphan must render byte-identically to Delete.
test_deletion_policy_ignored = lambda {
    assert serverless.render(_build(_minimal | {deletionPolicy = "Orphan"})) == serverless.render(_build(_minimal)), "deletionPolicy is documented as ignored in-cluster"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = serverless.status(_build(_minimal), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "ServerlessApp", "dxr kind must echo the composite"
    assert dxr.status.provider == "knative", "provider must be knative"
    assert dxr.status.ready == False, "no reported URL must mean not ready"
    assert dxr.status?.url == Undefined, "no url before the route serves"
    assert dxr.status?.host == Undefined, "no host before the route serves"
    assert dxr.status.id == "demo", "the Service name is the in-cluster id"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {url = "https://demo.default.svc.example.com"}
            }
        }
    }
    dxr = serverless.status(_build(_minimal), ocds)
    assert dxr.status.ready == True, "a reported URL must mark the app ready"
    assert dxr.status.url == "https://demo.default.svc.example.com", "the Service's own URL must be surfaced"
    assert dxr.status.host == "demo.default.svc.example.com", "host must be the url minus its scheme"
    assert dxr.status?.arn == Undefined, "no arn in-cluster"
    assert dxr.status?["cloud-url"] == Undefined, "no cloud console to link to"
}

# ---- run --------------------------------------------------------------------
_run = [
    test_render_minimal()
    test_scale_annotations()
    test_scale_defaults()
    test_port_mapping()
    test_env_mapping()
    test_resource_limits()
    test_timeout_and_service_account()
    test_visibility()
    test_tags_merge_with_visibility()
    test_deletion_policy_ignored()
    test_status_pre_creation()
    test_status_observed()
]
