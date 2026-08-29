# appstack — Crossplane Composition logic (function-kcl module).
#
# A composite of composites: instead of managed resources this module emits five
# CHILD COMPOSITE RESOURCES (Network, two ServerlessApps, PostgresInstance,
# RedisInstance, all cloud.example.org/v1alpha1). Each capability keeps owning
# its own cloud mapping, so nothing here knows what a VPC, a Cloud Run Service
# or an RDS Instance looks like — it only decides how the five are sized, which
# backend they resolve to, and how they are wired to one another.
#
# There are no schema imports for the same reason: child XRs have no generated
# KCL types, they are dicts their own XRDs validate.

# Every child lives in the portable capability group.
_child_api = "cloud.example.org/v1alpha1"

# Explicit "was this field set?" test. Truthiness cannot answer it: 0 instances
# and public=false are legitimate values that must still be forwarded. Both
# spellings of absent are checked because `?.` yields Undefined for a missing
# key but None when the parent dict itself is empty, which is exactly the case
# for an omitted optional block such as spec.network.
_set = lambda value -> bool {
    not (value == Undefined or value == None)
}

# AWS: RDS and ElastiCache are placed by subnet group plus security groups.
# Emit nothing until BOTH halves are observed — a block naming a subnet group
# with no security group would be applied as-is and then have to be corrected,
# which is a strictly worse state than not having attached yet. Crossplane
# re-renders when the Network publishes the rest.
_aws_placement = lambda subnet_group, security_groups: [str] -> any {
    {
        subnetGroupName = subnet_group
        securityGroupIds = security_groups
    } if (subnet_group and len(security_groups) > 0) else Undefined
}

# GCP: Cloud SQL private IP and Memorystore attach to the VPC itself. The self
# link (projects/<p>/global/networks/<n>) is the spelling both expect; fall back
# to the id when that is all the Network has published so far. reserved_range is
# the private-service-access CIDR, which only Memorystore takes.
_gcp_placement = lambda network_id, reserved_range -> any {
    {
        id = network_id
        if reserved_range:
            reservedIpRange = reserved_range
    } if network_id else Undefined
}

# A child XR's observed state as function-kcl receives it. Unlike a managed
# resource there is no `atProvider` layer: a composed XR's status IS the status
# its XRD declares.
_observed = lambda ocds, name: str -> any {
    (ocds[name]?.Resource?.status) if (name in ocds) else Undefined
}

# Coordinates of the composed data services, as environment variables for both
# apps. Each entry appears only once the corresponding child has actually
# published the value, so an app never starts with DATABASE_HOST="".
#
# Every value is non-secret: hostnames, ports, names, credential-free URIs, plus
# the NAMES of the Secrets holding the database password and the Redis AUTH
# string. ServerlessApp deliberately manages no secret material, so the workload
# mounts those Secrets itself using these two name/key pairs. The key is read
# from the child rather than hard-coded because each backend spells it
# differently (Upjet's `attribute.*` vs. a plain `password`).
_wiring_env = lambda db, cache -> {str:str} {
    {
        if db?.host:
            DATABASE_HOST = db.host
        if db?.port:
            DATABASE_PORT = str(db.port)
        if db?.database:
            DATABASE_NAME = db.database
        if db?.username:
            DATABASE_USER = db.username
        if db?.url:
            DATABASE_URL = db.url
        if db?.authSecret:
            DATABASE_PASSWORD_SECRET = db.authSecret
        if db?.authSecretKey:
            DATABASE_PASSWORD_SECRET_KEY = db.authSecretKey
        if cache?.host:
            REDIS_HOST = cache.host
        if cache?.port:
            REDIS_PORT = str(cache.port)
        if cache?.url:
            REDIS_URL = cache.url
        if cache?.authSecret:
            REDIS_AUTH_SECRET = cache.authSecret
        if cache?.authSecretKey:
            REDIS_AUTH_SECRET_KEY = cache.authSecretKey
    }
}

# One ServerlessApp child. `api` and `worker` differ in exactly one field —
# opts.public — and in their name; everything else, including the injected
# coordinates, is identical by construction.
#
# The per-child differences travel in ONE `opts` dict rather than as separate
# parameters to keep this signature short: `kcl fmt` (0.12.8) wraps a long
# lambda parameter list across lines, and the older KCL inside function-kcl
# v0.12.2 cannot parse that wrapped form — the Composition would fail to
# render on a cluster while the local CLI stayed green.
# opts: {name: str, resName: str, public: bool, envs: {str:str}}
_app_child = lambda base: {str:any}, app: {str:any}, opts: {str:any} -> any {
    {
        apiVersion = _child_api
        kind = "ServerlessApp"
        metadata = {
            name = opts.name
            annotations = {"krm.kcl.dev/composition-resource-name" = opts.resName}
        }
        spec = base | {
            image = app.image
            port = app?.port or 8080
            public = opts.public
            # Numeric knobs are forwarded only when set, so the ServerlessApp
            # XRD's own defaults stay in charge. Presence, not truthiness:
            # minInstances = 0 is a meaningful value.
            if _set(app?.cpu):
                cpu = app.cpu
            if _set(app?.memoryMb):
                memoryMb = app.memoryMb
            if _set(app?.minInstances):
                minInstances = app.minInstances
            if _set(app?.maxInstances):
                maxInstances = app.maxInstances
            if _set(app?.timeoutSeconds):
                timeoutSeconds = app.timeoutSeconds
            if app?.serviceAccount:
                serviceAccount = app.serviceAccount
            if opts.envs:
                env = opts.envs
        }
    }
}

# render(oxr, ocds) — the five children.
#
# ocds is a parameter, not read from option("params") inside, because the
# cross-child wiring below is derived from OBSERVED child status: the Network's
# placement fields and the database/cache coordinates only exist after those
# children have been created. It defaults to {} so a bare `kcl run main.k`
# renders the unwired first pass, which is exactly what Crossplane asks for on
# the first reconcile.
render = lambda oxr, ocds = {} -> [any] {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _provider = _spec.provider

    _net_spec = _spec?.network or {}
    _db_spec = _spec?.database or {}
    _cache_spec = _spec?.cache or {}

    # The fragment every child spec starts from. Backend selection, region, tags
    # and deletion policy are stack-wide by design: five children that could
    # drift onto different clouds or regions would not be a stack.
    _base = {
        region = _spec.region
        deletionPolicy = _spec?.deletionPolicy or "Delete"
        crossplane.compositionSelector.matchLabels.provider = _provider
        if _spec?.tags:
            tags = _spec.tags
    }

    # natGateway defaults on. Resolved here rather than inline because the XRD
    # default only applies to the AppStack's own field; the Network child must
    # be told explicitly, and `or True` would turn an explicit false into true.
    _nat = _net_spec?.natGateway if _set(_net_spec?.natGateway) else True

    # ---- observed children, for the wiring ----------------------------------
    _net_status = _observed(ocds, "network")
    _db_status = _observed(ocds, "database")
    _cache_status = _observed(ocds, "cache")

    _sgs = _net_status?.securityGroupIds or []

    # selfLink is empty on AWS and id is empty on GCP until the network exists,
    # so this is the one expression that covers both.
    _vpc = _net_status?.selfLink or _net_status?.id

    _db_net = _aws_placement(_net_status?.dbSubnetGroupName, _sgs) if _provider == "aws" else _gcp_placement(_vpc, Undefined)
    _cache_net = _aws_placement(_net_status?.cacheSubnetGroupName, _sgs) if _provider == "aws" else _gcp_placement(_vpc, _net_status?.serviceRange)

    # Injected coordinates are merged ON TOP of the user's env, not under it:
    # they are the live truth about the composed database and cache, so a stale
    # DATABASE_HOST left in the spec must not win over the instance that is
    # actually running. Users who need a different host should not be using the
    # composed one.
    _env = _wiring_env(_db_status, _cache_status)
    _api_env = (_spec.api?.env or {}) | _env
    _worker_env = (_spec.worker?.env or {}) | _env

    # Composed resources inherit the XR's namespace, so metadata.namespace is
    # deliberately never set here.
    [
        {
            apiVersion = _child_api
            kind = "Network"
            metadata = {
                name = "${_name}-net"
                annotations = {"krm.kcl.dev/composition-resource-name" = "network"}
            }
            spec = _base | {
                cidr = _net_spec?.cidr or "10.0.0.0/16"
                natGateway = _nat
                # AWS-only, and required there: RDS and ElastiCache subnet
                # groups must span more than one zone.
                if _net_spec?.availabilityZones:
                    availabilityZones = _net_spec.availabilityZones
                # GCP-only: reserving this range is what lets Cloud SQL and
                # Memorystore get private addresses inside the VPC.
                if _net_spec?.serviceRange:
                    serviceRange = _net_spec.serviceRange
            }
        }
        _app_child(_base, _spec.api, {name = "${_name}-api", resName = "api", public = True, envs = _api_env})
        _app_child(_base, _spec.worker, {name = "${_name}-worker", resName = "worker", public = False, envs = _worker_env})
        {
            apiVersion = _child_api
            kind = "PostgresInstance"
            metadata = {
                name = "${_name}-db"
                annotations = {"krm.kcl.dev/composition-resource-name" = "database"}
            }
            spec = _base | {
                database = _db_spec?.name or "app"
                username = _db_spec?.username or "app"
                if _db_spec?.engineVersion:
                    engineVersion = _db_spec.engineVersion
                if _set(_db_spec?.memoryGb):
                    memoryGb = _db_spec.memoryGb
                if _set(_db_spec?.storageGb):
                    storageGb = _db_spec.storageGb
                if _set(_db_spec?.highAvailability):
                    highAvailability = _db_spec.highAvailability
                if _set(_db_spec?.snapshotRetentionDays):
                    snapshotRetentionDays = _db_spec.snapshotRetentionDays
                if _db_spec?.passwordSecret:
                    passwordSecret = _db_spec.passwordSecret
                if _db_net:
                    network = _db_net
            }
        }
        {
            apiVersion = _child_api
            kind = "RedisInstance"
            metadata = {
                name = "${_name}-cache"
                annotations = {"krm.kcl.dev/composition-resource-name" = "cache"}
            }
            spec = _base | {
                if _cache_spec?.engineVersion:
                    engineVersion = _cache_spec.engineVersion
                if _set(_cache_spec?.memoryGb):
                    memoryGb = _cache_spec.memoryGb
                if _set(_cache_spec?.replicas):
                    replicas = _cache_spec.replicas
                if _set(_cache_spec?.highAvailability):
                    highAvailability = _cache_spec.highAvailability
                if _set(_cache_spec?.authEnabled):
                    authEnabled = _cache_spec.authEnabled
                if _cache_net:
                    network = _cache_net
            }
        }
    ]
}

# Build the desired composite carrying the children's observed status back to
# the AppStack. Endpoints and URLs are copied, never recomputed: each capability
# already decided what its connection string looks like (rediss:// vs redis://,
# which host is the writer), and duplicating that logic here would let the two
# answers disagree.
status = lambda oxr, ocds -> any {
    _name = oxr.metadata.name

    _net = _observed(ocds, "network")
    _api = _observed(ocds, "api")
    _worker = _observed(ocds, "worker")
    _db = _observed(ocds, "database")
    _cache = _observed(ocds, "cache")

    _net_ready = _net?.ready or False
    _api_ready = _api?.ready or False
    _worker_ready = _worker?.ready or False
    _db_ready = _db?.ready or False
    _cache_ready = _cache?.ready or False

    {
        apiVersion = oxr?.apiVersion or "platform.example.org/v1alpha1"
        kind = oxr?.kind or "AppStack"
        metadata.name = _name
        status = {
            provider = oxr.spec.provider
            # The stack is only usable end to end: the apps need the data
            # services, the data services need the network.
            ready = _net_ready and _api_ready and _worker_ready and _db_ready and _cache_ready
            components = {
                network = _net_ready
                api = _api_ready
                worker = _worker_ready
                database = _db_ready
                cache = _cache_ready
            }
            if _api?.url:
                apiUrl = _api.url
            if _worker?.url:
                workerUrl = _worker.url
            if _db?.endpoint:
                databaseEndpoint = _db.endpoint
            if _db?.url:
                databaseUrl = _db.url
            if _cache?.endpoint:
                cacheEndpoint = _cache.endpoint
            if _cache?.url:
                cacheUrl = _cache.url
            if _net?.id:
                networkId = _net.id
        }
    }
}
