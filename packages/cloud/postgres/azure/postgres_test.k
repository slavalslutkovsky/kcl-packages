import .postgres

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "PostgresInstance", metadata.name = "demo", spec = _spec}
}

_by_name = lambda _items, _n {
    _hits = [_i for _i in _items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == _n]
    _hits[0] if _hits else Undefined
}

# The FlexibleServer forProvider block from a render() of the given spec.
_fp = lambda _spec {
    postgres.render(_build(_spec))[0].spec.forProvider
}

# ---- render: shape ----------------------------------------------------------

# Minimal spec: the server plus its initial database, no configurations.
test_render_minimal = lambda {
    items = postgres.render(_build({region = "westeurope", resourceGroup = "demo-rg"}))
    assert len(items) == 2, "minimal render must emit the server and its database"
    assert items[0].apiVersion == "dbforpostgresql.azure.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "FlexibleServer", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    fp = items[0].spec.forProvider
    assert fp.location == "westeurope", "region must be carried as the location"
    assert fp.resourceGroupName == "demo-rg", "resource group must be carried"
    assert fp.version == "16", "engine version must default to 16"
    assert fp.administratorLogin == "app", "admin login must default to app"
    assert fp.publicNetworkAccessEnabled == False, "public access must default off"
}

# The initial database rides along as a companion MR whose external name is
# the database name Azure creates.
test_render_database = lambda {
    items = postgres.render(_build({region = "westeurope", resourceGroup = "demo-rg"}))
    _dbr = _by_name(items, "database")
    assert _dbr != Undefined, "the database MR must be present"
    assert _dbr.kind == "FlexibleServerDatabase", "wrong database kind"
    assert _dbr.metadata.annotations["crossplane.io/external-name"] == "app", "database name must default to app"
    assert _dbr.spec.forProvider.serverIdSelector.matchControllerRef == True, "database must bind to the server by controller ref"
    named = postgres.render(_build({region = "westeurope", resourceGroup = "demo-rg", database = "orders"}))
    assert _by_name(named, "database").metadata.annotations["crossplane.io/external-name"] == "orders", "explicit database name must win"
}

# ---- render: sizing ---------------------------------------------------------

# memoryGb picks the smallest SKU that fits, and instanceClass overrides it.
test_sku_mapping = lambda {
    assert postgres.sku_for(1, False) == "B_Standard_B1ms", "below the floor must take the smallest SKU"
    assert postgres.sku_for(2, False) == "B_Standard_B1ms", "an exact fit must not round up"
    assert postgres.sku_for(3, False) == "B_Standard_B2s", "3 GiB must fit B_Standard_B2s"
    assert postgres.sku_for(16, False) == "GP_Standard_D4s_v3", "16 GiB must fit GP_Standard_D4s_v3"
    assert postgres.sku_for(1000, False) == "GP_Standard_D16s_v3", "above the ceiling must take the largest SKU"
    assert _fp({region = "westeurope", resourceGroup = "demo-rg", memoryGb = 4}).skuName == "B_Standard_B2s", "memoryGb must drive skuName"
    assert _fp({region = "westeurope", resourceGroup = "demo-rg", memoryGb = 4, instanceClass = "MO_Standard_E4s_v3"}).skuName == "MO_Standard_E4s_v3", "instanceClass must override the mapping"
}

# Zone-redundant HA is unsupported on the Burstable tier, so an HA request on
# a B_ rung must bump to General Purpose — but an explicit instanceClass is
# trusted as-is.
test_sku_ha_bumps_burstable = lambda {
    assert postgres.sku_for(2, True) == "GP_Standard_D2s_v3", "HA must bump a burstable pick to GP"
    assert postgres.sku_for(16, True) == "GP_Standard_D4s_v3", "HA must not touch a non-burstable pick"
    fp = _fp({region = "westeurope", resourceGroup = "demo-rg", highAvailability = True})
    assert fp.skuName == "GP_Standard_D2s_v3", "the default HA pick must be GP"
    trusted = _fp({region = "westeurope", resourceGroup = "demo-rg", highAvailability = True, instanceClass = "B_Standard_B1ms"})
    assert trusted.skuName == "B_Standard_B1ms", "an explicit instanceClass must be trusted as-is"
}

# Azure only accepts fixed storageMb steps; storageGb rounds UP to one.
test_storage_rounding = lambda {
    assert postgres.storage_mb_for(20) == 32768, "the default 20 GiB must round up to the 32 GiB floor"
    assert postgres.storage_mb_for(50) == 65536, "50 GiB must round up to the 64 GiB step"
    assert postgres.storage_mb_for(64) == 65536, "an exact step must not round up"
    assert postgres.storage_mb_for(100000) == 33553408, "above the ceiling must take the 32767 GiB top step"
    assert _fp({region = "westeurope", resourceGroup = "demo-rg"}).storageMb == 32768, "storageGb must default to 20 -> 32768 MB"
    assert _fp({region = "westeurope", resourceGroup = "demo-rg", storageGb = 50}).storageMb == 65536, "storageGb must drive storageMb"
}

# ---- render: password -------------------------------------------------------

# No passwordSecret: the provider generates one and writes it to a Secret named
# after the XR (the ref is both read and written by upjet).
test_password_generated = lambda {
    fp = _fp({region = "westeurope", resourceGroup = "demo-rg"})
    assert fp.autoGeneratePassword == True, "password must be auto-generated by default"
    assert fp.administratorPasswordSecretRef.name == "demo-postgres-auth", "generated password secret is named after the XR"
    assert fp.administratorPasswordSecretRef.key == "password", "generated password key must be stable"
}

# An existing passwordSecret is read as-is, and nothing is generated.
test_password_supplied = lambda {
    fp = _fp({region = "westeurope", resourceGroup = "demo-rg", passwordSecret = {name = "my-secret"}})
    assert fp?.autoGeneratePassword == Undefined, "a supplied secret must not trigger generation"
    assert fp.administratorPasswordSecretRef.name == "my-secret", "supplied secret name must be carried"
    assert fp.administratorPasswordSecretRef.key == "password", "secret key must default to password"
    keyed = _fp({region = "westeurope", resourceGroup = "demo-rg", passwordSecret = {name = "my-secret", key = "pw"}})
    assert keyed.administratorPasswordSecretRef.key == "pw", "an explicit secret key must be carried"
}

# ---- render: backups --------------------------------------------------------

# Azure cannot disable backups; retention clamps into its 7..35 range.
test_retention_clamp = lambda {
    assert _fp({region = "westeurope", resourceGroup = "demo-rg"}).backupRetentionDays == 7, "retention must default to 7"
    assert _fp({region = "westeurope", resourceGroup = "demo-rg", snapshotRetentionDays = 0}).backupRetentionDays == 7, "0 must clamp to the 7-day floor"
    assert _fp({region = "westeurope", resourceGroup = "demo-rg", snapshotRetentionDays = 40}).backupRetentionDays == 35, "retention must clamp to the 35-day ceiling"
    assert _fp({region = "westeurope", resourceGroup = "demo-rg", snapshotRetentionDays = 14}).backupRetentionDays == 14, "an in-range retention must be carried"
}

# ---- render: HA ---------------------------------------------------------------
test_high_availability = lambda {
    fp = _fp({region = "westeurope", resourceGroup = "demo-rg", highAvailability = True})
    assert fp.highAvailability.mode == "ZoneRedundant", "HA must request zone-redundant mode"
    off = _fp({region = "westeurope", resourceGroup = "demo-rg"})
    assert off?.highAvailability == Undefined, "no HA block unless asked for"
}

# ---- render: maintenance window ----------------------------------------------

# Azure numbers days from Sunday (sun = 0 .. sat = 6).
test_maintenance_window = lambda {
    fp = _fp({region = "westeurope", resourceGroup = "demo-rg", maintenanceWindow = {day = "sun", hour = 5}})
    assert fp.maintenanceWindow.dayOfWeek == 0, "sunday must map to 0"
    assert fp.maintenanceWindow.startHour == 5, "start hour must be carried"
    assert fp.maintenanceWindow.startMinute == 0, "start minute must be 0"
    sat = _fp({region = "westeurope", resourceGroup = "demo-rg", maintenanceWindow = {day = "sat", hour = 23}})
    assert sat.maintenanceWindow.dayOfWeek == 6, "saturday must map to 6"
    assert _fp({region = "westeurope", resourceGroup = "demo-rg"})?.maintenanceWindow == Undefined, "no window unless asked for"
}

# ---- render: parameters -------------------------------------------------------

# Each override is its own FlexibleServerConfiguration, in sorted key order so
# the render is deterministic.
test_parameters_add_configurations = lambda {
    items = postgres.render(_build({region = "westeurope", resourceGroup = "demo-rg", parameters = {"max_connections" = "100", "log_statement" = "all"}}))
    assert len(items) == 4, "two overrides must add two configuration MRs"
    _cfgs = [_i for _i in items if _i.kind == "FlexibleServerConfiguration"]
    assert len(_cfgs) == 2, "each override must be its own configuration"
    assert _cfgs[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "param-log_statement", "configurations must be sorted by key"
    assert _cfgs[0].spec.forProvider.name == "log_statement", "parameter name must be carried"
    assert _cfgs[0].spec.forProvider.value == "all", "parameter value must be carried"
    assert _cfgs[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "param-max_connections", "configurations must be sorted by key"
    assert _cfgs[1].spec.forProvider.value == "100", "parameter value must be carried"
    assert _cfgs[0].spec.forProvider.serverIdSelector.matchControllerRef == True, "configurations must bind to the server by controller ref"
}

# ---- render: network ----------------------------------------------------------
test_network = lambda {
    fp = _fp({region = "westeurope", resourceGroup = "demo-rg", network = {delegatedSubnetId = "/subnets/db", privateDnsZoneId = "/dnszones/db"}})
    assert fp.delegatedSubnetId == "/subnets/db", "delegated subnet must be carried"
    assert fp.privateDnsZoneId == "/dnszones/db", "private DNS zone must be carried"
    bare = _fp({region = "westeurope", resourceGroup = "demo-rg"})
    assert bare?.delegatedSubnetId == Undefined, "no subnet unless asked for"
    assert bare?.privateDnsZoneId == Undefined, "no DNS zone unless asked for"
}

test_public_access = lambda {
    fp = _fp({region = "westeurope", resourceGroup = "demo-rg", publicAccess = True})
    assert fp.publicNetworkAccessEnabled == True, "publicAccess must be carried"
}

test_tags = lambda {
    fp = _fp({region = "westeurope", resourceGroup = "demo-rg", tags = {team = "data"}})
    assert fp.tags == {team = "data"}, "tags must be carried"
    assert _fp({region = "westeurope", resourceGroup = "demo-rg"})?.tags == Undefined, "no tags unless asked for"
}

# ---- render: deletion policy --------------------------------------------------

# Orphan must reach the companions too, or deleting the XR still drops the
# database and every configuration.
test_deletion_policy_orphan = lambda {
    items = postgres.render(_build({region = "westeurope", resourceGroup = "demo-rg", deletionPolicy = "Orphan", parameters = {"max_connections" = "100"}}))
    assert items[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies"
    assert _by_name(items, "database").spec.managementPolicies == _orphan, "Orphan must reach the database"
    assert _by_name(items, "param-max_connections").spec.managementPolicies == _orphan, "Orphan must reach the configurations"
}

test_deletion_policy_delete_default = lambda {
    items = postgres.render(_build({region = "westeurope", resourceGroup = "demo-rg"}))
    assert items[0].spec.managementPolicies != _orphan, "Delete must not set the orphan policies"
}

# ---- render: workload identity --------------------------------------------------
_wi = {principal = "app-workload", principalId = "00000000-0000-0000-0000-000000000001", tenantId = "00000000-0000-0000-0000-0000000000aa"}

# Presence enables Entra ID auth (passwords stay on) and admits the principal
# as the server's Entra administrator.
test_workload_identity = lambda {
    items = postgres.render(_build({region = "westeurope", resourceGroup = "demo-rg", workloadIdentity = _wi}))
    fp = items[0].spec.forProvider
    assert fp.authentication.activeDirectoryAuthEnabled == True, "presence must enable Entra auth"
    assert fp.authentication.passwordAuthEnabled == True, "password auth must stay on for existing consumers"
    assert fp.authentication.tenantId == _wi.tenantId, "the tenant must be carried"
    _a = _by_name(items, "entra-admin")
    assert _a.spec.forProvider.objectId == _wi.principalId, "the object id must be carried"
    assert _a.spec.forProvider.principalName == _wi.principal, "the principal name must be carried"
    assert _a.spec.forProvider.principalType == "ServicePrincipal", "the principal type defaults to ServicePrincipal"
    assert _a.spec.forProvider.tenantId == _wi.tenantId, "the admin must live in the same tenant"
    assert _a.spec.forProvider.resourceGroupName == "demo-rg", "the admin must target the server's resource group"
    assert _a.spec.forProvider.serverNameSelector.matchControllerRef == True, "the admin must bind to this server"
}

test_workload_identity_off = lambda {
    items = postgres.render(_build({region = "westeurope", resourceGroup = "demo-rg"}))
    assert items[0].spec.forProvider?.authentication == Undefined, "absent block must not touch authentication"
    assert len([_i for _i in items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "entra-admin"]) == 0, "no admin without workload identity"
    _disabled = postgres.render(_build({region = "westeurope", resourceGroup = "demo-rg", workloadIdentity = {enabled = False, principal = _wi.principal, principalId = _wi.principalId, tenantId = _wi.tenantId}}))
    assert _disabled[0].spec.forProvider?.authentication == Undefined, "enabled=false must switch it off"
    assert len(_disabled) == 2, "enabled=false must not add the admin MR"
}

test_workload_identity_orphan = lambda {
    items = postgres.render(_build({region = "westeurope", resourceGroup = "demo-rg", deletionPolicy = "Orphan", workloadIdentity = {principal = _wi.principal, principalId = _wi.principalId, tenantId = _wi.tenantId, principalType = "Group"}}))
    _a = _by_name(items, "entra-admin")
    assert _a.spec.managementPolicies == _orphan, "Orphan must reach the Entra admin"
    assert _a.spec.forProvider.principalType == "Group", "an explicit principal type must be carried"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = postgres.status(_build({region = "westeurope", resourceGroup = "demo-rg"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "PostgresInstance", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.port == 5432, "port must be 5432"
    assert dxr.status?.host == Undefined, "no host before the server exists"
    assert dxr.status?["cloud-url"] == Undefined, "no portal URL before the ARM id is known"
    assert dxr.status.database == "app", "database must echo the effective default"
    assert dxr.status.username == "app", "username must echo the effective default"
    assert dxr.status.authSecret == "demo-postgres-auth", "auth secret name is known ahead of creation"
    assert dxr.status.authSecretKey == "password", "auth secret key must be published"
}

test_status_observed = lambda {
    _arm_id = "/subscriptions/1/resourceGroups/demo-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/demo"
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = _arm_id
                        fqdn = "demo.postgres.database.azure.com"
                        version = "16"
                    }
                }
            }
        }
    }
    dxr = postgres.status(_build({region = "westeurope", resourceGroup = "demo-rg"}), ocds)
    assert dxr.status.ready == True, "an observed FQDN must mark the instance ready"
    assert dxr.status.host == "demo.postgres.database.azure.com", "the FQDN must be the host"
    assert dxr.status.endpoint == "demo.postgres.database.azure.com:5432", "endpoint must be host:port"
    assert dxr.status.readEndpoint == dxr.status.endpoint, "no separate read service, so readEndpoint equals endpoint"
    assert dxr.status.url == "postgresql://demo.postgres.database.azure.com:5432/app", "url must carry the database and no credentials"
    assert dxr.status.version == "16", "the running version must be surfaced"
    assert dxr.status.id == _arm_id, "the ARM id must be surfaced"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#resource${_arm_id}", "portal URL must be built from the ARM id"
}

# A supplied passwordSecret is echoed back instead of the generated one.
test_status_password_secret_echo = lambda {
    dxr = postgres.status(_build({region = "westeurope", resourceGroup = "demo-rg", passwordSecret = {name = "my-secret", key = "pw"}}), {})
    assert dxr.status.authSecret == "my-secret", "authSecret must echo the supplied secret"
    assert dxr.status.authSecretKey == "pw", "authSecretKey must echo the supplied key"
}
