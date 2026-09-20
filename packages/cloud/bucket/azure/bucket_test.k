import .bucket

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

test_render = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1"}}
    items = bucket.render(oxr)
    assert len(items) == 1, "expected one managed resource"
    assert items[0].apiVersion == "storage.azure.m.upbound.io/v1beta1"
    assert items[0].kind == "Account"
    assert items[0].metadata.annotations?["crossplane.io/external-name"] == Undefined, "a created account pins nothing"
}

test_storage_class = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1", storageClass = "archive"}}
    items = bucket.render(oxr)
    assert len(items) == 2, "expected account + management policy"
    assert items[1].kind == "ManagementPolicy"
    assert items[0].spec.forProvider.accessTier == "Cold", "archive accessTier -> Cold"
}

test_tags = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1", tags = {team = "platform"}}}
    assert bucket.render(oxr)[0].spec.forProvider.tags == {team = "platform"}, "tags -> forProvider.tags"
}

test_deletion_policy = lambda {
    assert bucket.render({metadata.name = "demo", spec = {region = "westeurope", deletionPolicy = "Orphan"}})[0].spec.managementPolicies == _orphan, "Orphan -> orphan policies"
    assert bucket.render({metadata.name = "demo", spec = {region = "westeurope"}})[0].spec.managementPolicies == ["*"], "Delete -> provider default"
}

# Adopting pins external-name to the account name and carries the resource
# group the ARM id needs; observe mode is read-only and drops the lifecycle
# companion, manage mode renders it under the usual policies.
test_import = lambda {
    obs = bucket.render({metadata.name = "demo", spec = {region = "westeurope", storageClass = "archive", import = {existingName = "legacyst01", resourceGroup = "rg-legacy", source = "terraform", address = "azurerm_storage_account.legacy"}}})
    assert len(obs) == 1, "observe mode must not render the lifecycle companion"
    assert obs[0].metadata.annotations["crossplane.io/external-name"] == "legacyst01", "existingName -> external-name"
    assert obs[0].metadata.annotations["cloud.example.org/imported-from"] == "terraform", "source recorded"
    assert obs[0].spec.forProvider.resourceGroupName == "rg-legacy", "import.resourceGroup -> resourceGroupName"
    assert obs[0].spec.managementPolicies == ["Observe"], "import defaults to observe-only"
    man = bucket.render({metadata.name = "demo", spec = {region = "westeurope", storageClass = "archive", deletionPolicy = "Orphan", import = {existingName = "legacyst01", resourceGroup = "rg-legacy", mode = "manage"}}})
    assert len(man) == 2, "manage mode renders the lifecycle companion"
    assert man[0].spec.managementPolicies == _orphan and man[1].spec.managementPolicies == _orphan, "manage + Orphan -> orphan policies on both"
    assert man[1].metadata.annotations?["crossplane.io/external-name"] == Undefined, "the policy is identified through its account, never pinned"
}

test_mode_of = lambda {
    assert bucket.mode_of({
        spec = {region = "westeurope"}
    }) == "created"
    assert bucket.mode_of({
        spec = {region = "westeurope", import = {existingName = "x"}}
    }) == "observe"
    assert bucket.mode_of({
        spec = {region = "westeurope", import = {existingName = "x", mode = "manage"}}
    }) == "managed"
}

test_render()
test_storage_class()
test_tags()
test_deletion_policy()
test_import()
test_mode_of()
