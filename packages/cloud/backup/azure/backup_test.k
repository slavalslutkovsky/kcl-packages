import runtime
import .backup

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec, _name: str = "nightly" {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "BackupPlan", metadata = {name = _name, namespace = "default"}, spec = _spec}
}

_sub = "11111111-2222-3333-4444-555555555555"
_cluster_id = "/subscriptions/${_sub}/resourceGroups/aks-rg/providers/Microsoft.ContainerService/managedClusters/prod"
_vault_id = "/subscriptions/${_sub}/resourceGroups/aks-rg/providers/Microsoft.DataProtection/backupVaults/nightly"
_policy_id = "${_vault_id}/backupPolicies/nightly"

# The minimum an azure BackupPlan needs: when, which cluster, and where to.
_dest = {provider = "azure", bucket = "aks-backups", storageAccount = "acmebackups"}
_minimal = {
    schedule = "0 2 * * *"
    cluster = {id = _cluster_id, region = "westeurope"}
    destination = _dest
}

_items = lambda _spec, _ocds {
    backup.render(_build(_spec), _ocds)
}

# Composed resources by their composition-resource-name.
_by_name = lambda _spec, _ocds {
    {r.metadata.annotations["krm.kcl.dev/composition-resource-name"]: r for r in _items(_spec, _ocds)}
}

_names = lambda _spec, _ocds {
    sorted([_k for _k in _by_name(_spec, _ocds)])
}

# An observed composed resource, Ready or not.
_obs = lambda _at, _ready: bool, _forProvider {
    {
        Resource = {
            spec.forProvider = _forProvider or {}
            status = {
                atProvider = _at
                conditions = [{type = "Ready", status = "True" if _ready else "False", reason = "Available" if _ready else "Creating", lastTransitionTime = "2026-11-20T02:00:00Z"}]
            }
        }
    }
}

_vault_roles = ["role-vault-cluster-reader", "role-vault-disk-operator", "role-vault-snapshot-contributor", "role-vault-snapshot-reader", "role-vault-storage"]
_all_roles = sorted(_vault_roles + ["role-cluster-snapshot-contributor", "role-extension-storage"])

# Progressive observed states, each building on the last.
_cluster_seen = {cluster = _obs({id = _cluster_id, identity = {principalId = "cluster-principal", tenantId = "tenant-1", $type = "SystemAssigned"}}, True, Undefined)}
_vault_seen = _cluster_seen | {
    vault = _obs({id = _vault_id, identity = {principalId = "vault-principal", tenantId = "tenant-1"}}, True, Undefined)
    policy = _obs({id = _policy_id}, True, Undefined)
}
_extension_seen = _vault_seen | {
    extension = _obs({aksAssignedIdentity = [{principalId = "extension-principal", tenantId = "tenant-1"}]}, True, Undefined)
    "trusted-access" = _obs({id = "${_cluster_id}/trustedAccessRoleBindings/nightly"}, True, Undefined)
}
# Every role assignment created and Ready: the cluster is fully wired.
_wired = _extension_seen | {_r: _obs({id = "/x/roleAssignments/${_r}"}, True, Undefined) for _r in _all_roles}
_protected = _wired | {managed = _obs({id = "${_vault_id}/backupInstances/nightly", protectionState = "ProtectionConfigured"}, True, Undefined)}

# ---- render: pass 1 ---------------------------------------------------------

# Nothing observed yet: only what needs no Azure-assigned id or identity.
test_first_render = lambda {
    _n = _by_name(_minimal, {})
    assert sorted([_k for _k in _n]) == ["cluster", "policy", "vault"], "pass 1 must compose exactly the observed cluster, the vault and the policy, got ${sorted([_k for _k in _n])}"
    assert _n["cluster"].kind == "KubernetesCluster", "the cluster is a KubernetesCluster MR"
    assert _n["cluster"].apiVersion == "containerservice.azure.m.upbound.io/v1beta1", "namespaced (.m.) Upjet API"
    assert _n["vault"].kind == "BackupVault", "wrong kind for the vault"
    assert _n["policy"].kind == "BackupPolicyKubernetesCluster", "wrong kind for the policy"
    assert _n["vault"].apiVersion == "dataprotection.azure.m.upbound.io/v1beta1", "namespaced (.m.) Upjet API"
}

test_cluster_is_observe_only = lambda {
    _c = _by_name(_minimal, {})["cluster"]
    assert _c.spec.managementPolicies == ["Observe"], "the cluster is read for its identity, never managed"
    assert _c.metadata.annotations["crossplane.io/external-name"] == "prod", "the external name is the cluster name parsed from the ARM id"
    assert _c.spec.forProvider.resourceGroupName == "aks-rg", "the resource group is parsed from the ARM id"
}

test_vault = lambda {
    _v = _by_name(_minimal | {tags = {team = "platform"}}, {})["vault"]
    assert _v.metadata.annotations["crossplane.io/external-name"] == "nightly", "the vault is named after the XR, so status.storageLocation is known up front"
    _f = _v.spec.forProvider
    assert _f.location == "westeurope", "the vault lives in cluster.region"
    assert _f.resourceGroupName == "aks-rg", "the vault lives in the cluster's resource group"
    assert _f.datastoreType == "VaultStore", "VaultStore, as in the azurerm example"
    assert _f.redundancy == "LocallyRedundant", "LocallyRedundant, as in the azurerm example"
    assert _f.identity.$type == "SystemAssigned", "the vault needs its own identity for the role assignments"
    assert _f.tags == {team = "platform"}, "tags go on the vault"
    assert _by_name(_minimal, {})["vault"].spec.forProvider?.tags == Undefined, "no tags unless asked for"
}

test_policy = lambda {
    _p = _by_name(_minimal, {})["policy"]
    assert _p.metadata.annotations["crossplane.io/external-name"] == "nightly", "the policy is named after the XR"
    _f = _p.spec.forProvider
    assert _f.vaultName == "nightly", "the policy names its vault directly — the vault name is pinned"
    assert _f.resourceGroupName == "aks-rg", "the policy lives beside its vault"
    assert _f.backupRepeatingTimeIntervals == ["R/2024-01-01T02:00:00+00:00/P1D"], "nightly at 02:00 UTC"
    assert _f.timeZone == "UTC", "the interval is written in UTC"
    assert [[_l.dataStoreType, _l.duration] for _l in _f.defaultRetentionRule.lifeCycle] == [["OperationalStore", "P30D"]], "retentionDays defaults to 30, in the operational store"
}

# ---- render: retention ------------------------------------------------------
test_retention = lambda {
    _r = lambda _d {
        _by_name(_minimal | {retentionDays = _d}, {})["policy"].spec.forProvider.defaultRetentionRule.lifeCycle[0].duration
    }
    assert _r(7) == "P7D", "retentionDays must become an ISO 8601 day count"
    assert _r(1) == "P1D", "one day is the minimum"
    assert _r(360) == "P360D", "360 days is Azure's operational-tier maximum"
    _err = runtime.catch(lambda {
        _r(361)
    })
    assert _err and "backup-azure:" in _err and "360" in _err, "retention beyond Azure's maximum must fail the render, got: ${_err}"
}

# ---- render: schedule translation -------------------------------------------
test_cron_to_iso = lambda {
    _table = {
        "0 2 * * *" = "R/2024-01-01T02:00:00+00:00/P1D"
        "30 23 * * *" = "R/2024-01-01T23:30:00+00:00/P1D"
        "5 0 * * *" = "R/2024-01-01T00:05:00+00:00/P1D"
        "@daily" = "R/2024-01-01T00:00:00+00:00/P1D"
        "0 */4 * * *" = "R/2024-01-01T00:00:00+00:00/PT4H"
        "15 */6 * * *" = "R/2024-01-01T00:15:00+00:00/PT6H"
        "0 */8 * * *" = "R/2024-01-01T00:00:00+00:00/PT8H"
        "45 */12 * * *" = "R/2024-01-01T00:45:00+00:00/PT12H"
    }
    assert all _c, _iso in _table {
        backup.repeating_interval(_c) == _iso
    }, "every translatable cron must map to its ISO 8601 repeating interval: ${[backup.repeating_interval(_c) for _c in _table]}"
}

test_cron_untranslatable = lambda {
    _bad = ["0 2 * * 1", "0 */3 * * *", "0 */24 * * *", "@weekly", "@hourly", "@monthly", "*/15 * * * *", "0 2 1 * *", "60 2 * * *", "0 24 * * *", "0 2 * *", "0 1,13 * * *"]
    _errs = [runtime.catch(lambda {
        backup.repeating_interval(_c)
    }) for _c in _bad]
    assert all _e in _errs {
        _e and "backup-azure:" in _e
    }, "every cron Azure cannot run must fail the render with a backup-azure: message, got ${_errs}"
    _err = runtime.catch(lambda {
        _items(_minimal | {schedule = "0 2 * * 0"}, {})
    })
    assert _err and "backup-azure:" in _err, "an untranslatable schedule must fail the whole render"
}

# ---- render: ARM id and required fields -------------------------------------
test_cluster_id_parsing = lambda {
    assert backup.parse_cluster_id(_cluster_id) == {subscription = _sub, resourceGroup = "aks-rg", name = "prod"}, "subscription, resource group and name must come out of the ARM id"
    # ARM ids are case-insensitive; az and the portal disagree on casing.
    assert backup.parse_cluster_id("/subscriptions/s/resourcegroups/My-RG/providers/microsoft.containerservice/managedclusters/My-AKS") == {subscription = "s", resourceGroup = "My-RG", name = "My-AKS"}, "fixed segments match case-insensitively; values keep their case"
    _bad = [
        "prod"
        "subscriptions/s/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/prod"
        "/subscriptions/s/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/prod/"
        "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/prod"
        "/subscriptions/s/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/prod/agentPools/system"
        "/subscriptions//resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/prod"
        "arn:aws:eks:eu-west-1:123456789012:cluster/prod"
    ]
    _errs = [runtime.catch(lambda {
        backup.parse_cluster_id(_i)
    }) for _i in _bad]
    assert all _e in _errs {
        _e and "backup-azure: spec.cluster.id" in _e
    }, "anything but an AKS ARM id must fail the render, got ${_errs}"
}

test_required_fields = lambda {
    _fails = lambda _spec, _what: str -> str {
        _e = runtime.catch(lambda {
            _items(_spec, {})
        })
        "" if (_e and "backup-azure:" in _e and _what in _e) else "${_what}: ${_e}"
    }
    _problems = [_p for _p in [
        _fails({schedule = "0 2 * * *", destination = _dest}, "spec.cluster.id")
        _fails(_minimal | {cluster = {id = _cluster_id}}, "spec.cluster.region")
        _fails({schedule = "0 2 * * *", cluster = _minimal.cluster}, "spec.destination")
        _fails(_minimal | {destination = _dest | {provider = "aws"}}, "destination.provider")
        _fails(_minimal | {destination = {provider = "azure", storageAccount = "acmebackups"}}, "destination.bucket")
        _fails(_minimal | {destination = {provider = "azure", bucket = "aks-backups"}}, "destination.storageAccount")
    ] if _p]
    assert not _problems, "missing or wrong required fields must fail the render: ${_problems}"
}

# Azure cannot pause a backup instance — only delete it, with its backups.
test_paused_fails = lambda {
    _err = runtime.catch(lambda {
        _items(_minimal | {paused = True}, {})
    })
    assert _err and "backup-azure: paused" in _err, "paused true must fail the render, got: ${_err}"
    assert len(_items(_minimal | {paused = False}, {})) == 3, "paused false is the only thing Azure can do"
}

# The XR name becomes the vault, policy and instance names.
test_xr_name_rules = lambda {
    _err = runtime.catch(lambda {
        backup.render(_build(_minimal, "nightly.prod"), {})
    })
    assert _err and "backup-azure: metadata.name" in _err, "a name Azure rejects for a vault must fail the render, got: ${_err}"
}

# ---- render: progressive wiring ---------------------------------------------

# The cluster's identity is observed first: its tenant unlocks the extension,
# its principal the one grant made to the cluster.
test_progressive_cluster_observed = lambda {
    assert _names(_minimal, _cluster_seen) == ["cluster", "extension", "policy", "role-cluster-snapshot-contributor", "vault"], "the cluster's identity unlocks the extension and its own grant, got ${_names(_minimal, _cluster_seen)}"
    _e = _by_name(_minimal, _cluster_seen)["extension"]
    assert _e.kind == "KubernetesClusterExtension", "wrong kind for the extension"
    assert _e.metadata.annotations["crossplane.io/external-name"] == "azure-aks-backup", "one backup extension per cluster, under a fixed name"
    _f = _e.spec.forProvider
    assert _f.clusterId == _cluster_id, "the extension goes on the protected cluster"
    assert _f.extensionType == "Microsoft.DataProtection.Kubernetes", "the AKS backup extension type"
    assert _f.releaseTrain == "stable", "stable release train"
    assert _f.releaseNamespace == "dataprotection-microsoft", "the namespace the Backup service looks in"
    assert _f.configurationSettings == {
        "configuration.backupStorageLocation.bucket" = "aks-backups"
        "configuration.backupStorageLocation.config.resourceGroup" = "aks-rg"
        "configuration.backupStorageLocation.config.storageAccount" = "acmebackups"
        "configuration.backupStorageLocation.config.subscriptionId" = _sub
        "credentials.tenantId" = "tenant-1"
    }, "the extension's storage location, as in the azurerm example"
}

# Without the cluster's identity, the vault's tenant is the same tenant.
test_extension_tenant_from_vault = lambda {
    _o = {vault = _obs({id = _vault_id, identity = {principalId = "vault-principal", tenantId = "tenant-2"}}, False, Undefined)}
    _f = _by_name(_minimal, _o)["extension"].spec.forProvider
    assert _f.configurationSettings["credentials.tenantId"] == "tenant-2", "the vault's tenant must stand in for the cluster's"
}

test_progressive_vault_observed = lambda {
    assert _names(_minimal, _vault_seen) == sorted(["cluster", "extension", "policy", "role-cluster-snapshot-contributor", "trusted-access", "vault"] + _vault_roles), "the vault's id unlocks trusted access, its identity its five grants, got ${_names(_minimal, _vault_seen)}"
    _t = _by_name(_minimal, _vault_seen)["trusted-access"]
    assert _t.kind == "TrustedAccessRoleBinding", "wrong kind for trusted access"
    assert _t.metadata.annotations["crossplane.io/external-name"] == "nightly", "a short XR name is the binding name"
    assert _t.spec.forProvider.kubernetesClusterId == _cluster_id, "trusted access is granted on the cluster"
    assert _t.spec.forProvider.sourceResourceId == _vault_id, "to the vault, by its observed ARM id"
    assert _t.spec.forProvider.roles == ["Microsoft.DataProtection/backupVaults/backup-operator"], "the backup-operator role"
}

test_progressive_extension_observed = lambda {
    _n = _names(_minimal, _extension_seen)
    assert _n == sorted(["cluster", "extension", "policy", "trusted-access", "vault"] + _all_roles), "the extension's identity unlocks the last grant, got ${_n}"
    assert "managed" not in _n, "nothing is Ready-checked yet: the role assignments do not exist, so neither may the instance"
}

# The azurerm example's seven grants, one-for-one.
test_role_assignments = lambda {
    _n = _by_name(_minimal | {cluster = _minimal.cluster | {snapshotResourceGroup = "aks-snapshots"}, destination = _dest | {resourceGroup = "storage-rg"}}, _extension_seen)
    _storage = "/subscriptions/${_sub}/resourceGroups/storage-rg/providers/Microsoft.Storage/storageAccounts/acmebackups"
    _snap = "/subscriptions/${_sub}/resourceGroups/aks-snapshots"
    _want = {
        "role-extension-storage" = ["extension-principal", "Storage Account Contributor", _storage]
        "role-vault-cluster-reader" = ["vault-principal", "Reader", _cluster_id]
        "role-vault-snapshot-reader" = ["vault-principal", "Reader", _snap]
        "role-vault-snapshot-contributor" = ["vault-principal", "Disk Snapshot Contributor", _snap]
        "role-vault-disk-operator" = ["vault-principal", "Data Operator for Managed Disks", _snap]
        "role-vault-storage" = ["vault-principal", "Storage Blob Data Contributor", _storage]
        "role-cluster-snapshot-contributor" = ["cluster-principal", "Contributor", _snap]
    }
    _got = {_k: [_n[_k].spec.forProvider.principalId, _n[_k].spec.forProvider.roleDefinitionName, _n[_k].spec.forProvider.scope] for _k in _want}
    assert _got == _want, "role assignments must match the azurerm example: ${_got}"
    assert all _k in _want {
        _n[_k].kind == "RoleAssignment" and _n[_k].spec.forProvider.principalType == "ServicePrincipal"
    }, "every grant is a RoleAssignment to a service principal"
    assert _n["extension"].spec.forProvider.configurationSettings["configuration.backupStorageLocation.config.resourceGroup"] == "storage-rg", "destination.resourceGroup must reach the extension"
}

test_snapshot_rg_defaults_to_cluster_rg = lambda {
    _n = _by_name(_minimal, _extension_seen)
    assert _n["role-vault-snapshot-reader"].spec.forProvider.scope == "/subscriptions/${_sub}/resourceGroups/aks-rg", "the snapshot RG defaults to the cluster's"
    assert _n["role-vault-storage"].spec.forProvider.scope == "/subscriptions/${_sub}/resourceGroups/aks-rg/providers/Microsoft.Storage/storageAccounts/acmebackups", "the storage account RG defaults to the cluster's"
}

# ---- render: the backup instance --------------------------------------------

# Azure checks every permission when the instance is created, so one missing
# grant must hold it back.
test_instance_gated_on_readiness = lambda {
    assert "managed" not in _by_name(_minimal, _wired | {"role-vault-storage" = _obs({id = "/x"}, False, Undefined)}), "one grant not Ready must hold the instance back"
    assert "managed" not in _by_name(_minimal, _wired | {"trusted-access" = _obs({}, False, Undefined)}), "trusted access not Ready must hold the instance back"
    assert "managed" not in _by_name(_minimal, _wired | {extension = _obs({aksAssignedIdentity = [{principalId = "extension-principal"}]}, False, Undefined)}), "an extension not Ready must hold the instance back"
    assert "managed" not in _by_name(_minimal, _wired | {policy = _obs({}, True, Undefined)}), "no policy id, no instance"
    _n = _names(_minimal, _wired)
    assert _n == sorted(["cluster", "extension", "managed", "policy", "trusted-access", "vault"] + _all_roles), "a fully wired cluster gets its instance, got ${_n}"
}

test_instance = lambda {
    _i = _by_name(_minimal, _wired)["managed"]
    assert _i.kind == "BackupInstanceKubernetesCluster", "the backup instance is the managed resource"
    assert _i.metadata.annotations["crossplane.io/external-name"] == "nightly", "the instance is named after the XR"
    _f = _i.spec.forProvider
    assert _f.location == "westeurope", "the instance lives in cluster.region"
    assert _f.vaultId == _vault_id, "bound to the observed vault"
    assert _f.backupPolicyId == _policy_id, "bound to the observed policy"
    assert _f.kubernetesClusterId == _cluster_id, "protecting the cluster"
    assert _f.snapshotResourceGroupName == "aks-rg", "snapshots go to the cluster RG by default"
    _p = _f.backupDatasourceParameters
    assert _p.volumeSnapshotEnabled == True and _p.clusterScopedResourcesEnabled == True, "volumes and cluster-scoped resources are backed up by default"
    assert [_p?.includedNamespaces, _p?.includedResourceTypes, _p?.excludedResourceTypes, _p?.labelSelectors] == [Undefined, Undefined, Undefined, Undefined], "no filters unless asked for: every namespace, every type"
}

# Once the instance exists it must never drop out of the desired state —
# Crossplane would delete it, and with it every backup.
test_instance_sticky = lambda {
    _o = _protected | {
        "role-vault-storage" = _obs({id = "/x"}, False, Undefined)
        vault = _obs({}, False, Undefined)
        managed = _obs({}, True, {vaultId = _vault_id, backupPolicyId = _policy_id})
        "trusted-access" = _obs({}, True, {sourceResourceId = _vault_id})
    } | {_r: _obs({}, True, {principalId = "vault-principal"}) for _r in _vault_roles}
    _n = _by_name(_minimal, _o)
    assert "managed" in _n, "an existing instance must stay rendered even when a prerequisite blinks"
    assert _n["managed"].spec.forProvider.vaultId == _vault_id, "and keep its own vault id when the vault's is not observed"
    assert _n["trusted-access"].spec.forProvider.sourceResourceId == _vault_id, "trusted access must stay rendered from its own spec"
    assert all _r in _vault_roles {
        _n[_r].spec.forProvider.principalId == "vault-principal"
    }, "grants must stay rendered from their own spec when the vault identity is not observed"
}

test_instance_filters = lambda {
    _f = _by_name(_minimal | {
        includedNamespaces = ["zerg", "dbs"]
        includedResources = ["persistentvolumeclaims", "deployments.apps"]
        excludedResources = ["events", "events.events.k8s.io"]
        labelSelector = {tier = "db", "backup" = "nightly"}
        snapshotVolumes = False
    }, _wired)["managed"].spec.forProvider.backupDatasourceParameters
    assert _f.includedNamespaces == ["zerg", "dbs"], "includedNamespaces must narrow the backup"
    assert _f.includedResourceTypes == ["persistentvolumeclaims", "deployments.apps"], "includedResources -> includedResourceTypes"
    assert _f.excludedResourceTypes == ["events", "events.events.k8s.io"], "excludedResources -> excludedResourceTypes"
    assert _f.labelSelectors == ["backup=nightly", "tier=db"], "labelSelector -> sorted key=value strings"
    assert _f.volumeSnapshotEnabled == False, "snapshotVolumes false must turn volume snapshots off"
    assert _f.clusterScopedResourcesEnabled == True, "cluster-scoped resources are always backed up"
    assert _by_name(_minimal | {includedNamespaces = []}, _wired)["managed"].spec.forProvider.backupDatasourceParameters?.includedNamespaces == Undefined, "an empty includedNamespaces means every namespace, which Azure spells as absence"
}

# ---- render: ignored fields -------------------------------------------------
test_ignored_fields = lambda {
    _plain = _items(_minimal, _wired)
    _noisy = _items(_minimal | {
        encryptionKmsKeyId = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/keys/k"
        defaultVolumesToFsBackup = True
        destination = _dest | {prefix = "prod", region = "westeurope", credentialsSecret = {name = "x"}}
    }, _wired)
    assert _plain == _noisy, "encryptionKmsKeyId, defaultVolumesToFsBackup, prefix, region and credentialsSecret are ignored on azure"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy_orphan = lambda {
    _n = _by_name(_minimal | {deletionPolicy = "Orphan"}, _wired)
    assert len(_n) == 13, "the full set must be rendered for this check"
    assert _n["cluster"].spec.managementPolicies == ["Observe"], "the cluster stays observe-only under Orphan"
    assert all _k, _r in _n {
        _k == "cluster" or _r.spec.managementPolicies == ["Observe", "Create", "Update", "LateInitialize"]
    }, "Orphan must drop Delete from every managed resource"
    _d = _by_name(_minimal, _wired)
    assert all _k, _r in _d {
        _k == "cluster" or _r.spec.managementPolicies == ["*"]
    }, "Delete leaves the default full management"
    assert _d["cluster"].spec.managementPolicies == ["Observe"], "the cluster is observe-only under Delete too"
}

# ---- naming -------------------------------------------------------------------
test_long_name_binding = lambda {
    _name = "nightly-production-cluster-backups"
    _t = [_r for _r in backup.render(_build(_minimal, _name), _vault_seen) if _r.kind == "TrustedAccessRoleBinding"][0]
    _b = _t.metadata.annotations["crossplane.io/external-name"]
    assert len(_b) == 24, "a trusted-access binding name is at most 24 characters, got ${_b}"
    assert _b.startswith("nightly-product-"), "the head of the XR name stays readable"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = backup.status(_build(_minimal), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "BackupPlan", "dxr kind must echo the composite"
    assert dxr.metadata.name == "nightly", "dxr must be named after the XR"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.ready == False, "a plan nothing has reconciled must not be ready"
    assert dxr.status.storageLocation == "nightly", "the vault name is pinned, so report it immediately"
    assert dxr.status?.phase == Undefined, "no phase until the instance is observed"
    assert dxr.status.message == "cluster: not observed yet", "the first missing piece must be named"
}

test_status_ready = lambda {
    dxr = backup.status(_build(_minimal), _protected)
    assert dxr.status.ready == True, "every composed resource Ready is a working plan"
    assert dxr.status.phase == "ProtectionConfigured", "the instance's protection state is the phase"
    assert dxr.status?.message == Undefined, "a healthy plan has nothing to say"
}

test_status_not_ready = lambda {
    _o = _protected | {
        "role-vault-disk-operator" = {
            Resource.status.conditions = [{type = "Ready", status = "False", reason = "ReconcileError", message = "AuthorizationFailed: client lacks Microsoft.Authorization/roleAssignments/write", lastTransitionTime = "2026-11-20T02:00:00Z"}]
        }
    }
    dxr = backup.status(_build(_minimal), _o)
    assert dxr.status.ready == False, "one grant not Ready means no working plan"
    assert dxr.status.message == "role-vault-disk-operator: AuthorizationFailed: client lacks Microsoft.Authorization/roleAssignments/write", "the failing resource and its own message"

    _waiting = backup.status(_build(_minimal), _wired)
    assert _waiting.status.ready == False, "a wired cluster without an instance protects nothing"
    assert _waiting.status.message.startswith("managed: waiting for"), "a resource not created yet says what it waits for, got ${_waiting.status.message}"

    _no_msg = backup.status(_build(_minimal), _cluster_seen | {vault = {Resource.status.conditions = [{type = "Ready", status = "False", reason = "Creating", lastTransitionTime = "2026-11-20T02:00:00Z"}]}})
    assert _no_msg.status.message == "vault: Creating", "without a message the condition reason stands in"

    _phase = backup.status(_build(_minimal), _wired | {managed = _obs({protectionState = "ConfiguringProtection"}, False, Undefined)})
    assert _phase.status.phase == "ConfiguringProtection", "the protection state is reported before it is Ready"
    assert _phase.status.ready == False, "an instance still configuring is not ready"
}
