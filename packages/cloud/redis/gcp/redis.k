# redis (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-redis schema package. Memorystore expresses sizing,
# replication, auth, encryption, persistence, config overrides and maintenance
# inline, so the portable RedisInstance maps onto a single Instance MR.
import gcp_redis.models.v1beta1.redis_gcpm_upbound_io_v1beta1_instance as backend

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

_gcp_day = {"mon" = "MONDAY", "tue" = "TUESDAY", "wed" = "WEDNESDAY", "thu" = "THURSDAY", "fri" = "FRIDAY", "sat" = "SATURDAY", "sun" = "SUNDAY"}

# "7.0" -> "REDIS_7_0" (Memorystore's enum spelling).
version_for = lambda engine_version: str -> str {
    "REDIS_" + engine_version.replace(".", "_")
}

# Memorystore keeps at most one RDB snapshot period, not a day count; pick the
# finest period the requested retention can actually observe.
_snapshot_period = lambda days: int -> str {
    "ONE_HOUR" if days == 0 else ("SIX_HOURS" if days == 1 else ("TWELVE_HOURS" if days <= 3 else "TWENTY_FOUR_HOURS"))
}

render = lambda oxr {
    _spec = oxr.spec

    _ha = _spec?.highAvailability or False
    _replicas = _spec?.replicas or 0

    _auth = _spec?.authEnabled
    if _auth == Undefined:
        _auth = True

    _tls = _spec?.transitEncryption
    if _tls == Undefined:
        _tls = True

    _persist = _spec?.persistence
    if _persist == Undefined:
        _persist = True

    # Read replicas are a STANDARD_HA-only feature; a replicas>0 request implies
    # the HA tier rather than silently dropping the replicas.
    _tier = "STANDARD_HA" if (_ha or _replicas > 0) else "BASIC"

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    [backend.Instance {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        # Memorystore returns the AUTH string only through connection details;
        # publish it so status.authSecret actually resolves to something.
        if _auth:
            spec.writeConnectionSecretToRef = {name = "${oxr.metadata.name}-redis-auth"}
        spec.forProvider.region = _spec.region
        spec.forProvider.tier = _tier
        spec.forProvider.memorySizeGb = _spec?.memoryGb or 1
        spec.forProvider.redisVersion = version_for(_spec?.engineVersion or "7.0")
        spec.forProvider.authEnabled = _auth
        spec.forProvider.transitEncryptionMode = "SERVER_AUTHENTICATION" if _tls else "DISABLED"
        if _replicas > 0:
            spec.forProvider.replicaCount = _replicas
            spec.forProvider.readReplicasMode = "READ_REPLICAS_ENABLED"
        else:
            spec.forProvider.readReplicasMode = "READ_REPLICAS_DISABLED"
        # Memorystore always encrypts at rest; only the CMEK is configurable.
        if _spec?.encryptionKmsKeyId:
            spec.forProvider.customerManagedKey = _spec.encryptionKmsKeyId
        spec.forProvider.persistenceConfig = {
            persistenceMode = "RDB" if _persist else "DISABLED"
            if _persist:
                rdbSnapshotPeriod = _snapshot_period(_spec?.snapshotRetentionDays or 0)
        }
        if _spec?.parameters:
            spec.forProvider.redisConfigs = _spec.parameters
        if _spec?.tags:
            spec.forProvider.labels = _spec.tags
        if _spec?.network?.id:
            spec.forProvider.authorizedNetwork = _spec.network.id
        if _spec?.network?.reservedIpRange:
            spec.forProvider.reservedIpRange = _spec.network.reservedIpRange
        if _spec?.maintenanceWindow:
            spec.forProvider.maintenancePolicy = {
                weeklyMaintenanceWindow = [{
                    day = _gcp_day[_spec.maintenanceWindow.day]
                    startTime = {hours = _spec.maintenanceWindow.hour, minutes = 0, seconds = 0, nanos = 0}
                }]
            }
    }]
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _tls = _spec?.transitEncryption
    if _tls == Undefined:
        _tls = True

    _auth = _spec?.authEnabled
    if _auth == Undefined:
        _auth = True

    _host = _at?.host or ""
    _port = int(_at?.port or 6379)
    _reader = _at?.readEndpoint or _host
    _reader_port = int(_at?.readEndpointPort or _port)
    _scheme = "rediss" if _tls else "redis"
    _region = (_at?.region) or _spec.region

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "RedisInstance"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = _host != ""
            port = _port
            "cloud-url" = "https://console.cloud.google.com/memorystore/redis/locations/${_region}/instances/${_name}/details"
            # Memorystore surfaces the AUTH string through the provider's
            # connection secret, written next to the Instance MR.
            if _auth:
                authSecret = "${_name}-redis-auth"
                # Upjet publishes sensitive attributes as `attribute.<terraform name>`.
                authSecretKey = "attribute.auth_string"
            if _host != "":
                host = _host
                endpoint = "${_host}:${_port}"
                readEndpoint = "${_reader}:${_reader_port}"
                url = "${_scheme}://${_host}:${_port}"
            if _at:
                if _at?.redisVersion:
                    version = _at.redisVersion
                if _at?.id:
                    id = _at.id
        }
    }
}
