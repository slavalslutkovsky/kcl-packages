import .serverless

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
# Every spec below carries resourceGroup: render() asserts on it ("the azure
# backend requires spec.resourceGroup") and KCL has no way to catch a failed
# assert inside a test, so the missing-group path is exercised by inspection
# (and by `kcl run` with the field removed), not by a test lambda.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "ServerlessApp", metadata.name = "demo", spec = _spec}
}

_by_kind = lambda _items, _k {
    _hits = [_i for _i in _items if _i.kind == _k]
    _hits[0] if _hits else Undefined
}

# The ContainerApp forProvider block from a render() of the given spec.
_fp = lambda _spec {
    _by_kind(serverless.render(_build(_spec)), "ContainerApp").spec.forProvider
}

_minimal = {image = "ghcr.io/acme/hello:1.0.0", region = "westeurope", resourceGroup = "demo-rg"}

# ---- render: shape ----------------------------------------------------------

# Minimal spec: the Environment then the ContainerApp, in that order.
test_render_minimal = lambda {
    items = serverless.render(_build(_minimal))
    assert len(items) == 2, "minimal render must emit the environment and the app"
    assert [_i.kind for _i in items] == ["Environment", "ContainerApp"], "kinds must be ordered environment-first"
    assert items[0].apiVersion == "containerapp.azure.m.upbound.io/v1beta1", "wrong environment apiVersion"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "environment", "environment must have a stable resource name"
    assert items[0].spec.forProvider.location == "westeurope", "region must be carried as the environment location"
    assert items[0].spec.forProvider.resourceGroupName == "demo-rg", "resource group must reach the environment"
    assert items[1].apiVersion == "containerapp.azure.m.upbound.io/v1beta1", "wrong app apiVersion"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "the app must be the managed resource"
    fp = items[1].spec.forProvider
    assert fp.resourceGroupName == "demo-rg", "resource group must reach the app"
    assert fp.containerAppEnvironmentIdSelector.matchControllerRef == True, "the app must bind to the environment by controller ref"
    assert fp.revisionMode == "Single", "revision mode must be Single"
}

# ---- render: container ------------------------------------------------------
test_container = lambda {
    fp = _fp(_minimal)
    _c = fp.template.container[0]
    assert len(fp.template.container) == 1, "exactly one container"
    assert _c.name == "demo", "container name must be the XR name"
    assert _c.image == "ghcr.io/acme/hello:1.0.0", "image must be carried"
    assert _c?.env == Undefined, "no env block unless asked for"
}

# env entries are sorted so the render is deterministic.
test_env_sorted = lambda {
    _c = _fp(_minimal | {
        env = {ZED = "1", ALPHA = "2"}
    }).template.container[0]
    assert len(_c.env) == 2, "two env vars -> two entries"
    assert _c.env[0].name == "ALPHA" and _c.env[0].value == "2", "env must be sorted by name"
    assert _c.env[1].name == "ZED" and _c.env[1].value == "1", "env values must be carried"
}

# ---- render: sizing ---------------------------------------------------------

# Container Apps only sells fixed cpu/memory pairs; the smallest pair
# satisfying BOTH requested dimensions wins, so requests only round up.
test_size_ladder = lambda {
    assert serverless.size_for(0.25, 512) == {cpu = 0.25, gi = 0.5, memory = "0.5Gi"}, "an exact pair must not round up"
    assert serverless.size_for(1, 512) == {cpu = 1, gi = 2, memory = "2Gi"}, "cpu=1 must drag memory up to its pair"
    assert serverless.size_for(0.25, 3072) == {cpu = 1.5, gi = 3, memory = "3Gi"}, "3 GiB must drag cpu up to its pair"
    assert serverless.size_for(0.6, 1024) == {cpu = 0.75, gi = 1.5, memory = "1.5Gi"}, "an off-ladder cpu must round up"
    assert serverless.size_for(4, 512) == {cpu = 2, gi = 4, memory = "4Gi"}, "above the ceiling must take the largest pair"
    _c = _fp(_minimal | {cpu = 0.5, memoryMb = 512}).template.container[0]
    assert _c.cpu == 0.5, "cpu=0.5/512Mi fits the 0.5/1Gi pair"
    assert _c.memory == "1Gi", "memory must be the pair's Gi literal"
    _d = _fp(_minimal).template.container[0]
    assert _d.cpu == 1, "defaults (cpu=1, 512Mi) must land on the 1/2Gi pair"
    assert _d.memory == "2Gi", "defaults must take the pair's memory"
}

# ---- render: scaling --------------------------------------------------------
test_scaling = lambda {
    t = _fp(_minimal).template
    assert t.minReplicas == 0, "minInstances must default to scale-to-zero"
    assert t?.maxReplicas == Undefined, "unset maxInstances must leave Azure's default cap"
    scaled = _fp(_minimal | {minInstances = 2, maxInstances = 10}).template
    assert scaled.minReplicas == 2, "minInstances must be carried"
    assert scaled.maxReplicas == 10, "maxInstances must be carried"
}

# ---- render: ingress --------------------------------------------------------
test_ingress_public_default = lambda {
    ing = _fp(_minimal).ingress
    assert ing.externalEnabled == True, "public must default to an external ingress"
    assert ing.targetPort == 8080, "port must default to 8080"
    assert len(ing.trafficWeight) == 1, "exactly one traffic weight"
    assert ing.trafficWeight[0].latestRevision == True, "all traffic must go to the latest revision"
    assert ing.trafficWeight[0].percentage == 100, "the latest revision must take 100%"
}

# public=false keeps the ingress, Environment-internal.
test_ingress_private = lambda {
    ing = _fp(_minimal | {public = False, port = 3000}).ingress
    assert ing.externalEnabled == False, "public=false must keep the ingress internal"
    assert ing.targetPort == 3000, "port must be carried"
}

# ---- render: tags -----------------------------------------------------------

# Tags must reach both MRs, or the Environment escapes cost attribution.
test_tags = lambda {
    items = serverless.render(_build(_minimal | {
        tags = {team = "web"}
    }))
    assert _by_kind(items, "Environment").spec.forProvider.tags == {team = "web"}, "tags must reach the environment"
    assert _by_kind(items, "ContainerApp").spec.forProvider.tags == {team = "web"}, "tags must reach the app"
    assert _fp(_minimal)?.tags == Undefined, "no tags unless asked for"
}

# ---- render: deletion policy ------------------------------------------------

# Orphan must reach the Environment too, or deleting the XR still drops the
# app's landing zone.
test_deletion_policy_orphan = lambda {
    items = serverless.render(_build(_minimal | {deletionPolicy = "Orphan"}))
    assert _by_kind(items, "ContainerApp").spec.managementPolicies == _orphan, "Orphan must set the non-delete policies"
    assert _by_kind(items, "Environment").spec.managementPolicies == _orphan, "Orphan must reach the environment"
}

test_deletion_policy_delete_default = lambda {
    items = serverless.render(_build(_minimal))
    assert items[0].spec.managementPolicies != _orphan, "Delete must not set the orphan policies"
    assert items[1].spec.managementPolicies != _orphan, "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = serverless.status(_build(_minimal), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "ServerlessApp", "dxr kind must echo the composite"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status?.host == Undefined, "no host before the app exists"
    assert dxr.status?.url == Undefined, "no url before the app exists"
    assert dxr.status?["cloud-url"] == Undefined, "no portal URL before the ARM id is observed"
}

test_status_observed = lambda {
    _arm_id = "/subscriptions/1/resourceGroups/demo-rg/providers/Microsoft.App/containerApps/demo"
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = _arm_id
                        latestRevisionFqdn = "demo--rev1.happysea-1.westeurope.azurecontainerapps.io"
                        ingress = {fqdn = "demo.happysea-1.westeurope.azurecontainerapps.io"}
                    }
                }
            }
        }
    }
    dxr = serverless.status(_build(_minimal), ocds)
    assert dxr.status.ready == True, "an observed FQDN must mark the app ready"
    assert dxr.status.host == "demo--rev1.happysea-1.westeurope.azurecontainerapps.io", "the latest revision FQDN must be the host"
    assert dxr.status.url == "https://demo--rev1.happysea-1.westeurope.azurecontainerapps.io", "url must be https on the host"
    assert dxr.status.id == _arm_id, "the ARM id must be surfaced"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#resource${_arm_id}", "portal URL must be built from the ARM id"
}

# Without a latest-revision FQDN yet, the stable ingress FQDN must serve.
test_status_ingress_fallback = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        ingress = {fqdn = "demo.happysea-1.westeurope.azurecontainerapps.io"}
                    }
                }
            }
        }
    }
    dxr = serverless.status(_build(_minimal), ocds)
    assert dxr.status.host == "demo.happysea-1.westeurope.azurecontainerapps.io", "the ingress FQDN must be the fallback host"
    assert dxr.status.ready == True, "the fallback host must still mark the app ready"
}

test_render_minimal()
test_container()
test_env_sorted()
test_size_ladder()
test_scaling()
test_ingress_public_default()
test_ingress_private()
test_tags()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_observed()
test_status_ingress_fallback()
