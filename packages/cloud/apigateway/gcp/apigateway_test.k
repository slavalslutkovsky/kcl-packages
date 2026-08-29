# Contract: ApiGateway (gcp) renders the per-API slice of an Apigee X runtime
# — environment, hostname-owning envgroup, their attachment, the backend
# TargetServer, and the instance attachment when an instance is named — and
# surfaces the serving hostname (plus the names a proxy bundle must target)
# back onto the composite.
import .apigateway

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "ApiGateway", metadata.name = "demo", spec = _spec}
}

# The minimum spec the gcp backend accepts.
_min = {backendUrl = "https://backend.example.com", region = "europe-west1", project = "proj", hostname = "api.example.com"}

_by_name = lambda _items, _n {
    _hits = [_i for _i in _items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == _n]
    _hits[0] if _hits else Undefined
}

_names = lambda _items {
    [_i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _i in _items]
}

# ---- render: shape ----------------------------------------------------------

# Without an instance name there is no instance attachment to render.
test_render_minimal = lambda {
    items = apigateway.render(_build(_min))
    assert len(items) == 4, "minimal render must emit envgroup, env, attachment and target only"
    assert _names(items) == ["managed", "env", "envgroup-attachment", "target"], "unexpected resource set: ${_names(items)}"
    assert _by_name(items, "managed").kind == "Envgroup", "the hostname-owning envgroup must be the managed resource"
    assert _by_name(items, "managed").apiVersion == "apigee.gcp.m.upbound.io/v1beta1", "wrong envgroup apiVersion"
    assert _by_name(items, "env").kind == "Environment", "env must be an Apigee Environment"
    assert _by_name(items, "envgroup-attachment").kind == "EnvgroupAttachment", "the attachment must be an EnvgroupAttachment"
    assert _by_name(items, "target").kind == "TargetServer", "the backend must be a TargetServer"
}

# The organization and the runtime instance are project-wide singletons: they
# are referenced, never composed.
test_render_composes_no_singletons = lambda {
    kinds = [i.kind for i in apigateway.render(_build(_min | {apigeeInstance = "runtime"}))]
    assert "Organization" not in kinds, "the Apigee organization must not be composed"
    assert "Instance" not in kinds, "the Apigee runtime instance must not be composed"
}

test_external_names = lambda {
    items = apigateway.render(_build(_min))
    _named = [n for n in ["managed", "env", "target"] if _by_name(items, n).metadata.annotations["crossplane.io/external-name"] == "demo"]
    assert len(_named) == 3, "every named resource must be addressed by the XR name, got ${_named}"
}

# ---- render: field mapping ---------------------------------------------------
test_envgroup_mapping = lambda {
    fp = _by_name(apigateway.render(_build(_min)), "managed").spec.forProvider
    assert fp.orgId == "organizations/proj", "the org id must be derived from spec.project"
    assert fp.hostnames == ["api.example.com"], "the envgroup must serve spec.hostname"
}

test_environment_mapping = lambda {
    fp = _by_name(apigateway.render(_build(_min | {description = "public edge"})), "env").spec.forProvider
    assert fp.orgId == "organizations/proj", "the env must live in the project's org"
    assert fp.displayName == "demo", "displayName must be the XR name"
    assert fp.description == "public edge", "description must be carried"
    # ARCHIVE environments cannot own target servers.
    assert fp.deploymentType == "PROXY", "the environment must accept proxy deployments"
}

test_description_absent = lambda {
    items = apigateway.render(_build(_min))
    assert _by_name(items, "env").spec.forProvider?.description == Undefined, "no env description unless asked for"
    assert _by_name(items, "target").spec.forProvider?.description == Undefined, "no target description unless asked for"
}

# Both ends of the attachment bind by controller ref so it waits for its parents.
test_attachment_binds_by_controller_ref = lambda {
    fp = _by_name(apigateway.render(_build(_min)), "envgroup-attachment").spec.forProvider
    assert fp.envgroupIdSelector.matchControllerRef == True, "the attachment must bind the composed envgroup"
    assert fp.environmentSelector.matchControllerRef == True, "the attachment must bind the composed environment"
    assert fp?.envgroupId == Undefined, "the envgroup must not be addressed by literal id"
    assert fp?.environment == Undefined, "the environment must not be addressed by literal name"
}

# ---- render: backend url -> target server ------------------------------------
test_target_https_default_port = lambda {
    fp = _by_name(apigateway.render(_build(_min)), "target").spec.forProvider
    assert fp.envIdSelector.matchControllerRef == True, "the target must live in the composed environment"
    assert fp.host == "backend.example.com", "the backend host must come from backendUrl"
    assert fp.port == 443, "https without a port must target 443"
    # There is no HTTPS protocol value — TLS is sSlInfo, protocol is the wire protocol.
    assert fp.$protocol == "HTTP", "protocol must be the wire protocol"
    assert fp.isEnabled == True, "the target must be in rotation"
    assert fp.sSlInfo.enabled == True, "an https backend must enable TLS"
    assert fp.sSlInfo.enforce == True, "TLS must be enforced, not best-effort"
}

test_target_plain_http = lambda {
    fp = _by_name(apigateway.render(_build(_min | {backendUrl = "http://backend.internal"})), "target").spec.forProvider
    assert fp.host == "backend.internal", "the backend host must come from backendUrl"
    assert fp.port == 80, "http without a port must target 80"
    assert fp?.sSlInfo == Undefined, "a plain http backend must leave TLS to the Apigee default"
}

test_target_explicit_port = lambda {
    assert _by_name(apigateway.render(_build(_min | {backendUrl = "https://backend.example.com:8443"})), "target").spec.forProvider.port == 8443, "an explicit port must win"
    assert _by_name(apigateway.render(_build(_min | {backendUrl = "http://backend.internal:8080"})), "target").spec.forProvider.port == 8080, "an explicit port must win"
}

# A trailing slash is the empty path, not a path.
test_target_trailing_slash = lambda {
    assert _by_name(apigateway.render(_build(_min | {backendUrl = "https://backend.example.com/"})), "target").spec.forProvider.host == "backend.example.com", "a trailing slash must be accepted"
}

# ---- render: instance attachment ----------------------------------------------
test_instance_attachment = lambda {
    items = apigateway.render(_build(_min | {apigeeInstance = "runtime"}))
    assert len(items) == 5, "naming an instance must add its attachment"
    fp = _by_name(items, "instance-attachment").spec.forProvider
    assert _by_name(items, "instance-attachment").kind == "InstanceAttachment", "the runtime binding must be an InstanceAttachment"
    assert fp.instanceId == "organizations/proj/instances/runtime", "the instance must be addressed by its documented id"
    assert fp.environmentSelector.matchControllerRef == True, "the attachment must bind the composed environment"
}

# ---- render: deletion policy -------------------------------------------------
test_deletion_policy_orphan = lambda {
    items = apigateway.render(_build(_min | {apigeeInstance = "runtime", deletionPolicy = "Orphan"}))
    _wrong = [i.kind for i in items if i.spec.managementPolicies != _orphan]
    assert _wrong == [], "Orphan must set the non-delete policies on every resource, missed ${_wrong}"
}

# The schemas default managementPolicies to ["*"] (full management) — assert
# the default survives untouched.
test_deletion_policy_delete_default = lambda {
    _wrong = [i.kind for i in apigateway.render(_build(_min)) if i.spec.managementPolicies != ["*"]]
    assert _wrong == [], "Delete must keep the schema's full-management default, changed on ${_wrong}"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = apigateway.status(_build(_min), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "ApiGateway", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status?.url == Undefined, "no url before the envgroup exists"
    assert dxr.status?.host == Undefined, "no host before the envgroup exists"
    assert dxr.status?.id == Undefined, "no id before the envgroup exists"
    # Names render() pins and the project-keyed console page are known up front.
    assert dxr.status.environment == "demo", "the environment name must be reported for the proxy bundle"
    assert dxr.status.targetServer == "demo", "the target server name must be reported for the proxy bundle"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/apigee/environment-groups?project=proj", "the console url is keyed by project alone"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = "organizations/proj/envgroups/demo"
                        hostnames = ["api.example.com"]
                        orgId = "organizations/proj"
                    }
                }
            }
        }
    }
    dxr = apigateway.status(_build(_min), ocds)
    assert dxr.status.ready == True, "an observed hostname must mark the gateway ready"
    assert dxr.status.url == "https://api.example.com", "the url must be the observed hostname over https"
    assert dxr.status.host == "api.example.com", "host must be the observed hostname"
    assert dxr.status.id == "organizations/proj/envgroups/demo", "observed id must be surfaced"
}

# An envgroup observed without hostnames serves nothing.
test_status_observed_without_hostnames = lambda {
    dxr = apigateway.status(_build(_min), {
        managed = {
            Resource = {
                status = {
                    atProvider = {id = "organizations/proj/envgroups/demo"}
                }
            }
        }
    })
    assert dxr.status.ready == False, "no hostname means not serving"
    assert dxr.status?.url == Undefined, "no url without a hostname"
    assert dxr.status.id == "organizations/proj/envgroups/demo", "observed id must be surfaced regardless"
}

test_render_minimal()
test_render_composes_no_singletons()
test_external_names()
test_envgroup_mapping()
test_environment_mapping()
test_description_absent()
test_attachment_binds_by_controller_ref()
test_target_https_default_port()
test_target_plain_http()
test_target_explicit_port()
test_target_trailing_slash()
test_instance_attachment()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_observed()
test_status_observed_without_hostnames()
