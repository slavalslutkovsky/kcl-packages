import .apigateway

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
# Every spec below carries resourceGroup and publisherEmail: render() asserts
# on both ("the azure backend requires spec.resourceGroup" /
# "...spec.publisherEmail") and KCL has no way to catch a failed assert inside
# a test, so the missing-field paths are exercised by inspection (and by
# `kcl run` with a field removed), not by a test lambda.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "ApiGateway", metadata.name = "demo", spec = _spec}
}

_by_kind = lambda _items, _k {
    _hits = [_i for _i in _items if _i.kind == _k]
    _hits[0] if _hits else Undefined
}

# The composed resource carrying the given composition-resource-name.
_by_name = lambda _items, _n {
    _hits = [_i for _i in _items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == _n]
    _hits[0] if _hits else Undefined
}

_minimal = {backendUrl = "https://backend.example.com", region = "westeurope", resourceGroup = "demo-rg", publisherEmail = "owner@example.com"}

# ---- render: shape ----------------------------------------------------------

# Minimal spec: the service, the API, then one wildcard operation per method.
test_render_minimal = lambda {
    items = apigateway.render(_build(_minimal))
    assert len(items) == 9, "minimal render must emit the service, the API and 7 operations"
    assert [_i.kind for _i in items] == ["Management", "API", "APIOperation", "APIOperation", "APIOperation", "APIOperation", "APIOperation", "APIOperation", "APIOperation"], "kinds must be ordered service-first"
    assert items[0].apiVersion == "apimanagement.azure.m.upbound.io/v1beta1", "wrong service apiVersion"
    assert items[1].apiVersion == "apimanagement.azure.m.upbound.io/v1beta1", "wrong API apiVersion"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "the service must be the managed resource"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "api", "the API must have a stable resource name"
    assert _by_name(items, "cors") == Undefined, "no cors policy unless asked for"
}

# ---- render: service --------------------------------------------------------

# The service name IS the gateway hostname, so the external name must be
# pinned to the XR name rather than left to Crossplane's random suffix.
test_service = lambda {
    svc = _by_kind(apigateway.render(_build(_minimal)), "Management")
    assert svc.metadata.annotations["crossplane.io/external-name"] == "demo", "the service external name must be the XR name"
    fp = svc.spec.forProvider
    assert fp.location == "westeurope", "region must be carried as the service location"
    assert fp.resourceGroupName == "demo-rg", "resource group must reach the service"
    assert fp.publisherEmail == "owner@example.com", "publisher email must be carried"
    assert fp.publisherName == "demo", "publisher name must default to the XR name"
    assert fp.skuName == "Consumption_0", "the sku must be the serverless Consumption tier"
    assert fp?.tags == Undefined, "no tags unless asked for"
}

test_publisher_name_carried = lambda {
    fp = _by_kind(apigateway.render(_build(_minimal | {publisherName = "Acme Corp"})), "Management").spec.forProvider
    assert fp.publisherName == "Acme Corp", "an explicit publisher name must win over the default"
}

# ---- render: api ------------------------------------------------------------
test_api = lambda {
    _api = _by_kind(apigateway.render(_build(_minimal)), "API")
    assert _api.metadata.annotations["crossplane.io/external-name"] == "demo", "the API external name must be the XR name"
    fp = _api.spec.forProvider
    assert fp.apiManagementNameSelector.matchControllerRef == True, "the API must bind to the service by controller ref"
    assert fp.resourceGroupName == "demo-rg", "resource group must reach the API"
    assert fp.revision == "1", "the revision must be pinned to 1"
    assert fp.displayName == "demo", "display name must be the XR name"
    assert fp?.description == Undefined, "no description unless asked for"
    assert fp.path == "", "the API must serve at the gateway root"
    assert fp.protocols == ["https"], "the API must serve https only"
    assert fp.serviceUrl == "https://backend.example.com", "backendUrl must be the API's backend"
    assert fp.subscriptionRequired == False, "the endpoint must be open, not keyed"
}

test_api_description = lambda {
    fp = _by_kind(apigateway.render(_build(_minimal | {description = "demo API"})), "API").spec.forProvider
    assert fp.description == "demo API", "description must be carried onto the API"
}

# ---- render: operations -----------------------------------------------------

# APIM only routes declared operations, so every method needs its wildcard.
test_operations = lambda {
    items = apigateway.render(_build(_minimal))
    ops = [_i for _i in items if _i.kind == "APIOperation"]
    assert len(ops) == 7, "one wildcard operation per HTTP method"
    assert [_o.spec.forProvider.method for _o in ops] == ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], "operations must come in a fixed order"
    assert all _o in ops {_o.spec.forProvider.urlTemplate == "/*"}, "every operation must use the wildcard template"
    assert all _o in ops {_o.spec.forProvider.apiNameSelector.matchControllerRef == True}, "every operation must bind to the API by controller ref"
    assert all _o in ops {_o.spec.forProvider.apiManagementNameSelector.matchControllerRef == True}, "every operation must bind to the service by controller ref"
    assert all _o in ops {_o.spec.forProvider.resourceGroupName == "demo-rg"}, "resource group must reach every operation"
    _get = _by_name(items, "op-get")
    assert _get.metadata.annotations["crossplane.io/external-name"] == "get", "the operation id must be the lowercase method"
    assert _get.spec.forProvider.displayName == "GET /*", "the display name must carry method and template"
    _opt = _by_name(items, "op-options")
    assert _opt.metadata.annotations["crossplane.io/external-name"] == "options", "every method must have its op-<method> resource"
}

# ---- render: cors -----------------------------------------------------------
test_cors_full = lambda {
    items = apigateway.render(_build(_minimal | {
        cors = {
            allowOrigins = ["https://app.example.com", "https://admin.example.com"]
            allowMethods = ["GET", "POST"]
            allowHeaders = ["Content-Type"]
            exposeHeaders = ["X-Request-Id"]
            allowCredentials = True
            maxAgeSeconds = 300
        }
    }))
    assert len(items) == 10, "cors must add exactly one policy"
    pol = _by_name(items, "cors")
    assert pol.kind == "APIPolicy", "the cors resource must be an APIPolicy"
    fp = pol.spec.forProvider
    assert fp.apiNameSelector.matchControllerRef == True, "the policy must bind to the API by controller ref"
    assert fp.apiManagementNameSelector.matchControllerRef == True, "the policy must bind to the service by controller ref"
    assert fp.resourceGroupName == "demo-rg", "resource group must reach the policy"
    assert fp.xmlContent == "<policies><inbound><base /><cors allow-credentials=\"true\"><allowed-origins><origin>https://app.example.com</origin><origin>https://admin.example.com</origin></allowed-origins><allowed-methods preflight-result-max-age=\"300\"><method>GET</method><method>POST</method></allowed-methods><allowed-headers><header>Content-Type</header></allowed-headers><expose-headers><header>X-Request-Id</header></expose-headers></cors></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>", "the full cors block must render every optional piece"
}

# allowed-methods and allowed-headers are mandatory in APIM's cors policy, so
# leaving them unset must render a wildcard, never drop the element.
test_cors_minimal = lambda {
    pol = _by_name(apigateway.render(_build(_minimal | {
        cors = {allowOrigins = ["*"]}
    })), "cors")
    assert pol.spec.forProvider.xmlContent == "<policies><inbound><base /><cors><allowed-origins><origin>*</origin></allowed-origins><allowed-methods><method>*</method></allowed-methods><allowed-headers><header>*</header></allowed-headers></cors></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>", "a minimal cors block must fall back to wildcards and skip the optional pieces"
}

# allowCredentials=false is still an explicit choice and must render.
test_cors_credentials_false = lambda {
    pol = _by_name(apigateway.render(_build(_minimal | {
        cors = {allowOrigins = ["*"], allowCredentials = False}
    })), "cors")
    assert "allow-credentials=\"false\"" in pol.spec.forProvider.xmlContent, "an explicit false must render, not vanish"
}

# ---- render: tags -----------------------------------------------------------
test_tags = lambda {
    fp = _by_kind(apigateway.render(_build(_minimal | {
        tags = {team = "web"}
    })), "Management").spec.forProvider
    assert fp.tags == {team = "web"}, "tags must reach the service"
}

# ---- render: deletion policy ------------------------------------------------

# Orphan must reach every composed resource, or deleting the XR still drops
# part of the gateway.
test_deletion_policy_orphan = lambda {
    items = apigateway.render(_build(_minimal | {
        deletionPolicy = "Orphan"
        cors = {allowOrigins = ["*"]}
    }))
    assert len(items) == 10, "the orphan render must still carry every resource"
    assert all _i in items {_i.spec.managementPolicies == _orphan}, "Orphan must set the non-delete policies on every resource"
}

test_deletion_policy_delete_default = lambda {
    items = apigateway.render(_build(_minimal))
    assert all _i in items {_i.spec.managementPolicies != _orphan}, "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = apigateway.status(_build(_minimal), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "ApiGateway", "dxr kind must echo the composite"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status?.host == Undefined, "no host before the gateway exists"
    assert dxr.status?.url == Undefined, "no url before the gateway exists"
    assert dxr.status?.id == Undefined, "no id before the gateway exists"
    assert dxr.status?["cloud-url"] == Undefined, "no portal URL before the ARM id is observed"
}

test_status_observed = lambda {
    _arm_id = "/subscriptions/1/resourceGroups/demo-rg/providers/Microsoft.ApiManagement/service/demo"
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = _arm_id
                        gatewayUrl = "https://demo.azure-api.net"
                    }
                }
            }
        }
    }
    dxr = apigateway.status(_build(_minimal), ocds)
    assert dxr.status.ready == True, "an observed gateway URL must mark the gateway ready"
    assert dxr.status.url == "https://demo.azure-api.net", "the gateway URL must be the endpoint"
    assert dxr.status.host == "demo.azure-api.net", "the host must be the URL without the scheme"
    assert dxr.status.id == _arm_id, "the ARM id must be surfaced"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#resource${_arm_id}", "portal URL must be built from the ARM id"
}

test_render_minimal()
test_service()
test_publisher_name_carried()
test_api()
test_api_description()
test_operations()
test_cors_full()
test_cors_minimal()
test_cors_credentials_false()
test_tags()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_observed()
