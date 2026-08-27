# postgres (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-rds schema package. The portable PostgresInstance maps
# onto a single RDS Instance; Postgres config overrides need a companion
# ParameterGroup MR, which RDS binds by name. The RDS ParameterGroup carries no
# forProvider.name — its AWS name is the Crossplane external name — so the
# group pins it via the crossplane.io/external-name annotation.
import aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_instance as db
import aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_parameter_group as pg

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Smallest RDS instance class that holds `memoryGb`, ascending by memory (GiB).
# Graviton generations only — they are the current-gen default in every
# commercial region and strictly cheaper per GiB than the x86 equivalents.
_node_ladder = [
    {gb = 1, cls = "db.t4g.micro"}
    {gb = 2, cls = "db.t4g.small"}
    {gb = 4, cls = "db.t4g.medium"}
    {gb = 8, cls = "db.t4g.large"}
    {gb = 16, cls = "db.m7g.xlarge"}
    {gb = 32, cls = "db.m7g.2xlarge"}
    {gb = 64, cls = "db.m7g.4xlarge"}
    {gb = 128, cls = "db.m7g.8xlarge"}
]

class_for = lambda gb: float -> str {
    _fits = [_n.cls for _n in _node_ladder if _n.gb >= gb]
    _fits[0] if _fits else _node_ladder[-1].cls
}

# ParameterGroup families track the Postgres major only (postgres16).
family_for = lambda engine_version: str -> str {
    "postgres" + engine_version.split(".")[0]
}

_next_day = {"mon" = "tue", "tue" = "wed", "wed" = "thu", "thu" = "fri", "fri" = "sat", "sat" = "sun", "sun" = "mon"}

_pad = lambda h: int -> str {
    "0${h}" if h < 10 else "${h}"
}

# {day = "sun", hour = 5} -> "sun:05:00-sun:07:00" (AWS ddd:hh24:mi-ddd:hh24:mi).
window_for = lambda mw: any -> str {
    _h = mw.hour
    _end = (_h + 2) % 24
    _end_day = _next_day[mw.day] if _end < _h else mw.day
    "${mw.day}:${_pad(_h)}:00-${_end_day}:${_pad(_end)}:00"
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region

    _version = _spec?.engineVersion or "16"
    _db = _spec?.database or "app"
    _user = _spec?.username or "app"
    _ha = _spec?.highAvailability or False
    _public = _spec?.publicAccess or False

    # 0 disables backups on purpose, so `or 7` would silently re-enable them.
    _retention = _spec?.snapshotRetentionDays
    if _retention == Undefined:
        _retention = 7

    # Workload identity: presence enables IAM database authentication unless
    # explicitly switched off. The instance-level flag is all RDS can express
    # declaratively — the in-database `GRANT rds_iam` and the workload's
    # rds-db:connect IAM policy live outside this XR, so principal is ignored.
    # A nested reassignment does not escape its if-block in a KCL lambda, so
    # this is one expression: present, and not explicitly disabled.
    _wi = _spec?.workloadIdentity
    _iam = _wi not in [None, Undefined] and _wi?.enabled != False

    _params = _spec?.parameters or {}
    _pg_name = "${_name}-params"

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _items: [any] = [db.Instance {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.engine = "postgres"
        # A major version is enough: with autoMinorVersionUpgrade (the RDS
        # default) it resolves to the latest published minor.
        spec.forProvider.engineVersion = _version
        spec.forProvider.port = 5432
        spec.forProvider.instanceClass = _spec?.instanceClass or class_for(_spec?.memoryGb or 2)
        spec.forProvider.allocatedStorage = _spec?.storageGb or 20
        # At-rest encryption is free and the sane default, so it is always on.
        spec.forProvider.storageEncrypted = True
        if _spec?.encryptionKmsKeyId:
            spec.forProvider.kmsKeyId = _spec.encryptionKmsKeyId
        spec.forProvider.dbName = _db
        spec.forProvider.username = _user
        # passwordSecretRef cuts both ways: with a user-supplied Secret the
        # provider READS the master password from it; with autoGeneratePassword
        # upjet WRITES the generated password to the referenced Secret instead.
        if _spec?.passwordSecret:
            spec.forProvider.passwordSecretRef = {name = _spec.passwordSecret.name, key = _spec.passwordSecret?.key or "password"}
        else:
            spec.forProvider.autoGeneratePassword = True
            spec.forProvider.passwordSecretRef = {name = "${_name}-postgres-auth", key = "password"}
        if _iam:
            spec.forProvider.iamDatabaseAuthenticationEnabled = True
        spec.forProvider.multiAz = _ha
        spec.forProvider.publiclyAccessible = _public
        spec.forProvider.backupRetentionPeriod = _retention
        # Without this RDS refuses deletion unless a finalSnapshotIdentifier is
        # given, wedging the XR in Deleting.
        spec.forProvider.skipFinalSnapshot = True
        if _spec?.maintenanceWindow:
            spec.forProvider.maintenanceWindow = window_for(_spec.maintenanceWindow)
        if _spec?.network?.subnetGroupName:
            spec.forProvider.dbSubnetGroupName = _spec.network.subnetGroupName
        if _spec?.network?.securityGroupIds:
            spec.forProvider.vpcSecurityGroupIds = _spec.network.securityGroupIds
        if _params:
            spec.forProvider.parameterGroupName = _pg_name
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    if _params:
        _items += [pg.ParameterGroup {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "parameters"
                # The AWS-side group name the Instance binds by (see header).
                "crossplane.io/external-name" = _pg_name
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.family = family_for(_version)
            spec.forProvider.description = "PostgresInstance ${_name} parameters"
            spec.forProvider.parameter = [{name = _k, value = _params[_k]} for _k in sorted(_params)]
            if _spec?.tags:
                spec.forProvider.tags = _spec.tags
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _db = _spec?.database or "app"
    _user = _spec?.username or "app"

    _host = (_at?.address) or ""
    _port = int(_at?.port or 5432)
    _region = (_at?.region) or _spec.region
    _id = _at?.id or _name

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "PostgresInstance"
        metadata.name = _name
        status = {
            provider = "aws"
            ready = _host != ""
            port = _port
            database = _db
            username = _user
            "cloud-url" = "https://${_region}.console.aws.amazon.com/rds/home?region=${_region}#database:id=${_id}"
            if _spec?.passwordSecret:
                authSecret = _spec.passwordSecret.name
                authSecretKey = _spec.passwordSecret?.key or "password"
            else:
                authSecret = "${_name}-postgres-auth"
                authSecretKey = "password"
            if _host != "":
                host = _host
                endpoint = "${_host}:${_port}"
                # Single instance — no separate read service.
                readEndpoint = "${_host}:${_port}"
                url = "postgresql://${_host}:${_port}/${_db}"
            if _at:
                if _at?.engineVersionActual:
                    version = _at.engineVersionActual
                elif _at?.engineVersion:
                    version = _at.engineVersion
                if _at?.arn:
                    arn = _at.arn
                if _at?.id:
                    id = _at.id
        }
    }
}
