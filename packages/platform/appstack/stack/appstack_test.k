import .appstack

_anno = "krm.kcl.dev/composition-resource-name"

# ---- helpers ----------------------------------------------------------------
# NOTE: KCL normalizes the leading underscore, so a helper here shadows ANY
# lambda parameter of the same normalized name over in appstack.k — `_ocds`
# would shadow render()'s `ocds`, `_res_name` would shadow _app_child()'s
# `res_name`, and the failure surfaces inside appstack.k as
# "argument of type 'function' is not iterable". Hence `_observed_children`,
# `_anno` and friends.
_build = lambda _spec {
    {apiVersion = "platform.example.org/v1alpha1", kind = "AppStack", metadata.name = "demo", spec = _spec}
}

# The smallest spec the XRD admits: provider, region and the two images.
_min = lambda _provider: str {
    {
        provider = _provider
        region = "us-east-1" if _provider == "aws" else "us-central1"
        api = {image = "reg/api:v1"}
        worker = {image = "reg/worker:v1"}
    }
}

# Pick a child out of a render() by its composition-resource-name.
_child = lambda _items, _res: str {
    [i for i in _items if i.metadata.annotations[_anno] == _res][0]
}

_selector = lambda _c {
    _c.spec.crossplane.compositionSelector.matchLabels.provider
}

# ---- synthetic observed children -------------------------------------------
# Shape as function-kcl hands it over: ocds[<resource-name>].Resource.status is
# the CHILD XR's status, i.e. what its own XRD declares. There is no atProvider
# layer here — that belongs to managed resources, one level further down.
_db_observed = {
    ready = True
    provider = "gcp"
    host = "10.0.0.5"
    port = 5432
    endpoint = "10.0.0.5:5432"
    url = "postgresql://10.0.0.5:5432/app"
    database = "app"
    username = "app"
    authSecret = "demo-db-password"
    authSecretKey = "password"
}

_cache_observed = {
    ready = True
    provider = "gcp"
    host = "10.0.0.9"
    port = 6379
    endpoint = "10.0.0.9:6379"
    url = "rediss://10.0.0.9:6379"
    authSecret = "demo-cache-redis-auth"
    authSecretKey = "attribute.auth_string"
}

# GCP publishes a self link and (when asked for) the private-service-access
# range; it has no subnet groups and no security groups.
_gcp_net_observed = {
    ready = True
    provider = "gcp"
    id = "demo-net"
    name = "demo-net"
    selfLink = "projects/p/global/networks/demo-net"
    region = "us-central1"
    cidr = "10.0.0.0/16"
    serviceRange = "10.9.0.0/20"
    natEnabled = True
}

# AWS publishes subnet groups and a workload security group; selfLink is empty.
_aws_net_observed = {
    ready = True
    provider = "aws"
    id = "vpc-0abc"
    name = "demo-net"
    region = "us-east-1"
    cidr = "10.0.0.0/16"
    privateSubnetIds = ["subnet-1", "subnet-2"]
    publicSubnetIds = ["subnet-3", "subnet-4"]
    securityGroupIds = ["sg-0abc"]
    dbSubnetGroupName = "demo-net-db"
    cacheSubnetGroupName = "demo-net-cache"
    natEnabled = True
}

_wrap = lambda _st {
    {
        Resource = {status = _st}
    }
}

_observed_children = lambda _net {
    {
        network = _wrap(_net)
        api = _wrap({ready = True, url = "https://demo-api.example.run"})
        worker = _wrap({ready = True, url = "https://demo-worker.example.run"})
        database = _wrap(_db_observed)
        cache = _wrap(_cache_observed)
    }
}

# Every key the wiring injects once both data services are observed.
_all_env_keys = sorted([
    "DATABASE_HOST"
    "DATABASE_PORT"
    "DATABASE_NAME"
    "DATABASE_USER"
    "DATABASE_URL"
    "DATABASE_PASSWORD_SECRET"
    "DATABASE_PASSWORD_SECRET_KEY"
    "REDIS_HOST"
    "REDIS_PORT"
    "REDIS_URL"
    "REDIS_AUTH_SECRET"
    "REDIS_AUTH_SECRET_KEY"
])

# ---- render: shape ----------------------------------------------------------

# Five children, in a fixed order, each with a stable composition-resource-name
# so Crossplane keeps matching the same composed resource across reconciles.
test_render_children = lambda {
    items = appstack.render(_build(_min("gcp")))
    assert len(items) == 5, "an AppStack must compose exactly five child XRs"
    assert [_c.metadata.annotations[_anno] for _c in items] == ["network", "api", "worker", "database", "cache"], "wrong composition-resource-names"
    assert [_c.kind for _c in items] == ["Network", "ServerlessApp", "ServerlessApp", "PostgresInstance", "RedisInstance"], "wrong child kinds"
    assert [_c.metadata.name for _c in items] == ["demo-net", "demo-api", "demo-worker", "demo-db", "demo-cache"], "wrong child names"
    assert all _c in items {_c.apiVersion == "cloud.example.org/v1alpha1"}, "children must be portable capability XRs"

    # Composed resources land in the XR's namespace; setting one here would
    # fight Crossplane for it.
    assert all _c in items {_c.metadata?.namespace == Undefined}, "children must not pin a namespace"
}

# The backend flag is what makes all five resolve to the same cloud.
test_provider_stamped_on_every_child = lambda {
    _gcp = appstack.render(_build(_min("gcp")))
    assert all _c in _gcp {_selector(_c) == "gcp"}, "every child must select the gcp backend"
    _aws = appstack.render(_build(_min("aws") | {
        network = {availabilityZones = ["us-east-1a", "us-east-1b"]}
    }))
    assert all _c in _aws {_selector(_c) == "aws"}, "every child must select the aws backend"
    assert len([_c for _c in _aws if _selector(_c) == "gcp"]) == 0, "no child may be left on another backend"
}

# public is the ONLY difference between the two apps.
test_api_public_worker_private = lambda {
    items = appstack.render(_build(_min("gcp")))
    _api = _child(items, "api")
    _worker = _child(items, "worker")
    assert _api.spec.public == True, "the api app must be publicly reachable"
    assert _worker.spec.public == False, "the worker app must not be publicly reachable"
    assert _api.spec.image == "reg/api:v1", "api image must be carried"
    assert _worker.spec.image == "reg/worker:v1", "worker image must be carried"
    assert _api.spec.port == 8080, "port must default to 8080"
    assert _worker.spec.port == 8080, "port must default to 8080"
}

# ---- render: stack-wide forwarding -----------------------------------------
test_common_fields_forwarded = lambda {
    items = appstack.render(_build(_min("gcp") | {
        deletionPolicy = "Orphan"
        tags = {team = "platform"}
    }))
    assert all _c in items {_c.spec.region == "us-central1"}, "every child must inherit the stack region"
    assert all _c in items {_c.spec.deletionPolicy == "Orphan"}, "every child must inherit the deletion policy"
    assert all _c in items {_c.spec.tags == {team = "platform"}}, "every child must inherit the stack tags"
}

# Delete is the default and must still be stated explicitly on each child: the
# AppStack XRD default does not propagate into a composed resource by itself.
test_deletion_policy_default = lambda {
    items = appstack.render(_build(_min("gcp")))
    assert all _c in items {_c.spec.deletionPolicy == "Delete"}, "every child must default to Delete"
}

# Absent tags must not become an empty map on the children.
test_tags_omitted = lambda {
    items = appstack.render(_build(_min("gcp")))
    assert all _c in items {_c.spec?.tags == Undefined}, "no tags key when the stack has none"
}

# ---- render: child sizing ---------------------------------------------------
test_network_sizing = lambda {
    _net = _child(appstack.render(_build(_min("gcp"))), "network")
    assert _net.spec.cidr == "10.0.0.0/16", "cidr must default to 10.0.0.0/16"
    assert _net.spec.natGateway == True, "natGateway must default on"
    assert _net.spec?.availabilityZones == Undefined, "no zones unless asked for"
    assert _net.spec?.serviceRange == Undefined, "no service range unless asked for"

    _tuned = _child(appstack.render(_build(_min("gcp") | {
        network = {
            cidr = "172.16.0.0/16"
            natGateway = False
            availabilityZones = ["us-east-1a", "us-east-1b"]
            serviceRange = "10.9.0.0/20"
        }
    })), "network")
    assert _tuned.spec.cidr == "172.16.0.0/16", "cidr must be carried"
    # An explicit false must survive: `or True` would have swallowed it.
    assert _tuned.spec.natGateway == False, "natGateway=false must be carried"
    assert _tuned.spec.availabilityZones == ["us-east-1a", "us-east-1b"], "zones must be carried for the aws backend"
    assert _tuned.spec.serviceRange == "10.9.0.0/20", "serviceRange must be carried for the gcp backend"
}

test_app_sizing = lambda {
    _api = _child(appstack.render(_build(_min("gcp") | {
        api = {
            image = "reg/api:v2"
            port = 3000
            cpu = 2
            memoryMb = 1024
            minInstances = 0
            maxInstances = 10
            timeoutSeconds = 120
            serviceAccount = "api@p.iam.gserviceaccount.com"
        }
    })), "api")
    assert _api.spec.port == 3000, "port must be carried"
    assert _api.spec.cpu == 2, "cpu must be carried"
    assert _api.spec.memoryMb == 1024, "memoryMb must be carried"
    # 0 is a legitimate value, so presence and not truthiness decides.
    assert _api.spec.minInstances == 0, "minInstances=0 must be forwarded"
    assert _api.spec.maxInstances == 10, "maxInstances must be carried"
    assert _api.spec.timeoutSeconds == 120, "timeoutSeconds must be carried"
    assert _api.spec.serviceAccount == "api@p.iam.gserviceaccount.com", "serviceAccount must be carried"

    # Unset knobs stay unset, so each ServerlessApp backend keeps its own default.
    _bare = _child(appstack.render(_build(_min("gcp"))), "api")
    assert _bare.spec?.cpu == Undefined, "no cpu unless asked for"
    assert _bare.spec?.maxInstances == Undefined, "no maxInstances unless asked for"
    assert _bare.spec?.serviceAccount == Undefined, "no serviceAccount unless asked for"
}

test_database_sizing = lambda {
    _db_child = _child(appstack.render(_build(_min("gcp"))), "database")
    assert _db_child.spec.database == "app", "database name must default to app"
    assert _db_child.spec.username == "app", "username must default to app"
    assert _db_child.spec?.memoryGb == Undefined, "no memoryGb unless asked for"

    _tuned = _child(appstack.render(_build(_min("gcp") | {
        database = {
            engineVersion = "16"
            memoryGb = 8
            storageGb = 100
            name = "orders"
            username = "orders"
            highAvailability = True
            snapshotRetentionDays = 0
            passwordSecret = {name = "db-password", key = "password"}
        }
    })), "database")
    assert _tuned.spec.engineVersion == "16", "engineVersion must be carried"
    assert _tuned.spec.memoryGb == 8, "memoryGb must be carried"
    assert _tuned.spec.storageGb == 100, "storageGb must be carried"
    assert _tuned.spec.database == "orders", "database.name -> child spec.database"
    assert _tuned.spec.username == "orders", "username must be carried"
    assert _tuned.spec.highAvailability == True, "highAvailability must be carried"
    # 0 means "no automatic backups", which is not the same as "unset".
    assert _tuned.spec.snapshotRetentionDays == 0, "snapshotRetentionDays=0 must be forwarded"
    assert _tuned.spec.passwordSecret == {name = "db-password", key = "password"}, "passwordSecret must be carried verbatim"
}

test_cache_sizing = lambda {
    _cache_child = _child(appstack.render(_build(_min("gcp"))), "cache")
    assert _cache_child.spec?.memoryGb == Undefined, "no memoryGb unless asked for"
    assert _cache_child.spec?.authEnabled == Undefined, "no authEnabled unless asked for"

    _tuned = _child(appstack.render(_build(_min("gcp") | {
        cache = {
            engineVersion = "7.0"
            memoryGb = 4
            replicas = 1
            highAvailability = True
            authEnabled = False
        }
    })), "cache")
    assert _tuned.spec.engineVersion == "7.0", "engineVersion must be carried"
    assert _tuned.spec.memoryGb == 4, "memoryGb must be carried"
    assert _tuned.spec.replicas == 1, "replicas must be carried"
    assert _tuned.spec.highAvailability == True, "highAvailability must be carried"
    assert _tuned.spec.authEnabled == False, "authEnabled=false must be forwarded"
}

# ---- render: network -> data service placement -----------------------------

# First reconcile: the Network exists only as a request, so there is nothing to
# attach to. A half-populated network block would be applied and then corrected.
test_placement_omitted_until_observed = lambda {
    _gcp = appstack.render(_build(_min("gcp")), {})
    assert _child(_gcp, "database").spec?.network == Undefined, "gcp: no db placement before the Network reports"
    assert _child(_gcp, "cache").spec?.network == Undefined, "gcp: no cache placement before the Network reports"
    _aws = appstack.render(_build(_min("aws")), {})
    assert _child(_aws, "database").spec?.network == Undefined, "aws: no db placement before the Network reports"
    assert _child(_aws, "cache").spec?.network == Undefined, "aws: no cache placement before the Network reports"
}

test_placement_aws = lambda {
    items = appstack.render(_build(_min("aws")), _observed_children(_aws_net_observed))
    assert _child(items, "database").spec.network == {
        subnetGroupName = "demo-net-db"
        securityGroupIds = ["sg-0abc"]
    }, "aws database must attach to the RDS subnet group"
    assert _child(items, "cache").spec.network == {
        subnetGroupName = "demo-net-cache"
        securityGroupIds = ["sg-0abc"]
    }, "aws cache must attach to the ElastiCache subnet group"
}

# A subnet group with no security group is worse than no block at all.
test_placement_aws_partial = lambda {
    _partial = _observed_children({ready = True, dbSubnetGroupName = "demo-net-db", cacheSubnetGroupName = "demo-net-cache", securityGroupIds = []})
    items = appstack.render(_build(_min("aws")), _partial)
    assert _child(items, "database").spec?.network == Undefined, "no placement without security groups"
    assert _child(items, "cache").spec?.network == Undefined, "no placement without security groups"
}

test_placement_gcp = lambda {
    items = appstack.render(_build(_min("gcp")), _observed_children(_gcp_net_observed))

    # Cloud SQL private IP takes the network only; the reserved range is a
    # Memorystore input, and PostgresInstance has no field for it.
    assert _child(items, "database").spec.network == {
        id = "projects/p/global/networks/demo-net"
    }, "gcp database must attach to the VPC self link"
    assert _child(items, "cache").spec.network == {
        id = "projects/p/global/networks/demo-net"
        reservedIpRange = "10.9.0.0/20"
    }, "gcp cache must also get the reserved service range"
}

# Before the self link is published the id is all there is, and it is enough.
test_placement_gcp_id_fallback = lambda {
    items = appstack.render(_build(_min("gcp")), _observed_children({ready = True, id = "demo-net"}))
    assert _child(items, "database").spec.network == {id = "demo-net"}, "id must stand in for a missing self link"
    assert _child(items, "cache").spec.network == {id = "demo-net"}, "no reservedIpRange until the range is published"
}

# ---- render: database/cache -> app environment ------------------------------
test_env_injection_gcp = lambda {
    items = appstack.render(_build(_min("gcp")), _observed_children(_gcp_net_observed))
    _env_pair = [_child(items, "api").spec.env, _child(items, "worker").spec.env]
    assert all e in _env_pair {sorted([_k for _k in e]) == _all_env_keys}, "both apps must receive every observed coordinate"

    env = _env_pair[0]
    assert env.DATABASE_HOST == "10.0.0.5", "database host must be injected"
    assert env.DATABASE_PORT == "5432", "ports are injected as strings"
    assert env.DATABASE_NAME == "app", "database name must be injected"
    assert env.DATABASE_USER == "app", "database user must be injected"
    assert env.DATABASE_URL == "postgresql://10.0.0.5:5432/app", "credential-free database URI must be injected"
    # Only the NAME of the Secret travels; ServerlessApp manages no secrets.
    assert env.DATABASE_PASSWORD_SECRET == "demo-db-password", "database password Secret name must be injected"
    assert env.DATABASE_PASSWORD_SECRET_KEY == "password", "database password Secret key must be injected"
    assert env.REDIS_HOST == "10.0.0.9", "cache host must be injected"
    assert env.REDIS_PORT == "6379", "ports are injected as strings"
    assert env.REDIS_URL == "rediss://10.0.0.9:6379", "cache URI must be injected as the child spelled it"
    assert env.REDIS_AUTH_SECRET == "demo-cache-redis-auth", "cache auth Secret name must be injected"
    assert env.REDIS_AUTH_SECRET_KEY == "attribute.auth_string", "cache auth Secret key must be injected"
    assert _env_pair[1] == env, "the worker must receive exactly the api's coordinates"
}

# The injected keys do not depend on the backend — they come from the child XRs'
# portable status, which is the point of the capability XRDs.
test_env_injection_aws = lambda {
    items = appstack.render(_build(_min("aws")), _observed_children(_aws_net_observed))
    _env_pair = [_child(items, "api").spec.env, _child(items, "worker").spec.env]
    assert all e in _env_pair {sorted([_k for _k in e]) == _all_env_keys}, "aws must inject the same coordinate set as gcp"
    assert _env_pair[0].DATABASE_URL == "postgresql://10.0.0.5:5432/app", "database URI must be injected"
    assert _env_pair[0].DATABASE_PASSWORD_SECRET_KEY == "password", "database password Secret key must be injected"
    assert _env_pair[0].REDIS_AUTH_SECRET == "demo-cache-redis-auth", "cache auth Secret name must be injected"
    assert _env_pair[0].REDIS_AUTH_SECRET_KEY == "attribute.auth_string", "cache auth Secret key must be injected"
}

# Nothing is injected before the data services report, so an app never starts
# with DATABASE_HOST="".
test_env_not_injected_before_observed = lambda {
    items = appstack.render(_build(_min("gcp") | {
        api = {image = "reg/api:v1", env = {LOG_LEVEL = "debug"}}
    }))
    assert _child(items, "api").spec.env == {LOG_LEVEL = "debug"}, "user env survives with nothing to inject"
    assert _child(items, "worker").spec?.env == Undefined, "no env key at all when there is nothing to set"
}

# Partial observation injects only what exists.
test_env_partial_observation = lambda {
    _partial = {database = _wrap({ready = False, host = "10.0.0.5", port = 5432, database = "app"})}
    env = _child(appstack.render(_build(_min("gcp")), _partial), "api").spec.env
    assert sorted([_k for _k in env]) == ["DATABASE_HOST", "DATABASE_NAME", "DATABASE_PORT"], "only observed coordinates are injected"
}

# The composed database is the live truth, so its coordinates win over a value
# left behind in the spec.
test_injected_env_overrides_user = lambda {
    _spec = _min("gcp") | {
        api = {image = "reg/api:v1", env = {DATABASE_HOST = "stale.example.com", LOG_LEVEL = "debug"}}
        worker = {image = "reg/worker:v1", env = {REDIS_URL = "redis://stale.example.com:6379"}}
    }
    items = appstack.render(_build(_spec), _observed_children(_gcp_net_observed))
    _api_env = _child(items, "api").spec.env
    assert _api_env.DATABASE_HOST == "10.0.0.5", "the observed host must override a stale user value"
    assert _api_env.LOG_LEVEL == "debug", "unrelated user env must survive the merge"
    assert _child(items, "worker").spec.env.REDIS_URL == "rediss://10.0.0.9:6379", "the observed cache URI must override a stale user value"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = appstack.status(_build(_min("gcp")), {})
    assert dxr.apiVersion == "platform.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "AppStack", "dxr kind must echo the composite"
    assert dxr.metadata.name == "demo", "dxr must carry the composite name"
    assert dxr.status.provider == "gcp", "provider must be echoed from the spec"
    assert dxr.status.ready == False, "nothing observed -> not ready"
    assert dxr.status.components == {network = False, api = False, worker = False, database = False, cache = False}, "every component starts false"
    assert dxr.status?.apiUrl == Undefined, "no api URL before the app exists"
    assert dxr.status?.networkId == Undefined, "no network id before the network exists"
}

test_status_all_ready = lambda {
    dxr = appstack.status(_build(_min("gcp")), _observed_children(_gcp_net_observed))
    assert dxr.status.ready == True, "all five children ready -> stack ready"
    assert dxr.status.components == {network = True, api = True, worker = True, database = True, cache = True}, "every component must be reported ready"
    assert dxr.status.apiUrl == "https://demo-api.example.run", "api URL must be copied from the child"
    assert dxr.status.workerUrl == "https://demo-worker.example.run", "worker URL must be copied from the child"
    assert dxr.status.databaseEndpoint == "10.0.0.5:5432", "database endpoint must be copied from the child"
    assert dxr.status.databaseUrl == "postgresql://10.0.0.5:5432/app", "database URI must be copied, not rebuilt"
    assert dxr.status.cacheEndpoint == "10.0.0.9:6379", "cache endpoint must be copied from the child"
    assert dxr.status.cacheUrl == "rediss://10.0.0.9:6379", "cache URI must be copied, not rebuilt"
    assert dxr.status.networkId == "demo-net", "network id must be copied from the child"
}

# A stack is only usable end to end: one child short is not ready, but the
# per-child breakdown still shows where it is stuck.
test_status_one_child_not_ready = lambda {
    _partial = _observed_children(_gcp_net_observed) | {cache = _wrap(_cache_observed | {ready = False})}
    dxr = appstack.status(_build(_min("gcp")), _partial)
    assert dxr.status.ready == False, "one child not ready -> stack not ready"
    assert dxr.status.components.cache == False, "the unready child must be reported"
    assert dxr.status.components.database == True, "the ready children must still be reported ready"

    # Coordinates are still published: the cache exists, it just has not
    # finished converging, and an operator needs the endpoint to look at it.
    assert dxr.status.cacheEndpoint == "10.0.0.9:6379", "an observed endpoint is published regardless of readiness"
}

test_status_aws = lambda {
    dxr = appstack.status(_build(_min("aws")), _observed_children(_aws_net_observed))
    assert dxr.status.provider == "aws", "provider must be echoed from the spec"
    assert dxr.status.ready == True, "all five children ready -> stack ready"
    assert dxr.status.networkId == "vpc-0abc", "the VPC id must be surfaced on aws"
}
