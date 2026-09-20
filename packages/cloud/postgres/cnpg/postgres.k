# postgres (cnpg) — Crossplane Composition logic (function-kcl module).
# The in-cluster backend: no cloud account, no VPC. Typed against the CNPG
# schema package, it renders one namespaced postgresql.cnpg.io/v1 Cluster
# DIRECTLY — Crossplane v2 composes arbitrary namespaced resources, so there
# is no provider MR wrapper, no providerConfigRef and no managementPolicies
# (deletionPolicy is documented as ignored in-cluster: the Cluster's lifetime
# follows the XR, and workloadIdentity too: there is no cloud IAM in-cluster).
#
# Backups are the one thing an in-cluster database has to be TOLD about: a
# managed service backs itself up to storage you never see, while CNPG needs
# an object store named for it. spec.backup is that name, and without it the
# Cluster renders exactly as it always did — no bucket, no WAL archive, and
# nothing to restore from once the cluster is gone.
import cnpg.models.v1.postgresql_cnpg_io_v1_cluster as backend

# Pinned repository; the major tag tracks the latest published minor image,
# so a re-render picks up patch releases without ever jumping a major.
image_repository = "ghcr.io/cloudnative-pg/postgresql"

# Service names the operator derives from the Cluster name.
rw_service = lambda name: str -> str {
    "${name}-rw"
}
ro_service = lambda name: str -> str {
    "${name}-ro"
}

# barman-cloud addresses an object store by URL, so the provider picks the
# scheme rather than the cloud: s3:// reaches AWS and every S3-compatible
# server alike. Azure has no scheme of its own — CNPG carries the storage
# account name in the host of the blob service URL, so there the endpoint IS
# the first half of the destination.
_schemes = {s3 = "s3://", gcs = "gs://"}

destination_path = lambda backup {
    _provider = backup?.provider or "s3"
    _base = "${backup.endpoint}/${backup.bucket}" if _provider == "azure" else "${_schemes[_provider]}${backup.bucket}"
    "${_base}/${backup.path}" if backup?.path else _base
}

# Where backups go and how the PostgreSQL pods authenticate to get there.
# Each object-store API takes its own credential block, and each has an
# ambient-identity flag for when no Secret is named — the only shape that
# keeps a long-lived key out of the cluster, and the only one a self-hosted
# cluster cannot use.
barman_object_store = lambda backup {
    _provider = backup?.provider or "s3"
    _sec = backup?.credentialsSecret
    _name = _sec?.name
    {
        destinationPath = destination_path(backup)
        # Only S3 has an endpoint override to set; Azure's endpoint is already
        # inside destinationPath, and GCS has none at all.
        if _provider == "s3" and backup?.endpoint:
            endpointURL = backup.endpoint
        if _provider == "gcs":
            googleCredentials = {
                if _sec:
                    applicationCredentials = {name = _name, key = _sec?.applicationCredentialsKey or "gcsCredentials"}
                else:
                    gkeEnvironment = True
            }
        elif _provider == "azure":
            azureCredentials = {
                if _sec:
                    storageAccount = {name = _name, key = _sec?.accessKeyIdKey or "ACCESS_KEY_ID"}
                    storageKey = {name = _name, key = _sec?.secretAccessKeyKey or "ACCESS_SECRET_KEY"}
                else:
                    inheritFromAzureAD = True
            }
        else:
            s3Credentials = {
                if _sec:
                    accessKeyId = {name = _name, key = _sec?.accessKeyIdKey or "ACCESS_KEY_ID"}
                    secretAccessKey = {name = _name, key = _sec?.secretAccessKeyKey or "ACCESS_SECRET_KEY"}
                    # CNPG takes the region only as a Secret key reference,
                    # never as a literal, so it is opt-in by key name.
                    if _sec?.regionKey:
                        region = {name = _name, key = _sec.regionKey}
                else:
                    inheritFromIAMRole = True
            }
    }
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    _version = _spec?.engineVersion or "16"
    _memory = _spec?.memoryGb or 2
    _storage = _spec?.storageGb or 20
    _db = _spec?.database or "app"
    _user = _spec?.username or "app"

    # A streaming standby is what makes failover possible in-cluster;
    # highAvailability with no explicit replicas still needs one, mirroring
    # the AWS multiAz mapping.
    _replicas = _spec?.replicas or 0
    if (_spec?.highAvailability or False) and _replicas < 1:
        _replicas = 1

    # Backups need somewhere to go, so the block's presence is the switch.
    _backup = _spec?.backup

    # snapshotRetentionDays is a tri-state: an explicit 0 means "no expiry
    # rule", and `or` would silently turn it back into the XRD default.
    _retention = _spec?.snapshotRetentionDays
    if _retention == Undefined:
        _retention = 7

    # Azure's destination is assembled FROM the endpoint, so unlike S3 it
    # cannot be left out.
    assert (not _backup) or (_backup?.provider or "s3") != "azure" or _backup?.endpoint, "spec.backup.provider 'azure' needs spec.backup.endpoint: CNPG builds the Azure destination from the blob service URL (https://<account>.blob.core.windows.net), the only place the storage account name appears. Set it, or use provider 's3' against an S3-compatible endpoint."

    [backend.Cluster {
        # The operator derives the -rw/-ro Service names from the Cluster
        # name, so naming it after the XR is what makes the status endpoints
        # deterministic. No namespace: Crossplane places composed namespaced
        # resources in the XR's own namespace.
        metadata.name = _name
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        spec.imageName = "${image_repository}:${_version}"
        # CNPG counts the primary among its instances.
        spec.instances = _replicas + 1
        spec.storage.size = "${_storage}Gi"
        # A database should reserve what it can use.
        spec.resources = {
            requests = {memory = "${_memory}Gi"}
            limits = {memory = "${_memory}Gi"}
        }
        spec.bootstrap.initdb = {
            database = _db
            owner = _user
            # CNPG consumes the whole kubernetes.io/basic-auth Secret, so
            # passwordSecret.key is ignored here (as the XRD documents).
            if _spec?.passwordSecret:
                secret.name = _spec.passwordSecret.name
        }
        # A map field on the CRD, so values pass through verbatim.
        if _spec?.parameters:
            spec.postgresql.parameters = _spec.parameters
        if _spec?.tags:
            spec.inheritedMetadata.labels = _spec.tags
        if _backup:
            spec.backup = {
                barmanObjectStore = barman_object_store(_backup)
                # barman expresses retention as an expiry rule in its own
                # <n>[dwm] spelling, and has no way to say "never expire":
                # 0 is that, so it emits no rule at all.
                if _retention > 0:
                    retentionPolicy = "${_retention}d"
            }
    }]
}

# Build the desired composite carrying observed status back to the XR.
# In-cluster endpoints are deterministic from the Cluster name, so they are
# reported as soon as the Cluster exists rather than read back from a cloud.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _st = (ocds["managed"]?.Resource?.status) if ("managed" in ocds) else Undefined

    _db = _spec?.database or "app"
    _user = _spec?.username or "app"

    _replicas = _spec?.replicas or 0
    if (_spec?.highAvailability or False) and _replicas < 1:
        _replicas = 1

    _host = "${rw_service(_name)}.${_ns}.svc.cluster.local"
    _reader = "${ro_service(_name)}.${_ns}.svc.cluster.local" if _replicas > 0 else _host

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "PostgresInstance"
        metadata.name = _name
        status = {
            provider = "cnpg"
            ready = (_st?.readyInstances or 0) >= 1
            host = _host
            port = 5432
            endpoint = "${_host}:5432"
            readEndpoint = "${_reader}:5432"
            url = "postgresql://${_host}:5432/${_db}"
            database = _db
            username = _user
            "cloud-url" = "kubernetes://${_ns}/cluster.postgresql.cnpg.io/${_name}"
            # The operator generates the app credentials into <cluster>-app
            # unless an existing basic-auth Secret was supplied.
            authSecret = _spec?.passwordSecret?.name or "${_name}-app"
            authSecretKey = "password"
            if _st?.image:
                # The running minor is the image tag, e.g. ...:16.4 -> 16.4.
                version = _st.image.split(":")[-1]
            if _st?.systemID:
                id = _st.systemID
        }
    }
}
