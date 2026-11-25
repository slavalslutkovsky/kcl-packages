# backup (azure) — Crossplane Composition logic (function-kcl module).
# Azure Backup for AKS. Typed against the azure-dataprotection,
# azure-containerservice and azure-authorization schema packages.
#
# Azure splits one backup plan across far more objects than Velero does,
# because the service is Velero run FOR you: a Backup vault (the catalogue of
# recovery points) with a Kubernetes backup policy (WHEN and HOW LONG), the
# AKS backup extension (Velero itself, installed into the cluster, staging
# backups in a blob container), a trusted-access binding (lets the vault
# drive the extension through the AKS API), a backup instance (WHAT: the
# cluster plus its filters, bound to vault and policy) and seven role
# assignments that let each identity reach what it touches.
#
# The wiring and the role set follow the azurerm example for
# azurerm_data_protection_backup_instance_kubernetes_cluster
# (website/docs/r/data_protection_backup_instance_kubernetes_cluster.html.markdown
# in hashicorp/terraform-provider-azurerm) exactly; see `_role_assignments`.
#
# Rendering is progressive, because most of these objects need an identity or
# an id that Azure only assigns on creation:
#   pass 1   cluster (observe only), vault, policy
#   then     extension            once a tenant id is observed
#            trusted-access       once the vault id is observed
#            role-*               once the principal they grant to is observed
#            managed (instance)   once vault + policy ids are known AND the
#                                 extension, trusted access and every role
#                                 assignment are Ready — Azure validates the
#                                 permissions when the instance is created and
#                                 fails it outright if one is missing.
# Every progressive resource stays rendered once it exists, falling back to
# its own observed spec: dropping it from the desired state because a source
# blinked would make Crossplane DELETE it, and deleting the backup instance is
# "stop protection and delete data".
#
# Not composed here: the AKS cluster (observed only, never managed), the
# storage account and blob container (a Bucket XR's job), and the snapshot
# resource group. See the README's prerequisites.
import crypto
import regex
import azure_containerservice.models.v1beta1.containerservice_azurem_upbound_io_v1beta1_kubernetes_cluster as aks
import azure_containerservice.models.v1beta1.containerservice_azurem_upbound_io_v1beta1_kubernetes_cluster_extension as ext
import azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_vault as bv
import azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_policy_kubernetes_cluster as bp
import azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_instance_kubernetes_cluster as bi
import azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_role_assignment as ra
import azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_trusted_access_role_binding as tarb

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# composition-resource-names. Renaming a composed resource makes Crossplane
# delete and recreate it, so these strings are contract, not decoration.
_cluster_resource = "cluster"
_vault_resource = "vault"
_policy_resource = "policy"
_extension_resource = "extension"
_trusted_access_resource = "trusted-access"
_instance_resource = "managed"

# The AKS backup extension's Azure name. Azure allows one
# Microsoft.DataProtection.Kubernetes extension per cluster, so the name is a
# fixed, recognisable one — the name Microsoft's own CLI walkthrough uses.
_extension_name = "azure-aks-backup"
_extension_type = "Microsoft.DataProtection.Kubernetes"
# The namespace the extension's Velero runs in. Microsoft documents this one
# and the Backup service looks for the extension there.
_extension_namespace = "dataprotection-microsoft"

# The single trusted-access role the Backup service needs on the cluster.
_trusted_access_roles = ["Microsoft.DataProtection/backupVaults/backup-operator"]

# The role set of the azurerm example, one-for-one (its resource names in
# brackets), so nothing here is a guess at what the service needs:
#   extension identity
#     Storage Account Contributor      on the storage account  [test_extension_and_storage_account_permission]
#   vault identity
#     Reader                           on the cluster          [test_vault_msi_read_on_cluster]
#     Reader                           on the snapshot RG      [test_vault_msi_read_on_snap_rg]
#     Disk Snapshot Contributor        on the snapshot RG      [test_vault_msi_snapshot_contributor_on_snap_rg]
#     Data Operator for Managed Disks  on the snapshot RG      [test_vault_data_operator_on_snap_rg]
#     Storage Blob Data Contributor    on the storage account  [test_vault_data_contributor_on_storage]
#   cluster identity
#     Contributor                      on the snapshot RG      [test_cluster_msi_contributor_on_snap_rg]
# `principal` names whose identity is granted, `scope` which of the three
# scopes render() derives.
_role_assignments = [
    {name = "role-extension-storage", principal = "extension", role = "Storage Account Contributor", scope = "storage"}
    {name = "role-vault-cluster-reader", principal = "vault", role = "Reader", scope = "cluster"}
    {name = "role-vault-snapshot-reader", principal = "vault", role = "Reader", scope = "snapshot"}
    {name = "role-vault-snapshot-contributor", principal = "vault", role = "Disk Snapshot Contributor", scope = "snapshot"}
    {name = "role-vault-disk-operator", principal = "vault", role = "Data Operator for Managed Disks", scope = "snapshot"}
    {name = "role-vault-storage", principal = "vault", role = "Storage Blob Data Contributor", scope = "storage"}
    {name = "role-cluster-snapshot-contributor", principal = "cluster", role = "Contributor", scope = "snapshot"}
]

# Every composed resource, in dependency order — status reports the first one
# that is not Ready, so the order is the order a human should look in.
_resource_names = [_cluster_resource, _vault_resource, _policy_resource, _extension_resource, _trusted_access_resource] + [_r.name for _r in _role_assignments] + [_instance_resource]

# Azure Backup for AKS keeps operational-tier recovery points for at most 360
# days (AKS backup support matrix).
_max_retention_days = 360

# Azure Backup for AKS runs every 4, 6, 8 or 12 hours, or once a day — nothing
# else (AKS backup support matrix).
_hour_steps = [4, 6, 8, 12]

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow a
# legitimate False, so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

_pad2 = lambda n: int -> str {
    "0${n}" if n < 10 else "${n}"
}

# One cron field holding a plain number in 0..hi.
_number = lambda s: str, hi: int -> bool {
    regex.match(s, r"^[0-9]{1,2}$") and int(s) <= hi
}

# Translate the XR's five-field cron into the ISO 8601 repeating interval a
# Kubernetes backup policy takes. Only two shapes have an Azure equivalent:
# "m h * * *" (daily) and "m */N * * *" (every N hours from midnight). The
# start date is arbitrary — Azure only reads the time of day and the period —
# and is pinned so the render is stable. Anything else fails the render: a
# weekly cron silently turned daily would back up something other than asked,
# and one turned into nothing would back up less.
repeating_interval = lambda cron: str -> str {
    _c = cron.strip()
    _f = ("0 0 * * *" if _c == "@daily" else _c).split()
    _shape = len(_f) == 5 and _f[2:] == ["*", "*", "*"] and _number(_f[0], 59)
    _daily = _shape and _number(_f[1], 23)
    _step = int(_f[1][2:]) if _shape and regex.match(_f[1], r"^\*/[0-9]{1,2}$") else 0
    assert _daily or _step in _hour_steps, "backup-azure: schedule \"${cron}\" cannot be expressed — Azure Backup for AKS only runs daily or every 4, 6, 8 or 12 hours, so use \"m h * * *\", \"m */N * * *\" (N in 4, 6, 8, 12) or @daily"
    _minute = _pad2(int(_f[0]))
    "R/2024-01-01T${_pad2(int(_f[1]))}:${_minute}:00+00:00/P1D" if _daily else "R/2024-01-01T00:${_minute}:00+00:00/PT${_step}H"
}

# /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerService/managedClusters/<name>
# ARM ids are case-insensitive, so the fixed segments are compared lowered;
# the values keep the caller's casing.
parse_cluster_id = lambda id: str -> {str:str} {
    _p = id.split("/")
    _ok = len(_p) == 9 and _p[0] == "" and _p[1].lower() == "subscriptions" and _p[2] != "" and _p[3].lower() == "resourcegroups" and _p[4] != "" and _p[5].lower() == "providers" and _p[6].lower() == "microsoft.containerservice" and _p[7].lower() == "managedclusters" and _p[8] != ""
    assert _ok, "backup-azure: spec.cluster.id must be an AKS ARM id (/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerService/managedClusters/<name>), got \"${id}\""
    {subscription = _p[2], resourceGroup = _p[4], name = _p[8]}
}

# Observed state of a composed resource; Undefined until the first reconcile.
_res = lambda ocds, name: str -> any {
    (ocds[name]?.Resource) if name in ocds else Undefined
}

_at = lambda ocds, name: str -> any {
    _res(ocds, name)?.status?.atProvider
}

# The resource's own last-applied forProvider, for staying rendered once it
# exists (see the header).
_fp = lambda ocds, name: str -> any {
    _res(ocds, name)?.spec?.forProvider
}

_ready_condition = lambda ocds, name: str -> any {
    _c = [c for c in (_res(ocds, name)?.status?.conditions or []) if c?.type == "Ready"]
    _c[0] if _c else Undefined
}

is_ready = lambda ocds, name: str -> bool {
    _ready_condition(ocds, name)?.status == "True"
}

# The three identities the role assignments grant to, as observed. The
# extension reports its identity as a list (aks_assigned_identity), the vault
# and the cluster as one block. The cluster's is its SYSTEM-assigned identity:
# an AKS cluster running on a user-assigned control-plane identity reports no
# principal here, and the README says so.
observed_principals = lambda ocds -> {str:str} {
    {
        extension = ((_at(ocds, _extension_resource)?.aksAssignedIdentity or [{}])[0])?.principalId or ""
        vault = _at(ocds, _vault_resource)?.identity?.principalId or ""
        cluster = _at(ocds, _cluster_resource)?.identity?.principalId or ""
    }
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _o = ocds or {}

    # --- validation ---------------------------------------------------------
    assert _spec?.cluster?.id, "backup-azure: spec.cluster.id is required — the AKS ARM id of the cluster to protect"
    _cl = parse_cluster_id(_spec.cluster.id)
    assert _spec.cluster?.region, "backup-azure: spec.cluster.region is required — an ARM id carries no location, and the vault, policy and instance must be created somewhere (use the cluster's own)"

    _dest = _spec?.destination
    assert _dest, "backup-azure: spec.destination is required — the AKS backup extension stages every backup in a blob container before the vault picks it up"
    assert _dest?.provider == "azure", "backup-azure: destination.provider must be azure — the AKS backup extension writes only to Azure Blob Storage"
    assert _dest?.bucket, "backup-azure: destination.bucket (the blob container) is required"
    assert _dest?.storageAccount, "backup-azure: destination.storageAccount is required — the extension addresses the container through its account"

    # Azure cannot hold a plan: the only way to stop protection is to delete
    # the backup instance, which deletes its recovery points with it.
    assert not _flag(_spec?.paused, False), "backup-azure: paused is not expressible — Azure stops protection only by deleting the backup instance, which deletes its backups; delete the XR (deletionPolicy Orphan keeps them) instead"

    # The XR name becomes the vault, policy and instance names, whose Azure
    # rules are the strictest of the three (vault 2-50, policy 3+, letters,
    # digits and hyphens).
    assert regex.match(_name, r"^[-a-zA-Z0-9]{3,50}$"), "backup-azure: metadata.name \"${_name}\" must be 3-50 letters, digits or hyphens — it names the Backup vault, policy and instance"

    _r = _spec?.retentionDays
    _retention = 30 if _r in [None, Undefined] else _r
    assert 1 <= _retention <= _max_retention_days, "backup-azure: retentionDays ${_retention} is out of range — Azure Backup for AKS keeps operational-tier backups 1 to ${_max_retention_days} days"

    _interval = repeating_interval(_spec.schedule)

    # --- derived values -----------------------------------------------------
    _cluster_id = _spec.cluster.id
    _rg = _cl.resourceGroup
    _region = _spec.cluster.region
    _snapshot_rg = _spec.cluster?.snapshotResourceGroup or _rg
    # The destination carries no subscription: the storage account is taken
    # to live in the cluster's (the README says so).
    _dest_rg = _dest?.resourceGroup or _rg
    _scopes = {
        storage = "/subscriptions/${_cl.subscription}/resourceGroups/${_dest_rg}/providers/Microsoft.Storage/storageAccounts/${_dest.storageAccount}"
        cluster = _cluster_id
        snapshot = "/subscriptions/${_cl.subscription}/resourceGroups/${_snapshot_rg}"
    }

    # Trusted-access binding names are 1-24 letters, digits or hyphens; a
    # longer XR name keeps a readable head plus a hash so it stays unique.
    _binding = _name if len(_name) <= 24 else "${_name[:15]}-${crypto.sha256(_name)[:8]}"

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _principals = observed_principals(_o)
    _vault_id = _at(_o, _vault_resource)?.id or ""
    _policy_id = _at(_o, _policy_resource)?.id or ""

    # The extension's own credentials.tenantId: the tenant the cluster
    # identity lives in (observed on the first pass), else the vault's. The
    # azurerm example reads it from the provider's client config, which a
    # composition cannot see — but the tenant is the same one either way.
    _cluster_ident = _at(_o, _cluster_resource)?.identity
    _tenant = _cluster_ident?.tenantId or _at(_o, _vault_resource)?.identity?.tenantId or (_fp(_o, _extension_resource)?.configurationSettings or {})["credentials.tenantId"] or ""

    # --- always: the cluster (observed), the vault and the policy -----------
    _items: [any] = [aks.KubernetesCluster {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = _cluster_resource
            "crossplane.io/external-name" = _cl.name
        }
        # Observe only, whatever deletionPolicy says: this XR reads the
        # cluster's identity and never owns the cluster.
        spec.managementPolicies = ["Observe"]
        spec.forProvider.resourceGroupName = _rg
    }, bv.BackupVault {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = _vault_resource
            # Pinned so status.storageLocation is known before anything
            # reconciles, and the policy can name its vault on pass 1.
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _region
        spec.forProvider.resourceGroupName = _rg
        # VaultStore + LocallyRedundant, as in the azurerm example. AKS
        # backups live in the operational tier (snapshots in the snapshot RG,
        # metadata in the blob container); the vault holds the catalogue.
        spec.forProvider.datastoreType = "VaultStore"
        spec.forProvider.redundancy = "LocallyRedundant"
        # The vault's own identity is what the role assignments below grant to.
        spec.forProvider.identity = {$type = "SystemAssigned"}
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }, bp.BackupPolicyKubernetesCluster {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = _policy_resource
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.resourceGroupName = _rg
        spec.forProvider.vaultName = _name
        spec.forProvider.backupRepeatingTimeIntervals = [_interval]
        # The interval above is written in UTC; say so, rather than leave
        # Azure to assume a zone.
        spec.forProvider.timeZone = "UTC"
        # The only data store a Kubernetes policy's lifecycle accepts.
        spec.forProvider.defaultRetentionRule.lifeCycle = [{
            dataStoreType = "OperationalStore"
            duration = "P${_retention}D"
        }]
    }]

    # --- the AKS backup extension -------------------------------------------
    if _tenant:
        _items += [ext.KubernetesClusterExtension {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = _extension_resource
                "crossplane.io/external-name" = _extension_name
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.clusterId = _cluster_id
            spec.forProvider.extensionType = _extension_type
            spec.forProvider.releaseTrain = "stable"
            spec.forProvider.releaseNamespace = _extension_namespace
            # The extension is Velero under the hood: these are its
            # BackupStorageLocation, spelled the azurerm example's way.
            spec.forProvider.configurationSettings = {
                "configuration.backupStorageLocation.bucket" = _dest.bucket
                "configuration.backupStorageLocation.config.resourceGroup" = _dest_rg
                "configuration.backupStorageLocation.config.storageAccount" = _dest.storageAccount
                "configuration.backupStorageLocation.config.subscriptionId" = _cl.subscription
                "credentials.tenantId" = _tenant
            }
        }]

    # --- trusted access: lets the vault operate the extension ---------------
    _source = _vault_id or _fp(_o, _trusted_access_resource)?.sourceResourceId or ""
    if _source:
        _items += [tarb.TrustedAccessRoleBinding {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = _trusted_access_resource
                "crossplane.io/external-name" = _binding
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.kubernetesClusterId = _cluster_id
            spec.forProvider.roles = _trusted_access_roles
            spec.forProvider.sourceResourceId = _source
        }]

    # --- role assignments, each once its principal is observed --------------
    _items += [ra.RoleAssignment {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = _g.name}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.principalId = _pid
        spec.forProvider.principalType = "ServicePrincipal"
        # The vault and extension identities are minutes old; skip the Entra
        # replication check that would otherwise fail their first attempt.
        spec.forProvider.skipServicePrincipalAadCheck = True
        spec.forProvider.roleDefinitionName = _g.role
        spec.forProvider.scope = _scopes[_g.scope]
    } for _g in _role_assignments for _pid in [_principals[_g.principal] or _fp(_o, _g.name)?.principalId or ""] if _pid]

    # --- the backup instance: last, and only on a fully wired cluster -------
    _prereqs = [_vault_resource, _policy_resource, _extension_resource, _trusted_access_resource] + [_g.name for _g in _role_assignments]
    _wired = all _n in _prereqs {
        is_ready(_o, _n)
    }
    _instance_vault = _vault_id or _fp(_o, _instance_resource)?.vaultId or ""
    _instance_policy = _policy_id or _fp(_o, _instance_resource)?.backupPolicyId or ""
    _namespaces = _spec?.includedNamespaces or []
    if (_wired or _instance_resource in _o) and _instance_vault and _instance_policy:
        _items += [bi.BackupInstanceKubernetesCluster {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = _instance_resource
                "crossplane.io/external-name" = _name
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.location = _region
            spec.forProvider.vaultId = _instance_vault
            spec.forProvider.backupPolicyId = _instance_policy
            spec.forProvider.kubernetesClusterId = _cluster_id
            spec.forProvider.snapshotResourceGroupName = _snapshot_rg
            # Every field below is ForceNew upstream (azurerm#33453), which
            # Upjet refuses to apply — see the README before editing filters.
            spec.forProvider.backupDatasourceParameters = {
                # Empty means every namespace to this XR; Azure spells that
                # as the field being absent.
                if _namespaces:
                    includedNamespaces = _namespaces
                if _spec?.includedResources:
                    includedResourceTypes = _spec.includedResources
                if _spec?.excludedResources:
                    excludedResourceTypes = _spec.excludedResources
                # "key=value", the same form `az dataprotection backup-instance
                # initialize-backupconfig --label-selectors` takes; sorted so
                # the render is stable.
                if _spec?.labelSelector:
                    labelSelectors = ["${_k}=${_spec.labelSelector[_k]}" for _k in sorted(_spec.labelSelector)]
                volumeSnapshotEnabled = _flag(_spec?.snapshotVolumes, True)
                # Velero's own default: namespaced objects alone restore into
                # a cluster missing their CRDs, ClusterRoles and PVs.
                clusterScopedResourcesEnabled = True
            }
        }]

    _items
}

# What a composed resource that has not been created yet is waiting for.
_waiting = {
    cluster = "not observed yet"
    vault = "not observed yet"
    policy = "not observed yet"
    extension = "waiting for the cluster's tenant id"
    "trusted-access" = "waiting for the Backup vault's id"
    "role-extension-storage" = "waiting for the backup extension's identity"
    "role-vault-cluster-reader" = "waiting for the Backup vault's identity"
    "role-vault-snapshot-reader" = "waiting for the Backup vault's identity"
    "role-vault-snapshot-contributor" = "waiting for the Backup vault's identity"
    "role-vault-disk-operator" = "waiting for the Backup vault's identity"
    "role-vault-storage" = "waiting for the Backup vault's identity"
    "role-cluster-snapshot-contributor" = "waiting for the cluster's system-assigned identity"
    managed = "waiting for the vault, policy, extension, trusted access and every role assignment to be Ready"
}

# Why one composed resource is not Ready: its own Ready condition's message,
# else its reason, else what it is still waiting for.
_why = lambda ocds, name: str -> str {
    _c = _ready_condition(ocds, name)
    _detail = (_c?.message or _c?.reason or "not Ready yet") if name in ocds else _waiting[name]
    "${name}: ${_detail}"
}

# Build the desired composite carrying observed status back to the XR.
# A backup only happens once every piece exists and is Ready — a vault with no
# instance, or an instance missing a role, protects nothing — so readiness is
# the AND over all of them and the first missing piece is named.
status = lambda oxr, ocds {
    _o = ocds or {}
    _pending = [_n for _n in _resource_names if not is_ready(_o, _n)]
    _phase = _at(_o, _instance_resource)?.protectionState or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "BackupPlan"
        metadata.name = oxr.metadata.name
        status = {
            provider = "azure"
            ready = len(_pending) == 0
            # The vault's name is pinned to the XR's, so it is known before
            # anything has reconciled.
            storageLocation = oxr.metadata.name
            # The instance's protection status (ProtectionConfigured,
            # ConfiguringProtection, ProtectionError, ...).
            if _phase:
                phase = _phase
            if _pending:
                message = _why(_o, _pending[0])
        }
    }
}
