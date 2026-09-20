import .postgres

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec, _ns: str = "default" {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "PostgresInstance", metadata = {name = "demo", namespace = _ns}, spec = _spec}
}

# The single CNPG Cluster spec from a render().
_cs = lambda _spec {
    postgres.render(_build(_spec))[0].spec
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = postgres.render(_build({region = "in-cluster"}))
    assert len(items) == 1, "the in-cluster backend must emit exactly one Cluster"
    assert items[0].apiVersion == "postgresql.cnpg.io/v1", "must be the CNPG CRD, composed directly"
    assert items[0].kind == "Cluster", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].metadata.name == "demo", "the Cluster must be named after the XR — the operator derives the Service names from it"
    assert items[0].metadata?.namespace == Undefined, "no namespace: Crossplane places the Cluster in the XR's namespace"
    assert items[0].spec.imageName == "${postgres.image_repository}:16", "engineVersion defaults to the 16 major tag"
    assert _cs({region = "in-cluster", engineVersion = "17"}).imageName == "${postgres.image_repository}:17", "engineVersion must pick the image tag"
}

# ---- render: topology -------------------------------------------------------

# CNPG counts the primary among its instances, so instances = replicas + 1.
test_instances = lambda {
    assert _cs({region = "in-cluster"}).instances == 1, "no replicas -> a single instance"
    assert _cs({region = "in-cluster", replicas = 2}).instances == 3, "replicas must add to the primary"
}

# Failover needs a standby, so HA must add one even at replicas=0.
test_high_availability_forces_a_standby = lambda {
    assert _cs({region = "in-cluster", highAvailability = True}).instances == 2, "HA must add a standby"
    assert _cs({region = "in-cluster", highAvailability = True, replicas = 3}).instances == 4, "explicit replicas already satisfy HA"
}

# ---- render: sizing ---------------------------------------------------------
test_sizing = lambda {
    _s = _cs({region = "in-cluster"})
    assert _s.resources.limits.memory == "2Gi", "memoryGb defaults to 2Gi as the container limit"
    assert _s.resources.requests.memory == "2Gi", "a database must reserve what it can use"
    assert _s.storage.size == "20Gi", "storageGb defaults to a 20Gi PVC"
    _sized = _cs({region = "in-cluster", memoryGb = 4, storageGb = 100})
    assert _sized.resources.limits.memory == "4Gi", "memoryGb must become the container limit"
    assert _sized.storage.size == "100Gi", "storageGb must size the PVC"
}

# ---- render: initdb ---------------------------------------------------------
test_initdb = lambda {
    _i = _cs({region = "in-cluster"}).bootstrap.initdb
    assert _i.database == "app", "database defaults to app"
    assert _i.owner == "app", "username defaults to app"
    assert _i?.secret == Undefined, "no secret ref -> the operator generates the credentials"
    _named = _cs({region = "in-cluster", database = "orders", username = "svc"}).bootstrap.initdb
    assert _named.database == "orders", "database must be carried"
    assert _named.owner == "svc", "username must become the owner"
}

# CNPG consumes the whole basic-auth Secret; passwordSecret.key is ignored.
test_initdb_password_secret = lambda {
    _i = _cs({region = "in-cluster", passwordSecret = {name = "pg-creds", key = "pw"}}).bootstrap.initdb
    assert _i.secret.name == "pg-creds", "passwordSecret must wire the initdb secret"
}

# ---- render: parameters and labels ------------------------------------------
test_parameters_passthrough = lambda {
    _s = _cs({region = "in-cluster", parameters = {"max_connections" = "200"}})
    assert _s.postgresql.parameters == {"max_connections" = "200"}, "parameters must pass through verbatim"
    assert _cs({region = "in-cluster"})?.postgresql == Undefined, "no postgresql block unless asked for"
}

test_labels = lambda {
    assert _cs({region = "in-cluster", tags = {team = "platform"}}).inheritedMetadata.labels == {team = "platform"}, "tags -> inherited labels"
    assert _cs({region = "in-cluster"})?.inheritedMetadata == Undefined, "no labels unless asked for"
}

# ---- render: backup ---------------------------------------------------------

# The object store is the switch: no spec.backup, no backup block at all —
# and snapshotRetentionDays on its own cannot conjure one, because retention
# is an expiry rule over backups that have somewhere to live.
test_backup_unset = lambda {
    assert _cs({region = "in-cluster"})?.backup == Undefined, "no object store -> no backup block"
    _plain = postgres.render(_build({region = "in-cluster"}))
    _retained = postgres.render(_build({region = "in-cluster", snapshotRetentionDays = 14}))
    assert _plain == _retained, "snapshotRetentionDays alone must not change the render: there is nowhere to keep anything"
}

_s3 = {bucket = "pg-backups", path = "prod/demo", endpoint = "http://rustfs.rustfs.svc.cluster.local:9000", credentialsSecret = {name = "rustfs-creds", regionKey = "REGION"}}

# The self-hosted case: an in-cluster S3-compatible server reached by an
# explicit endpoint, with keys in a Secret.
test_backup_s3 = lambda {
    _b = _cs({region = "in-cluster", backup = _s3}).backup.barmanObjectStore
    assert _b.destinationPath == "s3://pg-backups/prod/demo", "destinationPath is the bucket URL plus the path prefix"
    assert _b.endpointURL == "http://rustfs.rustfs.svc.cluster.local:9000", "an S3-compatible server is reached through endpointURL"
    assert _b.s3Credentials.accessKeyId.name == "rustfs-creds", "the credential Secret must be wired to the access key"
    assert _b.s3Credentials.accessKeyId.key == "ACCESS_KEY_ID", "the access key defaults to CNPG's own key name"
    assert _b.s3Credentials.secretAccessKey.name == "rustfs-creds", "the credential Secret must be wired to the secret key"
    assert _b.s3Credentials.secretAccessKey.key == "ACCESS_SECRET_KEY", "the secret key defaults to CNPG's own key name"
    assert _b.s3Credentials.region.name == "rustfs-creds", "the region lives in the same Secret"
    assert _b.s3Credentials.region.key == "REGION", "CNPG takes the region only as a Secret key reference, never as a literal"
    assert _b.s3Credentials?.inheritFromIAMRole == Undefined, "a named Secret must not also claim an ambient identity"
    assert _b?.googleCredentials == Undefined, "one provider, one credential block"
    assert _b?.azureCredentials == Undefined, "one provider, one credential block"
}

test_backup_s3_minimal = lambda {
    _b = _cs({region = "in-cluster", backup = {bucket = "pg-backups", credentialsSecret = {name = "s3-creds", accessKeyIdKey = "id", secretAccessKeyKey = "secret"}}}).backup.barmanObjectStore
    assert _b.destinationPath == "s3://pg-backups", "no path -> the bucket root, where CNPG separates clusters by serverName"
    assert _b?.endpointURL == Undefined, "no endpoint -> the SDK's own endpoint discovery, i.e. AWS"
    assert _b.s3Credentials.accessKeyId.key == "id", "an explicit key name must win"
    assert _b.s3Credentials.secretAccessKey.key == "secret", "an explicit key name must win"
    assert _b.s3Credentials?.region == Undefined, "no regionKey -> leave the region to the SDK"
}

# No Secret named means the pods' own cloud identity, which is the only shape
# that keeps a long-lived key out of the cluster.
test_backup_ambient_identity = lambda {
    _aws = _cs({region = "in-cluster", backup = {bucket = "pg-backups"}}).backup.barmanObjectStore.s3Credentials
    assert _aws.inheritFromIAMRole == True, "no Secret on s3 -> IRSA"
    assert _aws?.accessKeyId == Undefined, "an ambient identity carries no keys"
    _gcp = _cs({region = "in-cluster", backup = {provider = "gcs", bucket = "pg-backups"}}).backup.barmanObjectStore.googleCredentials
    assert _gcp.gkeEnvironment == True, "no Secret on gcs -> Workload Identity"
    assert _gcp?.applicationCredentials == Undefined, "an ambient identity carries no JSON file"
    _azure = _cs({region = "in-cluster", backup = {provider = "azure", bucket = "pgbackups", endpoint = "https://acme.blob.core.windows.net"}}).backup.barmanObjectStore.azureCredentials
    assert _azure.inheritFromAzureAD == True, "no Secret on azure -> Entra ID"
    assert _azure?.storageKey == Undefined, "an ambient identity carries no storage key"
}

test_backup_gcs = lambda {
    _b = _cs({region = "in-cluster", backup = {provider = "gcs", bucket = "pg-backups", path = "demo", endpoint = "http://ignored:9000", credentialsSecret = {name = "gcs-creds"}}}).backup.barmanObjectStore
    assert _b.destinationPath == "gs://pg-backups/demo", "GCS gets barman's gs:// scheme"
    assert _b?.endpointURL == Undefined, "GCS has no endpoint override, so endpoint must be dropped"
    assert _b.googleCredentials.applicationCredentials.name == "gcs-creds", "the credential Secret must be wired to the JSON file"
    assert _b.googleCredentials.applicationCredentials.key == "gcsCredentials", "GCS authenticates with one JSON file under CNPG's conventional key"
}

# Azure has no scheme of its own: the storage account name lives in the host
# of the blob service URL, so the endpoint IS the first half of the path.
test_backup_azure = lambda {
    _b = _cs({region = "in-cluster", backup = {provider = "azure", bucket = "pgbackups", path = "demo", endpoint = "https://acme.blob.core.windows.net", credentialsSecret = {name = "azure-creds", accessKeyIdKey = "AZURE_STORAGE_ACCOUNT", secretAccessKeyKey = "AZURE_STORAGE_KEY"}}}).backup.barmanObjectStore
    assert _b.destinationPath == "https://acme.blob.core.windows.net/pgbackups/demo", "the Azure destination is built from the blob service URL"
    assert _b?.endpointURL == Undefined, "the endpoint is already inside destinationPath, so it must not be repeated"
    assert _b.azureCredentials.storageAccount.name == "azure-creds", "the credential Secret must be wired to the storage account"
    assert _b.azureCredentials.storageAccount.key == "AZURE_STORAGE_ACCOUNT", "Azure's identity half is the storage account name"
    assert _b.azureCredentials.storageKey.name == "azure-creds", "both halves come from the same Secret"
    assert _b.azureCredentials.storageKey.key == "AZURE_STORAGE_KEY", "Azure's secret half is the storage key"
}

# Retention is the EXISTING snapshotRetentionDays, in barman's <n>[dwm]
# spelling — one knob for every backend rather than a second in-cluster one.
test_backup_retention = lambda {
    assert _cs({region = "in-cluster", backup = _s3}).backup.retentionPolicy == "7d", "snapshotRetentionDays defaults to 7 -> 7d"
    assert _cs({region = "in-cluster", backup = _s3, snapshotRetentionDays = 30}).backup.retentionPolicy == "30d", "snapshotRetentionDays must become the retention policy"
    assert _cs({region = "in-cluster", backup = _s3, snapshotRetentionDays = 0})?.backup?.retentionPolicy == Undefined, "0 means keep forever: barman has no way to spell 'never expire' but an absent rule"
    assert _cs({region = "in-cluster", backup = _s3, snapshotRetentionDays = 0}).backup.barmanObjectStore.destinationPath == "s3://pg-backups/prod/demo", "0 retention must still back up — the object store is the switch"
}

# ---- render: workload identity ------------------------------------------------

# There is no cloud IAM in-cluster; the XRD documents the block as ignored, so
# its presence must not change the render.
test_workload_identity_ignored = lambda {
    _plain = postgres.render(_build({region = "in-cluster"}))
    _wi = postgres.render(_build({region = "in-cluster", workloadIdentity = {principal = "app@proj.iam.gserviceaccount.com"}}))
    assert _plain == _wi, "workloadIdentity must be ignored in-cluster"
}

# ---- status -----------------------------------------------------------------

# In-cluster endpoints are derived from the Cluster name, so they are known
# before the operator has converged — but readiness is not.
test_status_pre_creation = lambda {
    dxr = postgres.status(_build({region = "in-cluster"}, "team-a"), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "PostgresInstance", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "a Cluster with no ready instance must not be ready"
    assert dxr.status.provider == "cnpg", "provider must be cnpg"
    assert dxr.status.host == "demo-rw.team-a.svc.cluster.local", "host is the operator's -rw service"
    assert dxr.status.port == 5432, "postgres port"
    assert dxr.status.endpoint == "demo-rw.team-a.svc.cluster.local:5432", "endpoint must be host:port"
    assert dxr.status.readEndpoint == dxr.status.endpoint, "a single instance reads from the primary"
    assert dxr.status.url == "postgresql://demo-rw.team-a.svc.cluster.local:5432/app", "url must carry the database, no credentials"
    assert dxr.status.database == "app", "effective database must be surfaced"
    assert dxr.status.username == "app", "effective username must be surfaced"
    assert dxr.status.authSecret == "demo-app", "the operator names the generated secret <cluster>-app"
    assert dxr.status.authSecretKey == "password", "auth secret key must be published"
    assert dxr.status["cloud-url"] == "kubernetes://team-a/cluster.postgresql.cnpg.io/demo", "cloud-url must locate the Cluster"
}

test_status_password_secret = lambda {
    dxr = postgres.status(_build({region = "in-cluster", passwordSecret = {name = "pg-creds"}}), {})
    assert dxr.status.authSecret == "pg-creds", "a supplied secret must be echoed, not the generated name"
}

test_status_ready = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    readyInstances = 3
                    image = "ghcr.io/cloudnative-pg/postgresql:16.4"
                    systemID = "7301127540311534610"
                }
            }
        }
    }
    dxr = postgres.status(_build({region = "in-cluster", replicas = 2}, "team-a"), ocds)
    assert dxr.status.ready == True, "a ready instance must make the composite ready"
    assert dxr.status.readEndpoint == "demo-ro.team-a.svc.cluster.local:5432", "replicas get the -ro read service"
    assert dxr.status.version == "16.4", "version is the running image tag"
    assert dxr.status.id == "7301127540311534610", "id must be the PostgreSQL system identifier"
}

# HA forces a standby, so the read service exists even at replicas=0.
test_status_ha_read_endpoint = lambda {
    dxr = postgres.status(_build({region = "in-cluster", highAvailability = True}, "team-a"), {})
    assert dxr.status.readEndpoint == "demo-ro.team-a.svc.cluster.local:5432", "HA must expose the -ro service"
}

# An observed Cluster with nothing ready yet must not report ready.
test_status_zero_ready_instances = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {readyInstances = 0}
            }
        }
    }
    dxr = postgres.status(_build({region = "in-cluster"}), ocds)
    assert dxr.status.ready == False, "readyInstances=0 must not be ready"
    assert dxr.status?.version == Undefined, "no version until the operator reports an image"
    assert dxr.status?.id == Undefined, "no id until the operator reports a systemID"
}
