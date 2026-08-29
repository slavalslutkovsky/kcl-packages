# redis (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-elasticache schema package. The portable RedisInstance
# maps onto a cluster-mode-disabled ElastiCache ReplicationGroup; Redis config
# overrides need a companion ParameterGroup MR, which ElastiCache binds by name
# (there is no bucketSelector-style controller ref for parameter groups).
import aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_replication_group as rg
import aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_parameter_group as pg

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Smallest ElastiCache node type that holds `memoryGb`, ascending by usable
# memory (GiB). Graviton generations only — they are the current-gen default in
# every commercial region and strictly cheaper per GiB than the x86 equivalents.
_node_ladder = [
    {gb = 0.5, node = "cache.t4g.micro"}
    {gb = 1.37, node = "cache.t4g.small"}
    {gb = 3.09, node = "cache.t4g.medium"}
    {gb = 6.38, node = "cache.m7g.large"}
    {gb = 12.93, node = "cache.m7g.xlarge"}
    {gb = 26.04, node = "cache.m7g.2xlarge"}
    {gb = 52.82, node = "cache.m7g.4xlarge"}
    {gb = 103.68, node = "cache.m7g.8xlarge"}
]

node_for = lambda gb: float -> str {
    _fits = [_n.node for _n in _node_ladder if _n.gb >= gb]
    _fits[0] if _fits else _node_ladder[-1].node
}

# ParameterGroup families are versioned differently before and after Redis 7.
family_for = lambda engine_version: str -> str {
    _major = engine_version.split(".")[0]
    "redis${_major}.x" if _major == "6" else "redis${_major}"
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

    _version = _spec?.engineVersion or "7.0"
    _replicas = _spec?.replicas or 0
    _ha = _spec?.highAvailability or False

    _auth = _spec?.authEnabled
    if _auth == Undefined:
        _auth = True

    _tls = _spec?.transitEncryption
    if _tls == Undefined:
        _tls = True

    _at_rest = _spec?.atRestEncryption
    if _at_rest == Undefined:
        _at_rest = True

    _persist = _spec?.persistence
    if _persist == Undefined:
        _persist = True

    # Failover needs a second node; honour highAvailability even at replicas=0.
    _nodes = _replicas + 1
    if _ha and _nodes < 2:
        _nodes = 2

    # AWS keeps backups by day count. Persistence with no explicit retention
    # still needs one day, otherwise ElastiCache disables snapshots entirely.
    _retention = _spec?.snapshotRetentionDays or 0
    if _persist and _retention < 1:
        _retention = 1

    _params = _spec?.parameters or {}
    _pg_name = "${_name}-params"

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _items: [any] = [rg.ReplicationGroup {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.description = "RedisInstance ${_name} (managed by Crossplane)"
        spec.forProvider.engine = "redis"
        spec.forProvider.engineVersion = _version
        spec.forProvider.nodeType = _spec?.nodeType or node_for(_spec?.memoryGb or 1)
        spec.forProvider.numCacheClusters = _nodes
        spec.forProvider.automaticFailoverEnabled = _ha
        spec.forProvider.multiAzEnabled = _ha
        spec.forProvider.port = 6379
        spec.forProvider.transitEncryptionEnabled = _tls
        # Upjet models this as a string ("true"/"false"), not a bool.
        spec.forProvider.atRestEncryptionEnabled = "true" if (_at_rest or _spec?.encryptionKmsKeyId) else "false"
        spec.forProvider.snapshotRetentionLimit = _retention
        if _spec?.encryptionKmsKeyId:
            spec.forProvider.kmsKeyId = _spec.encryptionKmsKeyId
        # AUTH requires an encrypted transport; the provider generates the token
        # and writes it to the referenced Secret in this resource's namespace.
        if _auth and _tls:
            spec.forProvider.autoGenerateAuthToken = True
            spec.forProvider.authTokenSecretRef = {name = "${_name}-redis-auth", key = "password"}
        if _spec?.maintenanceWindow:
            spec.forProvider.maintenanceWindow = window_for(_spec.maintenanceWindow)
        if _spec?.network?.subnetGroupName:
            spec.forProvider.subnetGroupName = _spec.network.subnetGroupName
        if _spec?.network?.securityGroupIds:
            spec.forProvider.securityGroupIds = _spec.network.securityGroupIds
        if _params:
            spec.forProvider.parameterGroupName = _pg_name
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    if _params:
        _items += [pg.ParameterGroup {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "parameters"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.name = _pg_name
            spec.forProvider.family = family_for(_version)
            spec.forProvider.description = "RedisInstance ${_name} parameters"
            spec.forProvider.parameter = [{name = _k, value = _params[_k]} for _k in _params]
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

    _tls = _spec?.transitEncryption
    if _tls == Undefined:
        _tls = True

    _auth = _spec?.authEnabled
    if _auth == Undefined:
        _auth = True

    # Cluster mode disabled exposes primaryEndpointAddress; enabled exposes a
    # single configurationEndpointAddress instead.
    _host = (_at?.primaryEndpointAddress) or (_at?.configurationEndpointAddress) or ""
    _port = int(_at?.port or 6379)
    _reader = (_at?.readerEndpointAddress) or _host
    _scheme = "rediss" if _tls else "redis"
    _region = (_at?.region) or _spec.region
    _id = _at?.id or _name

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "RedisInstance"
        metadata.name = _name
        status = {
            provider = "aws"
            ready = _host != ""
            port = _port
            "cloud-url" = "https://${_region}.console.aws.amazon.com/elasticache/home?region=${_region}#/redis/${_id}"
            if _auth and _tls:
                authSecret = "${_name}-redis-auth"
                authSecretKey = "password"
            if _host != "":
                host = _host
                endpoint = "${_host}:${_port}"
                readEndpoint = "${_reader}:${_port}"
                url = "${_scheme}://${_host}:${_port}"
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
