# postgres (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-sql schema package. Cloud SQL splits the portable
# PostgresInstance across MRs: the DatabaseInstance carries sizing, HA,
# backups, networking and flags; the initial database is a companion Database
# MR; the owner User is a third MR that only exists when a passwordSecret is
# given, because Cloud SQL cannot generate a password server-side; and workload
# identity adds an IAM-typed User admitted by GKE Workload Identity.
import gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_database_instance as sql
import gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_database as sqldb
import gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_user as sqluser

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Cloud SQL numbers maintenance days 1-7 starting on Monday.
_gcp_day = {"mon" = 1, "tue" = 2, "wed" = 3, "thu" = 4, "fri" = 5, "sat" = 6, "sun" = 7}

# "16" -> "POSTGRES_16" (Cloud SQL's enum spelling).
version_for = lambda engine_version: str -> str {
    "POSTGRES_" + engine_version.replace(".", "_")
}

# Cloud SQL admits service accounts as database principals under their email
# with the ".gserviceaccount.com" suffix stripped (a Cloud SQL length rule).
_sa_suffix = ".gserviceaccount.com"

iam_user_for = lambda principal: str -> {str:str} {
    {
        name = principal[:len(principal) - len(_sa_suffix):] if principal.endswith(_sa_suffix) else principal
        $type = "CLOUD_IAM_SERVICE_ACCOUNT" if principal.endswith(_sa_suffix) else "CLOUD_IAM_USER"
    }
}

# `**`/`|` on dicts sourced from option("params") is a *union*: overlapping
# keys are a hard error, not an override. Build the merge explicitly so a user
# parameter always wins over a flag of the same name.
override = lambda base: {str:str}, over: {str:str} -> {str:str} {
    {_k: (over[_k] if _k in over else base[_k]) for _k in base} | {_k: over[_k] for _k in over if _k not in base}
}

# Smallest db-custom tier that holds `memoryGb`, ascending by memory (GiB).
# N1-standard shapes only (3.75 GiB per vCPU) — they stay inside Cloud SQL's
# per-vCPU memory bounds at every rung, so every tier here is always valid.
_tier_ladder = [
    {gb = 3.75, tier = "db-custom-1-3840"}
    {gb = 7.5, tier = "db-custom-2-7680"}
    {gb = 15, tier = "db-custom-4-15360"}
    {gb = 30, tier = "db-custom-8-30720"}
    {gb = 60, tier = "db-custom-16-61440"}
]

tier_for = lambda gb: float -> str {
    _fits = [_t.tier for _t in _tier_ladder if _t.gb >= gb]
    _fits[0] if _fits else _tier_ladder[-1].tier
}

render = lambda oxr {
    _spec = oxr.spec

    _database = _spec?.database or "app"
    _username = _spec?.username or "app"
    _ha = _spec?.highAvailability or False
    _public = _spec?.publicAccess or False
    _params = _spec?.parameters or {}

    # 0 disables backups, so `or` would clobber it; default only when unset.
    _retention = _spec?.snapshotRetentionDays
    if _retention == Undefined:
        _retention = 7

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Workload identity: presence enables IAM database authentication unless
    # explicitly switched off; the flag merges under user parameters so an
    # explicit cloudsql.iam_authentication override always wins.
    # A nested reassignment does not escape its if-block in a KCL lambda, so
    # this is one expression: present, and not explicitly disabled.
    _wi = _spec?.workloadIdentity
    _iam = _wi not in [None, Undefined] and _wi?.enabled != False

    _flags = override({"cloudsql.iam_authentication" = "on"} if _iam else {}, _params)

    _items: [any] = [
        sql.DatabaseInstance {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _spec.region
            spec.forProvider.databaseVersion = version_for(_spec?.engineVersion or "16")
            # deletionProtection is the Terraform-level guard, separate from the
            # Crossplane deletionPolicy; leaving it on makes even an intended
            # Delete hang, so the XR's deletionPolicy is the only lifecycle knob.
            spec.forProvider.deletionProtection = False
            if _spec?.encryptionKmsKeyId:
                spec.forProvider.encryptionKeyName = _spec.encryptionKmsKeyId
            spec.forProvider.settings = {
                tier = _spec?.instanceClass or tier_for(_spec?.memoryGb or 2)
                diskSize = _spec?.storageGb or 20
                availabilityType = "REGIONAL" if _ha else "ZONAL"
                backupConfiguration = {
                    enabled = _retention > 0
                    if _retention > 0:
                        backupRetentionSettings = {retainedBackups = _retention, retentionUnit = "COUNT"}
                }
                # Cloud SQL requires at least one interface, so without a private
                # network the public address stays on regardless of publicAccess.
                ipConfiguration = {
                    ipv4Enabled = _public or not _spec?.network?.id
                    if _spec?.network?.id:
                        privateNetwork = _spec.network.id
                }
                if _flags:
                    databaseFlags = [{name = _k, value = _flags[_k]} for _k in sorted(_flags)]
                if _spec?.maintenanceWindow:
                    maintenanceWindow = {
                        day = _gcp_day[_spec.maintenanceWindow.day]
                        hour = _spec.maintenanceWindow.hour
                    }
                if _spec?.tags:
                    userLabels = _spec.tags
            }
        }
        sqldb.Database {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "database"
                # The external name IS the database name on the instance.
                "crossplane.io/external-name" = _database
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.instanceSelector = {matchControllerRef = True}
        }
    ]

    # Cloud SQL cannot generate a password server-side (see the XRD): without
    # a passwordSecret no User is created and credentials are managed out of
    # band (e.g. IAM database authentication).
    if _spec?.passwordSecret:
        _items += [sqluser.User {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "user"
                # The external name IS the SQL user name on the instance.
                "crossplane.io/external-name" = _username
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.instanceSelector = {matchControllerRef = True}
            spec.forProvider.passwordSecretRef = {
                name = _spec.passwordSecret.name
                key = _spec.passwordSecret?.key or "password"
            }
        }]

    # The workload's own identity, admitted as an IAM database user. Grants on
    # the database objects themselves stay with the owner (SQL, out of band).
    if _iam and _wi?.principal:
        _iam_user = iam_user_for(_wi.principal)
        _items += [sqluser.User {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "iam-user"
                # The external name IS the SQL user name on the instance.
                "crossplane.io/external-name" = _iam_user.name
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.instanceSelector = {matchControllerRef = True}
            spec.forProvider.$type = _iam_user.$type
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _database = _spec?.database or "app"
    _username = _spec?.username or "app"

    # Prefer the private address; fall back to the public one, then to
    # whatever interface Cloud SQL reported first.
    _host = (_at?.privateIpAddress) or (_at?.publicIpAddress) or (_at?.firstIpAddress) or ""
    _port = 5432

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "PostgresInstance"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = _host != ""
            port = _port
            database = _database
            username = _username
            "cloud-url" = "https://console.cloud.google.com/sql/instances/${_at?.id or _name}/overview"
            # The password lives in the caller-provided Secret; echo it so
            # consumers read credentials from one well-known status field.
            if _spec?.passwordSecret:
                authSecret = _spec.passwordSecret.name
                authSecretKey = _spec.passwordSecret?.key or "password"
            if _host != "":
                host = _host
                endpoint = "${_host}:${_port}"
                readEndpoint = "${_host}:${_port}"
                url = "postgresql://${_host}:${_port}/${_database}"
            if _at:
                if _at?.databaseVersion:
                    version = _at.databaseVersion
                if _at?.id:
                    id = _at.id
        }
    }
}
