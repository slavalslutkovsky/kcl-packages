import .postgres

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "PostgresInstance", metadata.name = "demo", spec = _spec}
}

# The DatabaseInstance forProvider block from a render().
_fp = lambda _spec {
    postgres.render(_build(_spec))[0].spec.forProvider
}

# ---- render: shape ----------------------------------------------------------

# Cloud SQL needs a companion Database MR for the initial database, so even the
# minimal render emits two resources; a User only appears with a passwordSecret.
test_render_minimal = lambda {
    items = postgres.render(_build({region = "us-central1"}))
    assert len(items) == 2, "minimal render must emit the DatabaseInstance and the Database"
    assert items[0].apiVersion == "sql.gcp.m.upbound.io/v1beta1", "wrong instance apiVersion"
    assert items[0].kind == "DatabaseInstance", "wrong instance kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "instance must be the managed resource"
    assert items[1].kind == "Database", "second resource must be the Database"
    fp = items[0].spec.forProvider
    assert fp.region == "us-central1", "region must be carried"
    assert fp.deletionProtection == False, "the Terraform-level guard must be off, or deletes hang"
    assert fp.settings.diskSize == 20, "storageGb must default to 20"
}

test_render_with_password_secret = lambda {
    items = postgres.render(_build({region = "us-central1", passwordSecret = {name = "pg-creds"}}))
    assert len(items) == 3, "a passwordSecret must add the User MR"
    assert items[2].kind == "User", "third resource must be the User"
}

# ---- render: version --------------------------------------------------------
test_version_mapping = lambda {
    assert postgres.version_for("16") == "POSTGRES_16", "major version maps to the enum"
    assert postgres.version_for("9.6") == "POSTGRES_9_6", "dots become underscores"
    assert _fp({region = "us-central1"}).databaseVersion == "POSTGRES_16", "engineVersion defaults to 16"
    assert _fp({region = "us-central1", engineVersion = "15"}).databaseVersion == "POSTGRES_15", "engineVersion must be carried"
}

# ---- render: tier -----------------------------------------------------------
test_tier_ladder = lambda {
    assert postgres.tier_for(1) == "db-custom-1-3840", "small requests take the smallest rung"
    assert postgres.tier_for(3.75) == "db-custom-1-3840", "a boundary fits its own rung"
    assert postgres.tier_for(4) == "db-custom-2-7680", "just over a rung takes the next one"
    assert postgres.tier_for(15) == "db-custom-4-15360", "15 GiB fits four vCPUs"
    assert postgres.tier_for(31) == "db-custom-16-61440", "past 30 GiB takes the largest rungs"
    assert postgres.tier_for(500) == "db-custom-16-61440", "oversize requests take the largest rung"
    assert _fp({region = "us-central1"}).settings.tier == "db-custom-1-3840", "memoryGb defaults to 2 -> smallest rung"
    assert _fp({region = "us-central1", memoryGb = 8}).settings.tier == "db-custom-4-15360", "memoryGb must pick the smallest fitting rung"
}

test_instance_class_override = lambda {
    fp = _fp({region = "us-central1", memoryGb = 8, instanceClass = "db-custom-2-13312"})
    assert fp.settings.tier == "db-custom-2-13312", "instanceClass must override the memoryGb mapping"
}

# ---- render: availability and disk ------------------------------------------
test_availability = lambda {
    assert _fp({region = "us-central1"}).settings.availabilityType == "ZONAL", "no HA -> ZONAL"
    assert _fp({region = "us-central1", highAvailability = True}).settings.availabilityType == "REGIONAL", "HA -> REGIONAL"
}

test_disk_size = lambda {
    assert _fp({region = "us-central1", storageGb = 100}).settings.diskSize == 100, "storageGb -> diskSize"
}

# ---- render: backups ----------------------------------------------------------

# snapshotRetentionDays=0 disables backups, so the default must not be applied
# with `or` (which would treat 0 as unset).
test_backup_retention = lambda {
    _default = _fp({region = "us-central1"}).settings.backupConfiguration
    assert _default.enabled == True, "backups default on"
    assert _default.backupRetentionSettings.retainedBackups == 7, "retention defaults to 7"
    assert _default.backupRetentionSettings.retentionUnit == "COUNT", "retention is a backup count"
    _long = _fp({region = "us-central1", snapshotRetentionDays = 30}).settings.backupConfiguration
    assert _long.backupRetentionSettings.retainedBackups == 30, "retention must be carried"
    _off = _fp({region = "us-central1", snapshotRetentionDays = 0}).settings.backupConfiguration
    assert _off.enabled == False, "retention 0 must disable backups"
    assert _off?.backupRetentionSettings == Undefined, "no retention settings when backups are off"
}

# ---- render: networking -------------------------------------------------------

# Cloud SQL requires at least one interface: no private network forces the
# public address on regardless of publicAccess.
test_ip_configuration = lambda {
    _none = _fp({region = "us-central1"}).settings.ipConfiguration
    assert _none.ipv4Enabled == True, "no network -> public IPv4 stays on"
    assert _none?.privateNetwork == Undefined, "no private network unless asked for"
    _vpc = "projects/p/global/networks/default"
    _private = _fp({region = "us-central1", network = {id = _vpc}}).settings.ipConfiguration
    assert _private.privateNetwork == _vpc, "network.id -> privateNetwork"
    assert _private.ipv4Enabled == False, "a private network turns the public address off"
    _both = _fp({region = "us-central1", network = {id = _vpc}, publicAccess = True}).settings.ipConfiguration
    assert _both.privateNetwork == _vpc, "publicAccess must keep the private network"
    assert _both.ipv4Enabled == True, "publicAccess must keep the public address"
}

# ---- render: flags, labels, maintenance ---------------------------------------
test_database_flags_sorted = lambda {
    _flags = _fp({region = "us-central1", parameters = {"work_mem" = "64MB", "max_connections" = "200"}}).settings.databaseFlags
    assert len(_flags) == 2, "both flags must be emitted"
    assert _flags[0].name == "max_connections" and _flags[0].value == "200", "flags must be emitted in a stable sorted order"
    assert _flags[1].name == "work_mem" and _flags[1].value == "64MB", "flags must be emitted in a stable sorted order"
    assert _fp({region = "us-central1"}).settings?.databaseFlags == Undefined, "no flags unless asked for"
}

test_labels = lambda {
    assert _fp({region = "us-central1", tags = {team = "platform"}}).settings.userLabels == {team = "platform"}, "tags -> userLabels"
    assert _fp({region = "us-central1"}).settings?.userLabels == Undefined, "no labels unless asked for"
}

test_maintenance_window = lambda {
    _w = _fp({region = "us-central1", maintenanceWindow = {day = "wed", hour = 3}}).settings.maintenanceWindow
    assert _w.day == 3, "day must map to Cloud SQL's 1-7 numbering (Monday=1)"
    assert _w.hour == 3, "hour must be carried"
    assert _fp({region = "us-central1", maintenanceWindow = {day = "mon", hour = 0}}).settings.maintenanceWindow.day == 1, "mon -> 1"
    assert _fp({region = "us-central1", maintenanceWindow = {day = "sun", hour = 23}}).settings.maintenanceWindow.day == 7, "sun -> 7"
    assert _fp({region = "us-central1"}).settings?.maintenanceWindow == Undefined, "no window unless asked for"
}

# ---- render: encryption -------------------------------------------------------
test_cmek = lambda {
    _key = "projects/p/locations/us-central1/keyRings/r/cryptoKeys/k"
    assert _fp({region = "us-central1", encryptionKmsKeyId = _key}).encryptionKeyName == _key, "CMEK must be carried"
    assert _fp({region = "us-central1"})?.encryptionKeyName == Undefined, "no CMEK unless asked for"
}

# ---- render: companion Database and User --------------------------------------

# Crossplane names both companions through their external-name annotation.
test_database_external_name = lambda {
    _dbr = postgres.render(_build({region = "us-central1"}))[1]
    assert _dbr.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "database", "the Database gets its own stable name"
    assert _dbr.metadata.annotations["crossplane.io/external-name"] == "app", "database defaults to app"
    assert _dbr.spec.forProvider.instanceSelector.matchControllerRef == True, "the Database must bind to this XR's instance"
    _named = postgres.render(_build({region = "us-central1", database = "orders"}))[1]
    assert _named.metadata.annotations["crossplane.io/external-name"] == "orders", "database must be carried"
}

test_user_from_password_secret = lambda {
    _usr = postgres.render(_build({region = "us-central1", username = "owner", passwordSecret = {name = "pg-creds", key = "pw"}}))[2]
    assert _usr.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "user", "the User gets its own stable name"
    assert _usr.metadata.annotations["crossplane.io/external-name"] == "owner", "username must be carried"
    assert _usr.spec.forProvider.instanceSelector.matchControllerRef == True, "the User must bind to this XR's instance"
    assert _usr.spec.forProvider.passwordSecretRef.name == "pg-creds", "the password comes from the caller's Secret"
    assert _usr.spec.forProvider.passwordSecretRef.key == "pw", "the caller's Secret key must be carried"
    _defaulted = postgres.render(_build({region = "us-central1", passwordSecret = {name = "pg-creds"}}))[2]
    assert _defaulted.spec.forProvider.passwordSecretRef.key == "password", "the Secret key defaults to password"
}

# ---- render: deletion policy --------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = postgres.render(_build({region = "us-central1", deletionPolicy = "Orphan", passwordSecret = {name = "pg-creds"}}))
    assert _orphaned[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies"
    assert _orphaned[1].spec.managementPolicies == _orphan, "the Database must be orphaned too"
    assert _orphaned[2].spec.managementPolicies == _orphan, "the User must be orphaned too"
    _deleted = postgres.render(_build({region = "us-central1"}))[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- render: workload identity --------------------------------------------------

# Presence turns the IAM auth flag on; an explicit user override of the same
# flag must win, and the principal becomes an IAM-typed User.
test_workload_identity_flag = lambda {
    _flags = _fp({region = "us-central1", workloadIdentity = {}}).settings.databaseFlags
    assert len(_flags) == 1 and _flags[0].name == "cloudsql.iam_authentication" and _flags[0].value == "on", "presence must enable the IAM auth flag"
    _over = _fp({region = "us-central1", workloadIdentity = {}, parameters = {"cloudsql.iam_authentication" = "off"}}).settings.databaseFlags
    assert len(_over) == 1 and _over[0].value == "off", "a user parameter must win over the flag"
    assert _fp({region = "us-central1"}).settings?.databaseFlags == Undefined, "absent block must not add flags"
    assert _fp({region = "us-central1", workloadIdentity = {enabled = False, principal = "sa@p.iam.gserviceaccount.com"}}).settings?.databaseFlags == Undefined, "enabled=false must switch it off"
}

# Cloud SQL admits service accounts under their email minus .gserviceaccount.com.
test_workload_identity_principal = lambda {
    _sa = postgres.iam_user_for("app@proj.iam.gserviceaccount.com")
    assert _sa.name == "app@proj.iam", "the SA suffix must be stripped"
    assert _sa.$type == "CLOUD_IAM_SERVICE_ACCOUNT", "an SA email maps to the SA user type"
    _human = postgres.iam_user_for("dev@example.org")
    assert _human.name == "dev@example.org", "user emails are admitted verbatim"
    assert _human.$type == "CLOUD_IAM_USER", "a plain email maps to the IAM user type"
}

test_workload_identity_user_mr = lambda {
    items = postgres.render(_build({region = "us-central1", workloadIdentity = {principal = "app@proj.iam.gserviceaccount.com"}}))
    assert len(items) == 3, "the principal must add an IAM User MR"
    _u = [_i for _i in items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "iam-user"][0]
    assert _u.metadata.annotations["crossplane.io/external-name"] == "app@proj.iam", "the external name is the truncated SA email"
    assert _u.spec.forProvider.$type == "CLOUD_IAM_SERVICE_ACCOUNT", "the user type must be carried"
    assert _u.spec.forProvider.instanceSelector.matchControllerRef == True, "the IAM user must bind to this instance"
    assert _u.spec.forProvider?.passwordSecretRef == Undefined, "IAM users must not carry a password"
    assert len(postgres.render(_build({region = "us-central1", workloadIdentity = {}}))) == 2, "no principal, no extra User"
}

# Orphan must reach the IAM user too.
test_workload_identity_orphan = lambda {
    items = postgres.render(_build({region = "us-central1", deletionPolicy = "Orphan", workloadIdentity = {principal = "app@proj.iam.gserviceaccount.com"}}))
    _u = [_i for _i in items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "iam-user"][0]
    assert _u.spec.managementPolicies == _orphan, "Orphan must reach the IAM user"
}

# ---- status -------------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = postgres.status(_build({region = "us-central1"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "PostgresInstance", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status?.host == Undefined, "no host before the instance exists"
    assert dxr.status.port == 5432, "port is always Postgres"
    assert dxr.status.database == "app", "database echoes its default"
    assert dxr.status.username == "app", "username echoes its default"
    assert dxr.status?.authSecret == Undefined, "no auth secret without a passwordSecret"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/sql/instances/demo/overview", "cloud-url falls back to the XR name"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = "demo-instance"
                        privateIpAddress = "10.1.0.3"
                        publicIpAddress = "34.1.2.3"
                        firstIpAddress = "34.1.2.3"
                        databaseVersion = "POSTGRES_16"
                    }
                }
            }
        }
    }
    dxr = postgres.status(_build({region = "us-central1", database = "orders", username = "owner", passwordSecret = {name = "pg-creds", key = "pw"}}), ocds)
    assert dxr.status.ready == True, "an observed address must mark the instance ready"
    assert dxr.status.host == "10.1.0.3", "the private address must win over the public one"
    assert dxr.status.endpoint == "10.1.0.3:5432", "endpoint must be host:port"
    assert dxr.status.readEndpoint == "10.1.0.3:5432", "no separate read service -> readEndpoint equals endpoint"
    assert dxr.status.url == "postgresql://10.1.0.3:5432/orders", "url must carry the effective database"
    assert dxr.status.database == "orders", "database must echo the effective value"
    assert dxr.status.username == "owner", "username must echo the effective value"
    assert dxr.status.authSecret == "pg-creds", "auth secret echoes the caller's Secret"
    assert dxr.status.authSecretKey == "pw", "auth secret key echoes the caller's key"
    assert dxr.status.version == "POSTGRES_16", "version reports the raw Cloud SQL enum"
    assert dxr.status.id == "demo-instance", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/sql/instances/demo-instance/overview", "cloud-url must use the observed id"
}

# Without a private interface the host falls back to the public address, then
# to whatever interface Cloud SQL reported first.
test_status_host_preference = lambda {
    _public = postgres.status(_build({region = "us-central1"}), {
        managed = {
            Resource = {
                status = {
                    atProvider = {publicIpAddress = "34.1.2.3", firstIpAddress = "34.1.2.3"}
                }
            }
        }
    })
    assert _public.status.host == "34.1.2.3", "no private address -> the public one"
    _first = postgres.status(_build({region = "us-central1"}), {
        managed = {
            Resource = {
                status = {
                    atProvider = {firstIpAddress = "2600::1"}
                }
            }
        }
    })
    assert _first.status.host == "2600::1", "last resort is the first reported interface"
}
