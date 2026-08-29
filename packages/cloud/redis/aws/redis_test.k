import .redis

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "RedisInstance", metadata.name = "demo", spec = _spec}
}

_by_kind = lambda _items, _k {
    _hits = [_i for _i in _items if _i.kind == _k]
    _hits[0] if _hits else Undefined
}

# The ReplicationGroup forProvider block from a render() of the given spec.
_fp = lambda _spec {
    redis.render(_build(_spec))[0].spec.forProvider
}

# ---- render: shape ----------------------------------------------------------

# Minimal spec: one ReplicationGroup, no ParameterGroup (no overrides given).
test_render_minimal = lambda {
    items = redis.render(_build({region = "us-east-1"}))
    assert len(items) == 1, "minimal render must emit exactly one MR"
    assert items[0].apiVersion == "elasticache.aws.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "ReplicationGroup", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    fp = items[0].spec.forProvider
    assert fp.region == "us-east-1", "region must be carried"
    assert fp.engine == "redis", "engine must be redis"
    assert fp.port == 6379, "port must default to 6379"
}

# ---- render: sizing ---------------------------------------------------------

# memoryGb picks the smallest node type that fits, and nodeType overrides it.
test_node_type_mapping = lambda {
    assert redis.node_for(0.4) == "cache.t4g.micro", "below the floor must take the smallest node"
    assert redis.node_for(1) == "cache.t4g.small", "1 GiB must fit cache.t4g.small"
    assert redis.node_for(1.37) == "cache.t4g.small", "an exact fit must not round up"
    assert redis.node_for(4) == "cache.m7g.large", "4 GiB must fit cache.m7g.large"
    assert redis.node_for(1000) == "cache.m7g.8xlarge", "above the ceiling must take the largest node"
    assert _fp({region = "us-east-1", memoryGb = 4}).nodeType == "cache.m7g.large", "memoryGb must drive nodeType"
    assert _fp({region = "us-east-1", memoryGb = 4, nodeType = "cache.r7g.large"}).nodeType == "cache.r7g.large", "nodeType must override the mapping"
}

# ---- render: replication / HA ----------------------------------------------
test_replicas = lambda {
    assert _fp({region = "us-east-1"}).numCacheClusters == 1, "no replicas -> a single node"
    assert _fp({region = "us-east-1", replicas = 2}).numCacheClusters == 3, "numCacheClusters counts the primary"
}

# Failover needs a second node even when no replicas were asked for; otherwise
# AWS rejects automaticFailoverEnabled on a one-node group.
test_high_availability = lambda {
    fp = _fp({region = "us-east-1", highAvailability = True})
    assert fp.automaticFailoverEnabled == True, "HA must enable automatic failover"
    assert fp.multiAzEnabled == True, "HA must enable multi-AZ"
    assert fp.numCacheClusters == 2, "HA must force a second node"
    off = _fp({region = "us-east-1"})
    assert off.automaticFailoverEnabled == False, "failover must default off"
    assert off.multiAzEnabled == False, "multi-AZ must default off"
}

# ---- render: auth and encryption -------------------------------------------
test_auth_defaults_on = lambda {
    fp = _fp({region = "us-east-1"})
    assert fp.transitEncryptionEnabled == True, "transit encryption defaults on"
    assert fp.autoGenerateAuthToken == True, "auth defaults on"
    assert fp.authTokenSecretRef.name == "demo-redis-auth", "auth token secret is named after the XR"
    assert fp.authTokenSecretRef.key == "password", "auth token key must be stable"
}

# AUTH is only legal over an encrypted transport, so it must drop with it.
test_auth_requires_transit_encryption = lambda {
    fp = _fp({region = "us-east-1", transitEncryption = False})
    assert fp.transitEncryptionEnabled == False, "transitEncryption=false must be carried"
    assert fp?.autoGenerateAuthToken == Undefined, "auth must not be requested without transit encryption"
    assert fp?.authTokenSecretRef == Undefined, "no auth token secret without transit encryption"
}

test_auth_disabled = lambda {
    fp = _fp({region = "us-east-1", authEnabled = False})
    assert fp?.autoGenerateAuthToken == Undefined, "authEnabled=false must not generate a token"
}

# Upjet types atRestEncryptionEnabled as a string, and a CMEK implies it.
test_at_rest_encryption = lambda {
    assert _fp({region = "us-east-1"}).atRestEncryptionEnabled == "true", "at-rest encryption defaults on"
    assert _fp({region = "us-east-1", atRestEncryption = False}).atRestEncryptionEnabled == "false", "at-rest encryption must be disablable"
    fp = _fp({region = "us-east-1", atRestEncryption = False, encryptionKmsKeyId = "arn:aws:kms:us-east-1:1:key/a"})
    assert fp.atRestEncryptionEnabled == "true", "a CMEK must imply at-rest encryption"
    assert fp.kmsKeyId == "arn:aws:kms:us-east-1:1:key/a", "CMEK must be carried"
}

# ---- render: persistence ----------------------------------------------------

# ElastiCache disables snapshots at 0, so persistence must floor the retention.
test_persistence_floors_retention = lambda {
    assert _fp({region = "us-east-1"}).snapshotRetentionLimit == 1, "persistence must keep at least one day"
    assert _fp({region = "us-east-1", snapshotRetentionDays = 7}).snapshotRetentionLimit == 7, "explicit retention must win"
    assert _fp({region = "us-east-1", persistence = False}).snapshotRetentionLimit == 0, "persistence=false must disable snapshots"
}

# ---- render: maintenance window --------------------------------------------
test_maintenance_window = lambda {
    assert redis.window_for({day = "sun", hour = 5}) == "sun:05:00-sun:07:00", "hours must be zero-padded"
    assert redis.window_for({day = "mon", hour = 0}) == "mon:00:00-mon:02:00", "midnight must render as 00:00"
    assert redis.window_for({day = "sat", hour = 23}) == "sat:23:00-sun:01:00", "a window past midnight must roll to the next day"
    assert redis.window_for({day = "sun", hour = 22}) == "sun:22:00-mon:00:00", "sunday must wrap to monday"
    assert _fp({region = "us-east-1", maintenanceWindow = {day = "wed", hour = 9}}).maintenanceWindow == "wed:09:00-wed:11:00", "window must be carried"
    assert _fp({region = "us-east-1"})?.maintenanceWindow == Undefined, "no window unless asked for"
}

# ---- render: parameters -----------------------------------------------------

# Overrides need a companion ParameterGroup, bound to the group by name.
test_parameters_add_group = lambda {
    items = redis.render(_build({region = "us-east-1", parameters = {"maxmemory-policy" = "volatile-lru"}}))
    assert len(items) == 2, "parameters must add a ParameterGroup MR"
    _group = _by_kind(items, "ParameterGroup")
    assert _group != Undefined, "ParameterGroup must be present"
    assert _group.spec.forProvider.name == "demo-params", "parameter group name must derive from the XR"
    assert len(_group.spec.forProvider.parameter) == 1, "one override -> one parameter entry"
    assert _group.spec.forProvider.parameter[0].name == "maxmemory-policy", "parameter name must be carried"
    assert _group.spec.forProvider.parameter[0].value == "volatile-lru", "parameter value must be carried"
    assert items[0].spec.forProvider.parameterGroupName == "demo-params", "replication group must reference the parameter group"
}

test_parameter_group_family = lambda {
    assert redis.family_for("7.0") == "redis7", "redis 7 uses the unsuffixed family"
    assert redis.family_for("7.1") == "redis7", "family tracks the major version only"
    assert redis.family_for("6.2") == "redis6.x", "redis 6 uses the .x family"
    items = redis.render(_build({region = "us-east-1", engineVersion = "6.2", parameters = {"appendonly" = "yes"}}))
    assert _by_kind(items, "ParameterGroup").spec.forProvider.family == "redis6.x", "family must follow engineVersion"
}

# ---- render: deletion policy ------------------------------------------------

# Orphan must reach the companion MR too, or deleting the XR still drops the
# parameter group.
test_deletion_policy_orphan = lambda {
    items = redis.render(_build({region = "us-east-1", deletionPolicy = "Orphan", parameters = {"appendonly" = "yes"}}))
    assert items[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies"
    assert _by_kind(items, "ParameterGroup").spec.managementPolicies == _orphan, "Orphan must reach companions"
}

test_deletion_policy_delete_default = lambda {
    items = redis.render(_build({region = "us-east-1"}))
    assert items[0].spec.managementPolicies != _orphan, "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = redis.status(_build({region = "us-east-1"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "RedisInstance", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status?.host == Undefined, "no host before the group exists"
    assert dxr.status.authSecret == "demo-redis-auth", "auth secret name is known ahead of creation"
    assert dxr.status.authSecretKey == "password", "auth secret key must be published"
    assert dxr.status["cloud-url"].startswith("https://us-east-1.console.aws.amazon.com/elasticache"), "cloud-url must point at the ElastiCache console"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        arn = "arn:aws:elasticache:us-east-1:1:replicationgroup:demo"
                        id = "demo"
                        region = "us-east-1"
                        port = 6379
                        primaryEndpointAddress = "master.demo.abc.use1.cache.amazonaws.com"
                        readerEndpointAddress = "replica.demo.abc.use1.cache.amazonaws.com"
                        engineVersionActual = "7.0.7"
                    }
                }
            }
        }
    }
    dxr = redis.status(_build({region = "us-east-1"}), ocds)
    assert dxr.status.ready == True, "an observed endpoint must mark the instance ready"
    assert dxr.status.host == "master.demo.abc.use1.cache.amazonaws.com", "primary endpoint must be the host"
    assert dxr.status.endpoint == "master.demo.abc.use1.cache.amazonaws.com:6379", "endpoint must be host:port"
    assert dxr.status.readEndpoint == "replica.demo.abc.use1.cache.amazonaws.com:6379", "reader endpoint must be surfaced"
    assert dxr.status.url == "rediss://master.demo.abc.use1.cache.amazonaws.com:6379", "transit encryption must select the rediss scheme"
    assert dxr.status.version == "7.0.7", "the actual engine version must be surfaced"
    assert dxr.status.arn.endswith("replicationgroup:demo"), "arn must be surfaced"
    assert dxr.status.id == "demo", "observed id must be surfaced"
}

# Cluster mode exposes one configuration endpoint instead of a primary, and
# without transit encryption the URL scheme drops back to redis://.
test_status_configuration_endpoint = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        configurationEndpointAddress = "clustercfg.demo.abc.use1.cache.amazonaws.com"
                        port = 6379
                    }
                }
            }
        }
    }
    dxr = redis.status(_build({region = "us-east-1", transitEncryption = False}), ocds)
    assert dxr.status.host == "clustercfg.demo.abc.use1.cache.amazonaws.com", "configuration endpoint must be the fallback host"
    assert dxr.status.readEndpoint == "clustercfg.demo.abc.use1.cache.amazonaws.com:6379", "read endpoint falls back to the host"
    assert dxr.status.url.startswith("redis://"), "plaintext transport must use the redis scheme"
    assert dxr.status?.authSecret == Undefined, "no auth secret when transit encryption is off"
}
