# Contract: ApiGateway (aws) renders exactly one quick-create HTTP API
# proxying every request to the backend URL, and surfaces the serving
# endpoint (plus id/arn/console URL once observed) back onto the composite.
import .apigateway

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "ApiGateway", metadata.name = "demo", spec = _spec}
}

_by_kind = lambda _items, _k {
    _hits = [_i for _i in _items if _i.kind == _k]
    _hits[0] if _hits else Undefined
}

# The API forProvider block from a render() of the given spec.
_fp = lambda _spec {
    apigateway.render(_build(_spec))[0].spec.forProvider
}

# ---- render: shape ----------------------------------------------------------

# Quick create means the API is the ONLY managed resource: AWS owns the
# integration, route, and stage it derives from target.
test_render_minimal = lambda {
    items = apigateway.render(_build({backendUrl = "https://backend.example.com", region = "us-east-1"}))
    assert len(items) == 1, "quick-create render must emit exactly the API"
    assert items[0].apiVersion == "apigatewayv2.aws.m.upbound.io/v1beta1", "wrong API apiVersion"
    assert items[0].kind == "API", "the MR must be the apigatewayv2 API"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "API must be the managed resource"
}

test_field_mapping = lambda {
    fp = _fp({backendUrl = "https://backend.example.com", region = "us-east-1"})
    assert fp.target == "https://backend.example.com", "backendUrl must be the quick-create target"
    assert fp.protocolType == "HTTP", "quick create only exists for HTTP APIs"
    assert fp.name == "demo", "API name must be the XR name"
    assert fp.region == "us-east-1", "region must be carried"
}

# ---- render: optional metadata -----------------------------------------------
test_description_and_tags = lambda {
    bare = _fp({backendUrl = "u", region = "r"})
    assert bare?.description == Undefined, "no description unless asked for"
    assert bare?.tags == Undefined, "no tags unless asked for"
    set = _fp({backendUrl = "u", region = "r", description = "public edge", tags = {team = "platform"}})
    assert set.description == "public edge", "description must be carried"
    assert set.tags == {team = "platform"}, "tags must be carried"
}

# ---- render: cors -------------------------------------------------------------
test_cors_absent = lambda {
    assert _fp({backendUrl = "u", region = "r"})?.corsConfiguration == Undefined, "no CORS block unless asked for"
}

test_cors_mapping = lambda {
    cc = _fp({backendUrl = "u", region = "r", cors = {
        allowOrigins = ["https://app.example.com"]
        allowMethods = ["GET", "POST"]
        allowHeaders = ["content-type"]
        exposeHeaders = ["x-request-id"]
        allowCredentials = True
        maxAgeSeconds = 600
    }}).corsConfiguration
    assert cc.allowOrigins == ["https://app.example.com"], "allowOrigins must be carried"
    assert cc.allowMethods == ["GET", "POST"], "allowMethods must be carried"
    assert cc.allowHeaders == ["content-type"], "allowHeaders must be carried"
    assert cc.exposeHeaders == ["x-request-id"], "exposeHeaders must be carried"
    assert cc.allowCredentials == True, "allowCredentials must be carried"
    assert cc.maxAge == 600, "maxAgeSeconds maps to maxAge"
}

# Unset sub-fields must stay unset so AWS keeps its own defaults.
test_cors_partial = lambda {
    cc = _fp({backendUrl = "u", region = "r", cors = {allowOrigins = ["*"]}}).corsConfiguration
    assert cc.allowOrigins == ["*"], "allowOrigins must be carried"
    assert cc?.allowMethods == Undefined, "no allowMethods unless asked for"
    assert cc?.allowHeaders == Undefined, "no allowHeaders unless asked for"
    assert cc?.exposeHeaders == Undefined, "no exposeHeaders unless asked for"
    assert cc?.allowCredentials == Undefined, "no allowCredentials unless asked for"
    assert cc?.maxAge == Undefined, "no maxAge unless asked for"
}

# ---- render: deletion policy -------------------------------------------------
test_deletion_policy_orphan = lambda {
    items = apigateway.render(_build({backendUrl = "u", region = "r", deletionPolicy = "Orphan"}))
    assert items[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies"
}

# The API schema defaults managementPolicies to ["*"] (full management), and
# KCL has no list `!=` — assert the default survives untouched instead.
test_deletion_policy_delete_default = lambda {
    items = apigateway.render(_build({backendUrl = "u", region = "r"}))
    assert items[0].spec.managementPolicies == ["*"], "Delete must keep the schema's full-management default"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = apigateway.status(_build({backendUrl = "u", region = "us-east-1"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "ApiGateway", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status?.url == Undefined, "no url before the API exists"
    assert dxr.status?.host == Undefined, "no host before the API exists"
    assert dxr.status?.arn == Undefined, "no arn before the API exists"
    assert dxr.status?["cloud-url"] == Undefined, "the console URL needs the observed API id"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = "a1b2c3"
                        arn = "arn:aws:apigateway:us-east-1::/apis/a1b2c3"
                        apiEndpoint = "https://a1b2c3.execute-api.us-east-1.amazonaws.com"
                        region = "us-east-1"
                    }
                }
            }
        }
    }
    dxr = apigateway.status(_build({backendUrl = "u", region = "us-east-1"}), ocds)
    assert dxr.status.ready == True, "an observed endpoint must mark the gateway ready"
    assert dxr.status.url == "https://a1b2c3.execute-api.us-east-1.amazonaws.com", "apiEndpoint must be the url"
    assert dxr.status.host == "a1b2c3.execute-api.us-east-1.amazonaws.com", "host must drop the https scheme"
    assert dxr.status.arn == "arn:aws:apigateway:us-east-1::/apis/a1b2c3", "observed arn must be surfaced"
    assert dxr.status.id == "a1b2c3", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://us-east-1.console.aws.amazon.com/apigateway/main/api-detail?api=a1b2c3&region=us-east-1", "observed id must key the console url"
}

test_render_minimal()
test_field_mapping()
test_description_and_tags()
test_cors_absent()
test_cors_mapping()
test_cors_partial()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_observed()
