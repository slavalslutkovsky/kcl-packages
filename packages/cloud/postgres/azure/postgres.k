# postgres (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-dbforpostgresql schema package. The portable
# PostgresInstance maps onto a Flexible Server, a companion
# FlexibleServerDatabase for the initial database, one
# FlexibleServerConfiguration per PostgreSQL parameter override (Azure has no
# parameter-group equivalent; each setting is its own resource), and — with
# workload identity — a FlexibleServerActiveDirectoryAdministrator admitting
# the AKS Workload Identity principal through Entra ID.
import azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server as server
import azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server_database as db
import azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server_configuration as config
import azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server_active_directory_administrator as admin

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Smallest Flexible Server SKU that holds `memoryGb`, ascending by memory (GiB).
_sku_ladder = [
    {gb = 2, sku = "B_Standard_B1ms"}
    {gb = 4, sku = "B_Standard_B2s"}
    {gb = 8, sku = "GP_Standard_D2s_v3"}
    {gb = 16, sku = "GP_Standard_D4s_v3"}
    {gb = 32, sku = "GP_Standard_D8s_v3"}
    {gb = 64, sku = "GP_Standard_D16s_v3"}
]

sku_for = lambda gb: float, ha: bool -> str {
    _fits = [_s.sku for _s in _sku_ladder if _s.gb >= gb]
    _sku = _fits[0] if _fits else _sku_ladder[-1].sku

    # Zone-redundant HA is unsupported on the Burstable (B_) tier; bump to the
    # smallest General Purpose SKU rather than render a server Azure rejects.
    "GP_Standard_D2s_v3" if ha and _sku.startswith("B_") else _sku
}

# Azure only accepts fixed storageMb steps; round the request UP to the
# smallest step that holds it. 32767 GB is Azure's real maximum (the top step
# is 33553408 MB, deliberately one GiB short of 32 TiB).
_storage_steps_gb = [32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32767]

storage_mb_for = lambda gb: int -> int {
    _fits = [_s for _s in _storage_steps_gb if _s >= gb]
    (_fits[0] if _fits else _storage_steps_gb[-1]) * 1024
}

# Azure numbers maintenance days from Sunday (sun = 0 .. sat = 6).
_azure_day = {"sun" = 0, "mon" = 1, "tue" = 2, "wed" = 3, "thu" = 4, "fri" = 5, "sat" = 6}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    # A Flexible Server cannot exist outside a resource group and this XR does
    # not manage one; fail loud instead of rendering a server Azure rejects.
    assert _spec?.resourceGroup, "the azure backend requires spec.resourceGroup"

    _database = _spec?.database or "app"
    _ha = _spec?.highAvailability or False
    _params = _spec?.parameters or {}

    # 0 is meaningful here (`or` would clobber it), but Azure cannot disable
    # backups anyway: clamp into its 7..35 range (the XRD documents the floor).
    _retention = _spec?.snapshotRetentionDays
    if _retention == Undefined:
        _retention = 7

    if _retention < 7:
        _retention = 7

    if _retention > 35:
        _retention = 35

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Workload identity: presence enables Entra ID authentication unless
    # explicitly switched off. Azure expresses the admitted principal as the
    # server's Entra administrator, which needs the full identity triple.
    # A nested reassignment does not escape its if-block in a KCL lambda, so
    # this is one expression: present, and not explicitly disabled.
    _wi = _spec?.workloadIdentity
    _iam = _wi not in [None, Undefined] and _wi?.enabled != False

    if _iam:
        assert _wi?.principal and _wi?.principalId and _wi?.tenantId, "the azure backend requires workloadIdentity.principal, principalId and tenantId"

    # encryptionKmsKeyId is ignored on Azure: its customer-managed key needs a
    # user-assigned identity with key vault access, which is beyond this XR.
    _items: [any] = [server.FlexibleServer {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        # Flexible Server versions are majors only ("16", never "16.4").
        spec.forProvider.version = _spec?.engineVersion or "16"
        spec.forProvider.skuName = _spec?.instanceClass or sku_for(_spec?.memoryGb or 2, _ha)
        spec.forProvider.storageMb = storage_mb_for(_spec?.storageGb or 20)
        spec.forProvider.administratorLogin = _spec?.username or "app"
        # Upjet reads the admin password from a Secret; when none is given it
        # generates one and writes it to the very same ref (the same read/write
        # duality as the AWS backend's auto-generated password).
        if _spec?.passwordSecret:
            spec.forProvider.administratorPasswordSecretRef = {
                name = _spec.passwordSecret.name
                key = _spec.passwordSecret?.key or "password"
            }
        else:
            spec.forProvider.autoGeneratePassword = True
            spec.forProvider.administratorPasswordSecretRef = {name = "${_name}-postgres-auth", key = "password"}
        if _iam:
            # Password auth stays on so status.authSecret keeps working for
            # consumers that have not moved to tokens yet.
            spec.forProvider.authentication = {
                activeDirectoryAuthEnabled = True
                passwordAuthEnabled = True
                tenantId = _wi.tenantId
            }
        spec.forProvider.publicNetworkAccessEnabled = _spec?.publicAccess or False
        if _spec?.network?.delegatedSubnetId:
            spec.forProvider.delegatedSubnetId = _spec.network.delegatedSubnetId
        if _spec?.network?.privateDnsZoneId:
            spec.forProvider.privateDnsZoneId = _spec.network.privateDnsZoneId
        spec.forProvider.backupRetentionDays = _retention
        if _ha:
            spec.forProvider.highAvailability = {mode = "ZoneRedundant"}
        if _spec?.maintenanceWindow:
            spec.forProvider.maintenanceWindow = {
                dayOfWeek = _azure_day[_spec.maintenanceWindow.day]
                startHour = _spec.maintenanceWindow.hour
                startMinute = 0
            }
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # The initial database is a companion MR bound to the server by controller
    # reference; its external name IS the database name Azure creates.
    _items += [db.FlexibleServerDatabase {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "database"
            "crossplane.io/external-name" = _database
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.serverIdSelector.matchControllerRef = True
    }]

    # The workload's own identity, admitted as the server's Entra
    # administrator. Entra grants full admin — Azure has no declarative
    # lesser IAM database principal; scope it down in SQL if needed.
    if _iam:
        _items += [admin.FlexibleServerActiveDirectoryAdministrator {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "entra-admin"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.resourceGroupName = _spec.resourceGroup
            spec.forProvider.serverNameSelector = {matchControllerRef = True}
            spec.forProvider.objectId = _wi.principalId
            spec.forProvider.principalName = _wi.principal
            spec.forProvider.principalType = _wi?.principalType or "ServicePrincipal"
            spec.forProvider.tenantId = _wi.tenantId
        }]

    # One FlexibleServerConfiguration per override, in sorted key order so the
    # render is deterministic.
    _items += [config.FlexibleServerConfiguration {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "param-" + _k}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.name = _k
        spec.forProvider.value = _params[_k]
        spec.forProvider.serverIdSelector.matchControllerRef = True
    } for _k in sorted(_params)]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _database = _spec?.database or "app"
    _host = _at?.fqdn or ""
    _port = 5432

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "PostgresInstance"
        metadata.name = _name
        status = {
            provider = "azure"
            ready = _host != ""
            port = _port
            database = _database
            username = _spec?.username or "app"
            if _spec?.passwordSecret:
                authSecret = _spec.passwordSecret.name
                authSecretKey = _spec.passwordSecret?.key or "password"
            else:
                authSecret = "${_name}-postgres-auth"
                authSecretKey = "password"
            if _host != "":
                host = _host
                endpoint = "${_host}:${_port}"
                readEndpoint = "${_host}:${_port}"
                url = "postgresql://${_host}:${_port}/${_database}"
            if _at:
                if _at?.version:
                    version = _at.version
                if _at?.id:
                    id = _at.id
                    # The ARM id starts with a /, so the concatenation is clean.
                    "cloud-url" = "https://portal.azure.com/#resource${_at.id}"
        }
    }
}
