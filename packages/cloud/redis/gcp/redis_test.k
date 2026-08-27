import .redis

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "RedisInstance", metadata.name = "demo", spec = _spec}
}

# The single Memorystore Instance forProvider block from a render().
_fp = lambda _spec {
    redis.render(_build(_spec))[0].spec.forProvider
}

# ---- render: shape ----------------------------------------------------------

# Memorystore expresses everything inline -> exactly one MR.
test_render_minimal = lambda {
    items = redis.render(_build({region = "us-central1"}))
    assert len(items) == 1, "Memorystore render must emit exactly one Instance"
    assert items[0].apiVersion == "redis.gcp.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "Instance", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    fp = items[0].spec.forProvider
    assert fp.region == "us-central1", "region must be carried"
    assert fp.memorySizeGb == 1, "memoryGb must default to 1"
}

# ---- render: version --------------------------------------------------------
test_version_mapping = lambda {
    assert redis.version_for("7.0") == "REDIS_7_0", "dots become underscores"
    assert redis.version_for("6.2") == "REDIS_6_2", "dots become underscores"
    assert _fp({region = "us-central1"}).redisVersion == "REDIS_7_0", "engineVersion defaults to 7.0"
    assert _fp({region = "us-central1", engineVersion = "6.2"}).redisVersion == "REDIS_6_2", "engineVersion must be carried"
}

# ---- render: tier / replication --------------------------------------------
test_tier = lambda {
    assert _fp({region = "us-central1"}).tier == "BASIC", "no HA and no replicas -> BASIC"
    assert _fp({region = "us-central1", highAvailability = True}).tier == "STANDARD_HA", "HA -> STANDARD_HA"
}

# Read replicas are STANDARD_HA-only, so asking for them must upgrade the tier
# rather than silently dropping them.
test_replicas_imply_ha_tier = lambda {
    fp = _fp({region = "us-central1", replicas = 2})
    assert fp.tier == "STANDARD_HA", "replicas must force the HA tier"
    assert fp.replicaCount == 2, "replica count must be carried"
    assert fp.readReplicasMode == "READ_REPLICAS_ENABLED", "replicas must enable read replicas"
    off = _fp({region = "us-central1"})
    assert off.readReplicasMode == "READ_REPLICAS_DISABLED", "no replicas -> read replicas disabled"
    assert off?.replicaCount == Undefined, "no replicaCount when there are no replicas"
}

# ---- render: auth and encryption -------------------------------------------
test_auth_defaults_on = lambda {
    items = redis.render(_build({region = "us-central1"}))
    assert items[0].spec.forProvider.authEnabled == True, "auth defaults on"
    assert items[0].spec.writeConnectionSecretToRef.name == "demo-redis-auth", "auth must publish a connection secret"
}

test_auth_disabled = lambda {
    items = redis.render(_build({region = "us-central1", authEnabled = False}))
    assert items[0].spec.forProvider.authEnabled == False, "authEnabled=false must be carried"
    assert items[0].spec?.writeConnectionSecretToRef == Undefined, "no connection secret without auth"
}

test_transit_encryption = lambda {
    assert _fp({region = "us-central1"}).transitEncryptionMode == "SERVER_AUTHENTICATION", "transit encryption defaults on"
    assert _fp({region = "us-central1", transitEncryption = False}).transitEncryptionMode == "DISABLED", "transitEncryption=false -> DISABLED"
}

# Memorystore is always encrypted at rest; only the CMEK is configurable.
test_cmek = lambda {
    _key = "projects/p/locations/us-central1/keyRings/r/cryptoKeys/k"
    assert _fp({region = "us-central1", encryptionKmsKeyId = _key}).customerManagedKey == _key, "CMEK must be carried"
    assert _fp({region = "us-central1"})?.customerManagedKey == Undefined, "no CMEK unless asked for"
}

# ---- render: persistence ----------------------------------------------------

# Memorystore has a snapshot period, not a day count; retention picks the period.
test_persistence = lambda {
    assert _fp({region = "us-central1"}).persistenceConfig.persistenceMode == "RDB", "persistence defaults on"
    assert _fp({region = "us-central1"}).persistenceConfig.rdbSnapshotPeriod == "ONE_HOUR", "no retention -> the finest period"
    assert _fp({region = "us-central1", snapshotRetentionDays = 1}).persistenceConfig.rdbSnapshotPeriod == "SIX_HOURS", "1 day -> SIX_HOURS"
    assert _fp({region = "us-central1", snapshotRetentionDays = 3}).persistenceConfig.rdbSnapshotPeriod == "TWELVE_HOURS", "3 days -> TWELVE_HOURS"
    assert _fp({region = "us-central1", snapshotRetentionDays = 30}).persistenceConfig.rdbSnapshotPeriod == "TWENTY_FOUR_HOURS", "long retention -> daily"
    _off = _fp({region = "us-central1", persistence = False}).persistenceConfig
    assert _off.persistenceMode == "DISABLED", "persistence=false -> DISABLED"
    assert _off?.rdbSnapshotPeriod == Undefined, "no snapshot period when persistence is off"
}

# ---- render: config, labels, network, maintenance ---------------------------
test_parameters_and_labels = lambda {
    fp = _fp({region = "us-central1", parameters = {"maxmemory-policy" = "allkeys-lru"}, tags = {team = "platform"}})
    assert fp.redisConfigs == {"maxmemory-policy" = "allkeys-lru"}, "parameters -> redisConfigs"
    assert fp.labels == {team = "platform"}, "tags -> labels"
}

test_network = lambda {
    fp = _fp({region = "us-central1", network = {id = "projects/p/global/networks/default", reservedIpRange = "10.1.0.0/29"}})
    assert fp.authorizedNetwork == "projects/p/global/networks/default", "network.id -> authorizedNetwork"
    assert fp.reservedIpRange == "10.1.0.0/29", "reservedIpRange must be carried"
}

test_maintenance_window = lambda {
    _w = _fp({region = "us-central1", maintenanceWindow = {day = "wed", hour = 3}}).maintenancePolicy.weeklyMaintenanceWindow
    assert len(_w) == 1, "one window"
    assert _w[0].day == "WEDNESDAY", "day must map to the Memorystore enum"
    assert _w[0].startTime.hours == 3, "hour must be carried"
    assert _fp({region = "us-central1"})?.maintenancePolicy == Undefined, "no policy unless asked for"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = redis.render(_build({region = "us-central1", deletionPolicy = "Orphan"}))[0].spec.managementPolicies
    assert _orphaned == _orphan, "Orphan must set the non-delete policies"
    _deleted = redis.render(_build({region = "us-central1"}))[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = redis.status(_build({region = "us-central1"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "RedisInstance", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status?.host == Undefined, "no host before the instance exists"
    assert dxr.status.authSecret == "demo-redis-auth", "auth secret name is known ahead of creation"
    assert dxr.status.authSecretKey == "attribute.auth_string", "auth secret key must be published"
    assert dxr.status["cloud-url"].startswith("https://console.cloud.google.com/memorystore"), "cloud-url must point at the Memorystore console"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = "projects/p/locations/us-central1/instances/demo"
                        host = "10.1.0.3"
                        port = 6379
                        readEndpoint = "10.1.0.4"
                        readEndpointPort = 6379
                        redisVersion = "REDIS_7_0"
                        region = "us-central1"
                    }
                }
            }
        }
    }
    dxr = redis.status(_build({region = "us-central1"}), ocds)
    assert dxr.status.ready == True, "an observed host must mark the instance ready"
    assert dxr.status.host == "10.1.0.3", "host must be surfaced"
    assert dxr.status.endpoint == "10.1.0.3:6379", "endpoint must be host:port"
    assert dxr.status.readEndpoint == "10.1.0.4:6379", "read endpoint must be surfaced"
    assert dxr.status.url == "rediss://10.1.0.3:6379", "transit encryption must select the rediss scheme"
    assert dxr.status.version == "REDIS_7_0", "version must be surfaced"
    assert dxr.status.id == "projects/p/locations/us-central1/instances/demo", "observed id must be surfaced"
}

# Without a separate read endpoint the reader falls back to the primary, and
# plaintext transport drops the URL back to redis://.
test_status_no_read_replica = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {host = "10.1.0.3", port = 6379}
                }
            }
        }
    }
    dxr = redis.status(_build({region = "us-central1", transitEncryption = False, authEnabled = False}), ocds)
    assert dxr.status.readEndpoint == "10.1.0.3:6379", "read endpoint falls back to the primary"
    assert dxr.status.url == "redis://10.1.0.3:6379", "plaintext transport must use the redis scheme"
    assert dxr.status?.authSecret == Undefined, "no auth secret when auth is off"
}
