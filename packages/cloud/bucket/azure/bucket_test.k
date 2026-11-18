import .bucket
import crypto
import runtime

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

# ---- spec.access ---------------------------------------------------------------

_main = "repo:acme/app:ref:refs/heads/main"
_prod = "repo:acme/app:environment:prod"
_gh = {client = "github", owner = "acme", role = "write", subjects = [_main, _prod]}
_jira = {client = "github", ticket = "jira", workflows = ["acme/ops/.github/workflows/jira.yml"], role = "admin", subjects = ["repo:acme/ops:job_workflow_ref:acme/ops/.github/workflows/jira.yml@refs/heads/main"]}
_account_id = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/demost"

_xr = lambda access: [any], extra: {str:} -> {str:} {
    {metadata.name = "demo", spec = {region = "westeurope", federation = {azureResourceGroup = "rg-ci"}, access = access} | extra}
}

_seen = lambda at: {str:} -> {str:} {
    {Resource.status.atProvider = at}
}

_names = lambda items: [any] -> [str] {
    [_i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _i in items]
}

_by_name = lambda items: [any] -> {str:} {
    {_i.metadata.annotations["krm.kcl.dev/composition-resource-name"]: _i for _i in items}
}

_err = lambda f -> str {
    runtime.catch(f) or ""
}

# A schema instance's set fields as a plain dict, for whole-value comparison.
_set = lambda s: any -> {str:} {
    {_k: _v for _k, _v in s if _v != None and _v != Undefined}
}

test_access_none = lambda {
    assert bucket.render_access({metadata.name = "demo", spec = {region = "westeurope"}}, {}) == [], "no access -> nothing"
    assert bucket.render_access(_xr([], {}), {}) == [], "empty access -> nothing"
    assert "access" not in bucket.status({metadata.name = "demo", spec = {region = "westeurope"}}, {}).status, "no access -> no status.access"
}

# Before anything is observed only the identities exist.
test_access_identities_first = lambda {
    items = bucket.render_access(_xr([_gh, _jira], {tags = {team = "platform"}}), {})
    assert [_i.kind for _i in items] == ["UserAssignedIdentity", "UserAssignedIdentity"], "only identities before observation, got ${[_i.kind for _i in items]}"
    assert _names(items) == ["access-github-actions-pool", "access-jira-github"]
    fp = items[0].spec.forProvider
    assert fp.name == "demo-github-actions-pool" and fp.location == "westeurope" and fp.resourceGroupName == "rg-ci"
    assert fp.tags == {team = "platform", "access-for" = "GitHub Actions"}, "spec.tags + access-for"
    assert items[1].spec.forProvider.tags["access-for"] == "Jira via GitHub Actions"
    assert items[0].spec.managementPolicies == ["*"], "Delete -> provider default"
    orphan = bucket.render_access(_xr([_gh], {deletionPolicy = "Orphan"}), {})
    assert orphan[0].spec.managementPolicies == _orphan, "Orphan -> orphan policies"
    # import.resourceGroup is the fallback.
    imp = bucket.render_access({metadata.name = "demo", spec = {region = "westeurope", access = [_gh], import = {existingName = "legacyst01", resourceGroup = "rg-legacy", mode = "manage"}}}, {})
    assert imp[0].spec.forProvider.resourceGroupName == "rg-legacy"
}

# Once the identity is observed: one credential per subject, parented on its id.
test_access_credentials_after_identity = lambda {
    items = bucket.render_access(_xr([_gh], {}), {"access-github-actions-pool" = _seen({id = "/uai/gh"})})
    byn = _by_name(items)
    assert len(items) == 3, "identity + 2 credentials, no grant without principal/account"
    assert all _s in [_main, _prod] {
        byn["access-github-actions-pool-${crypto.sha256(_s)[:8]}"].kind == "FederatedIdentityCredential"
    }
    assert all _s in [_main, _prod] {
        byn["access-github-actions-pool-${crypto.sha256(_s)[:8]}"].metadata.annotations["crossplane.io/external-name"] == "demo-github-actions-pool-${crypto.sha256(_s)[:8]}"
    }
    assert all _s in [_main, _prod] {
        _set(byn["access-github-actions-pool-${crypto.sha256(_s)[:8]}"].spec.forProvider) == {issuer = "https://token.actions.githubusercontent.com", subject = _s, audience = ["api://AzureADTokenExchange"], resourceGroupName = "rg-ci", parentId = "/uai/gh"}
    }
    # A custom issuer and audiences carry through.
    ado = {client = "azure-devops", owner = "org-guid", subjects = ["sc://org/proj/conn"], audiences = ["api://custom"]}
    c = [_i for _i in bucket.render_access(_xr([ado], {}), {"access-azure-pipelines-pool" = _seen({id = "/uai/ado"})}) if _i.kind == "FederatedIdentityCredential"][0]
    assert c.spec.forProvider.issuer == "https://vstoken.dev.azure.com/org-guid" and c.spec.forProvider.audience == ["api://custom"]
    # The other entry, not yet observed, still has no credentials.
    two = bucket.render_access(_xr([_gh, _jira], {}), {"access-github-actions-pool" = _seen({id = "/uai/gh"})})
    two_names = _names(two)
    assert not any _n in two_names {
        _n.startswith("access-jira-github-")
    }, "credentials follow their own identity's observation"
}

# The grant needs the identity's principal and the account's id.
test_access_grant_after_both = lambda {
    ident = {"access-github-actions-pool" = _seen({id = "/uai/gh", principalId = "p-gh"})}
    acct = {managed = _seen({id = _account_id})}
    assert "access-github-actions-pool-grant" not in _names(bucket.render_access(_xr([_gh], {}), ident)), "no grant without the account id"
    assert "access-github-actions-pool-grant" not in _names(bucket.render_access(_xr([_gh], {}), acct)), "no grant without the principal"
    g = _by_name(bucket.render_access(_xr([_gh], {}), ident | acct))["access-github-actions-pool-grant"]
    assert g.kind == "RoleAssignment"
    assert _set(g.spec.forProvider) == {principalId = "p-gh", principalType = "ServicePrincipal", skipServicePrincipalAadCheck = True, scope = _account_id, roleDefinitionName = "Storage Blob Data Contributor"}
    role_of = lambda role: str -> str {
        _by_name(bucket.render_access(_xr([_gh | {role = role}], {}), ident | acct))["access-github-actions-pool-grant"].spec.forProvider.roleDefinitionName
    }
    assert role_of("read") == "Storage Blob Data Reader"
    assert role_of("admin") == "Storage Blob Data Owner"
    dflt = {client = "github", owner = "acme", subjects = [_main]}
    assert _by_name(bucket.render_access(_xr([dflt], {}), ident | acct))["access-github-actions-pool-grant"].spec.forProvider.roleDefinitionName == "Storage Blob Data Reader", "role defaults to read"
}

# Reordering entries keeps every resource's name and content.
test_access_names_stable = lambda {
    ocds = {
        managed = _seen({id = _account_id})
        "access-github-actions-pool" = _seen({id = "/uai/gh", principalId = "p-gh"})
        "access-jira-github" = _seen({id = "/uai/jira", principalId = "p-jira"})
    }
    a = _by_name(bucket.render_access(_xr([_gh, _jira], {}), ocds))
    b = _by_name(bucket.render_access(_xr([_jira, _gh], {}), ocds))
    assert len(a) == 7, "2 identities + 3 credentials + 2 grants"
    assert a == b, "names and content independent of entry order"
    # Reordering subjects keeps the credential names too.
    c = _by_name(bucket.render_access(_xr([_gh | {subjects = [_prod, _main]}], {}), ocds))
    assert sorted([_k for _k in c]) == sorted([_k for _k in a if _k.startswith("access-github-actions-pool")])
}

test_access_status = lambda {
    oxr = _xr([_gh, _jira], {})
    assert bucket.status(oxr, {}).status.access == [{name = "github-actions-pool", role = "write"}, {name = "jira-github", role = "admin"}]
    s = bucket.status(oxr, {"access-github-actions-pool" = _seen({clientId = "c-gh", tenantId = "t-1"}), managed = _seen({id = _account_id})}).status
    assert s.access[0] == {name = "github-actions-pool", role = "write", clientId = "c-gh", tenantId = "t-1"}
    assert s.ready and s.bucketName == "demost" and s.provider == "azure"
}

test_access_failures = lambda {
    assert "Azure federated credentials match the token's sub exactly" in _err(lambda {
        bucket.render_access(_xr([{client = "github", owner = "acme"}], {}), {})
    }), "missing subjects fails"
    assert "lists subjects twice" in _err(lambda {
        bucket.render_access(_xr([_gh | {subjects = [_main, _main]}], {}), {})
    })
    assert "bucket-azure: spec.access needs spec.federation.azureResourceGroup" in _err(lambda {
        bucket.render_access({metadata.name = "demo", spec = {region = "westeurope", access = [_gh]}}, {})
    })
    assert "bucket-azure: spec.federation.gcpProjectNumber is GCP-only" in _err(lambda {
        bucket.render_access(_xr([_gh], {federation = {azureResourceGroup = "rg-ci", gcpProjectNumber = "123"}}), {})
    })
    assert "bucket-azure: spec.federation.awsAccountId is AWS-only" in _err(lambda {
        bucket.render_access(_xr([_gh], {federation = {azureResourceGroup = "rg-ci", awsAccountId = "111122223333"}}), {})
    })
    assert "bucket-azure: access writes IAM" in _err(lambda {
        bucket.render_access(_xr([_gh], {import = {existingName = "legacyst01", resourceGroup = "rg-legacy"}}), {})
    }), "observe-mode import with access fails"
    assert "over Azure's 128 characters" in _err(lambda {
        bucket.render_access({metadata.name = "x" * 120, spec = {region = "westeurope", federation = {azureResourceGroup = "rg"}, access = [_gh]}}, {})
    })
}

test_access_none()
test_access_identities_first()
test_access_credentials_after_identity()
test_access_grant_after_both()
test_access_names_stable()
test_access_status()
test_access_failures()
