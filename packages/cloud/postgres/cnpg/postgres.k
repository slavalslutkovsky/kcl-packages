# postgres (cnpg) — Crossplane Composition logic (function-kcl module).
# The in-cluster backend: no cloud account, no VPC. Typed against the CNPG
# schema package, it renders one namespaced postgresql.cnpg.io/v1 Cluster
# DIRECTLY — Crossplane v2 composes arbitrary namespaced resources, so there
# is no provider MR wrapper, no providerConfigRef and no managementPolicies
# (deletionPolicy is documented as ignored in-cluster: the Cluster's lifetime
# follows the XR, and workloadIdentity too: there is no cloud IAM in-cluster).
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
