import .postgres

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "PostgresInstance", metadata.name = "demo", spec = _spec}
}

_by_kind = lambda _items, _k {
    _hits = [_i for _i in _items if _i.kind == _k]
    _hits[0] if _hits else Undefined
}

# The Instance forProvider block from a render() of the given spec.
_fp = lambda _spec {
    postgres.render(_build(_spec))[0].spec.forProvider
}

# ---- render: shape ----------------------------------------------------------

# Minimal spec: one Instance, no ParameterGroup (no overrides given).
test_render_minimal = lambda {
    items = postgres.render(_build({region = "us-east-1"}))
    assert len(items) == 1, "minimal render must emit exactly one MR"
    assert items[0].apiVersion == "rds.aws.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "Instance", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    fp = items[0].spec.forProvider
    assert fp.region == "us-east-1", "region must be carried"
    assert fp.engine == "postgres", "engine must be postgres"
    assert fp.engineVersion == "16", "engine version must default to 16"
    assert fp.port == 5432, "port must default to 5432"
    assert fp.dbName == "app", "database must default to app"
    assert fp.username == "app", "username must default to app"
}

# ---- render: sizing ---------------------------------------------------------

# memoryGb picks the smallest instance class that fits, and instanceClass
# overrides it.
test_instance_class_mapping = lambda {
    assert postgres.class_for(0.5) == "db.t4g.micro", "below the floor must take the smallest class"
    assert postgres.class_for(1) == "db.t4g.micro", "an exact fit must not round up"
    assert postgres.class_for(2) == "db.t4g.small", "2 GiB must fit db.t4g.small"
    assert postgres.class_for(3) == "db.t4g.medium", "3 GiB must round up to db.t4g.medium"
    assert postgres.class_for(16) == "db.m7g.xlarge", "16 GiB must fit db.m7g.xlarge"
    assert postgres.class_for(1000) == "db.m7g.8xlarge", "above the ceiling must take the largest class"
    assert _fp({region = "us-east-1"}).instanceClass == "db.t4g.small", "memoryGb must default to 2 GiB"
    assert _fp({region = "us-east-1", memoryGb = 4}).instanceClass == "db.t4g.medium", "memoryGb must drive instanceClass"
    assert _fp({region = "us-east-1", memoryGb = 4, instanceClass = "db.r7g.large"}).instanceClass == "db.r7g.large", "instanceClass must override the mapping"
}

# ---- render: storage and encryption -----------------------------------------
test_storage = lambda {
    assert _fp({region = "us-east-1"}).allocatedStorage == 20, "storage must default to 20 GiB"
    assert _fp({region = "us-east-1", storageGb = 100}).allocatedStorage == 100, "storageGb must be carried"
}

test_encryption = lambda {
    fp = _fp({region = "us-east-1"})
    assert fp.storageEncrypted == True, "at-rest encryption must always be on"
    assert fp?.kmsKeyId == Undefined, "no CMEK unless asked for"
    cmek = _fp({region = "us-east-1", encryptionKmsKeyId = "arn:aws:kms:us-east-1:1:key/a"})
    assert cmek.storageEncrypted == True, "a CMEK must keep encryption on"
    assert cmek.kmsKeyId == "arn:aws:kms:us-east-1:1:key/a", "CMEK must be carried"
}

# ---- render: password -------------------------------------------------------

# With a user-supplied Secret the provider READS the password from it.
test_password_user_supplied = lambda {
    fp = _fp({region = "us-east-1", passwordSecret = {name = "pg-creds", key = "pw"}})
    assert fp.passwordSecretRef.name == "pg-creds", "the user Secret must be referenced"
    assert fp.passwordSecretRef.key == "pw", "the user key must be carried"
    assert fp?.autoGeneratePassword == Undefined, "a supplied password must not be regenerated"
    assert _fp({region = "us-east-1", passwordSecret = {name = "pg-creds"}}).passwordSecretRef.key == "password", "the Secret key must default to password"
}

# Without one, upjet WRITES a generated password to the referenced Secret.
test_password_auto_generated = lambda {
    fp = _fp({region = "us-east-1"})
    assert fp.autoGeneratePassword == True, "no Secret must auto-generate a password"
    assert fp.passwordSecretRef.name == "demo-postgres-auth", "generated password secret is named after the XR"
    assert fp.passwordSecretRef.key == "password", "generated password key must be stable"
}

# ---- render: HA and exposure ------------------------------------------------
test_high_availability = lambda {
    assert _fp({region = "us-east-1", highAvailability = True}).multiAz == True, "HA must enable multi-AZ"
    assert _fp({region = "us-east-1"}).multiAz == False, "multi-AZ must default off"
}

test_public_access = lambda {
    assert _fp({region = "us-east-1"}).publiclyAccessible == False, "public access must default off"
    assert _fp({region = "us-east-1", publicAccess = True}).publiclyAccessible == True, "publicAccess must be carried"
}

# ---- render: backups --------------------------------------------------------

# 0 disables backups on purpose, so the default must not clobber it.
test_backup_retention = lambda {
    assert _fp({region = "us-east-1"}).backupRetentionPeriod == 7, "retention must default to 7 days"
    assert _fp({region = "us-east-1", snapshotRetentionDays = 14}).backupRetentionPeriod == 14, "explicit retention must win"
    assert _fp({region = "us-east-1", snapshotRetentionDays = 0}).backupRetentionPeriod == 0, "an explicit 0 must disable backups"
}

# Without it RDS refuses deletion unless a finalSnapshotIdentifier is given,
# wedging the XR in Deleting.
test_skip_final_snapshot = lambda {
    assert _fp({region = "us-east-1"}).skipFinalSnapshot == True, "final snapshot must be skipped"
    assert _fp({region = "us-east-1", deletionPolicy = "Orphan"}).skipFinalSnapshot == True, "Orphan must not change it"
}

# ---- render: maintenance window --------------------------------------------
test_maintenance_window = lambda {
    assert postgres.window_for({day = "sun", hour = 5}) == "sun:05:00-sun:07:00", "hours must be zero-padded"
    assert postgres.window_for({day = "mon", hour = 0}) == "mon:00:00-mon:02:00", "midnight must render as 00:00"
    assert postgres.window_for({day = "sat", hour = 23}) == "sat:23:00-sun:01:00", "a window past midnight must roll to the next day"
    assert postgres.window_for({day = "sun", hour = 22}) == "sun:22:00-mon:00:00", "sunday must wrap to monday"
    assert _fp({region = "us-east-1", maintenanceWindow = {day = "wed", hour = 9}}).maintenanceWindow == "wed:09:00-wed:11:00", "window must be carried"
    assert _fp({region = "us-east-1"})?.maintenanceWindow == Undefined, "no window unless asked for"
}

# ---- render: network ---------------------------------------------------------
test_network = lambda {
    fp = _fp({region = "us-east-1", network = {subnetGroupName = "db-subnets", securityGroupIds = ["sg-1", "sg-2"]}})
    assert fp.dbSubnetGroupName == "db-subnets", "subnet group must be carried"
    assert fp.vpcSecurityGroupIds == ["sg-1", "sg-2"], "security groups must be carried"
    bare = _fp({region = "us-east-1"})
    assert bare?.dbSubnetGroupName == Undefined, "no subnet group unless asked for"
    assert bare?.vpcSecurityGroupIds == Undefined, "no security groups unless asked for"
}

# ---- render: parameters -----------------------------------------------------

# Overrides need a companion ParameterGroup; RDS has no forProvider.name, so
# the group's AWS name is pinned via the external-name annotation.
test_parameters_add_group = lambda {
    items = postgres.render(_build({region = "us-east-1", parameters = {"work_mem" = "64MB", "max_connections" = "200"}}))
    assert len(items) == 2, "parameters must add a ParameterGroup MR"
    _group = _by_kind(items, "ParameterGroup")
    assert _group != Undefined, "ParameterGroup must be present"
    assert _group.metadata.annotations["crossplane.io/external-name"] == "demo-params", "parameter group name must derive from the XR"
    assert len(_group.spec.forProvider.parameter) == 2, "two overrides -> two parameter entries"
    assert _group.spec.forProvider.parameter[0].name == "max_connections", "parameters must be emitted in a stable order"
    assert _group.spec.forProvider.parameter[0].value == "200", "parameter value must be carried"
    assert _group.spec.forProvider.parameter[1].name == "work_mem", "parameters must be emitted in a stable order"
    assert items[0].spec.forProvider.parameterGroupName == "demo-params", "instance must reference the parameter group"
}

test_parameter_group_family = lambda {
    assert postgres.family_for("16") == "postgres16", "family must follow the major version"
    assert postgres.family_for("16.4") == "postgres16", "family tracks the major version only"
    assert postgres.family_for("15") == "postgres15", "family must follow engineVersion"
    items = postgres.render(_build({region = "us-east-1", engineVersion = "15", parameters = {"work_mem" = "64MB"}}))
    assert _by_kind(items, "ParameterGroup").spec.forProvider.family == "postgres15", "family must follow engineVersion"
}

# ---- render: tags -----------------------------------------------------------
test_tags = lambda {
    items = postgres.render(_build({region = "us-east-1", tags = {team = "data"}, parameters = {"work_mem" = "64MB"}}))
    assert items[0].spec.forProvider.tags == {team = "data"}, "tags must reach the instance"
    assert _by_kind(items, "ParameterGroup").spec.forProvider.tags == {team = "data"}, "tags must reach companions"
    assert _fp({region = "us-east-1"})?.tags == Undefined, "no tags unless asked for"
}

# ---- render: deletion policy ------------------------------------------------

# Orphan must reach the companion MR too, or deleting the XR still drops the
# parameter group.
test_deletion_policy_orphan = lambda {
    items = postgres.render(_build({region = "us-east-1", deletionPolicy = "Orphan", parameters = {"work_mem" = "64MB"}}))
    assert items[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies"
    assert _by_kind(items, "ParameterGroup").spec.managementPolicies == _orphan, "Orphan must reach companions"
}

test_deletion_policy_delete_default = lambda {
    items = postgres.render(_build({region = "us-east-1"}))
    assert items[0].spec.managementPolicies != _orphan, "Delete must not set the orphan policies"
}

# ---- render: workload identity ------------------------------------------------

# Presence enables IAM database authentication; the in-database GRANT rds_iam
# and the rds-db:connect policy are out of band, so principal changes nothing.
test_workload_identity = lambda {
    assert _fp({region = "us-east-1", workloadIdentity = {}}).iamDatabaseAuthenticationEnabled == True, "presence must enable IAM auth"
    assert _fp({region = "us-east-1", workloadIdentity = {principal = "ignored"}}).iamDatabaseAuthenticationEnabled == True, "principal must not change the instance mapping"
    assert _fp({region = "us-east-1"})?.iamDatabaseAuthenticationEnabled == Undefined, "absent block must not touch IAM auth"
    assert _fp({region = "us-east-1", workloadIdentity = {enabled = False}})?.iamDatabaseAuthenticationEnabled == Undefined, "enabled=false must switch it off"
    items = postgres.render(_build({region = "us-east-1", workloadIdentity = {principal = "ignored"}}))
    assert len(items) == 1, "workload identity must not add resources on AWS"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = postgres.status(_build({region = "us-east-1"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "PostgresInstance", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status?.host == Undefined, "no host before the instance exists"
    assert dxr.status.port == 5432, "port is known ahead of creation"
    assert dxr.status.database == "app", "database must echo the effective default"
    assert dxr.status.username == "app", "username must echo the effective default"
    assert dxr.status.authSecret == "demo-postgres-auth", "auth secret name is known ahead of creation"
    assert dxr.status.authSecretKey == "password", "auth secret key must be published"
    assert dxr.status["cloud-url"].startswith("https://us-east-1.console.aws.amazon.com/rds"), "cloud-url must point at the RDS console"
}

# A user-supplied Secret must be echoed instead of the generated one.
test_status_user_secret = lambda {
    dxr = postgres.status(_build({region = "us-east-1", passwordSecret = {name = "pg-creds", key = "pw"}}), {})
    assert dxr.status.authSecret == "pg-creds", "auth secret must echo the supplied Secret"
    assert dxr.status.authSecretKey == "pw", "auth secret key must echo the supplied key"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        arn = "arn:aws:rds:us-east-1:1:db:demo"
                        id = "demo"
                        region = "us-east-1"
                        port = 5432
                        address = "demo.abc.us-east-1.rds.amazonaws.com"
                        engineVersionActual = "16.4"
                    }
                }
            }
        }
    }
    dxr = postgres.status(_build({region = "us-east-1"}), ocds)
    assert dxr.status.ready == True, "an observed address must mark the instance ready"
    assert dxr.status.host == "demo.abc.us-east-1.rds.amazonaws.com", "address must be the host"
    assert dxr.status.endpoint == "demo.abc.us-east-1.rds.amazonaws.com:5432", "endpoint must be host:port"
    assert dxr.status.readEndpoint == dxr.status.endpoint, "a single instance has no separate read endpoint"
    assert dxr.status.url == "postgresql://demo.abc.us-east-1.rds.amazonaws.com:5432/app", "url must carry the database, no credentials"
    assert dxr.status.version == "16.4", "the actual engine version must be surfaced"
    assert dxr.status.arn.endswith("db:demo"), "arn must be surfaced"
    assert dxr.status.id == "demo", "observed id must be surfaced"
    assert dxr.status["cloud-url"].endswith("#database:id=demo"), "cloud-url must target the observed id"
}
