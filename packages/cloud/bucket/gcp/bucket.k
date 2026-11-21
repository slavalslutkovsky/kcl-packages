# bucket (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-storage schema package. Maps the portable Bucket
# common parameters onto a single GCS Bucket (GCS expresses versioning,
# access, encryption, retention, lifecycle, cors, logging and website inline).
import crypto
import gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket as backend
import gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket_i_a_m_member as iammember
import federation.lib as fed

# Abstract storage tier -> gcp native value.
_storage_class = {"standard" = "STANDARD", "nearline" = "NEARLINE", "cold" = "COLDLINE", "archive" = "ARCHIVE"}

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# access role -> GCS predefined role on the bucket. Object-level only: none
# of them can change the bucket's configuration or its IAM policy.
_access_roles = {read = "roles/storage.objectViewer", write = "roles/storage.objectUser", admin = "roles/storage.objectAdmin"}

# How Crossplane relates to the cloud bucket, for status.mode:
# created (Crossplane made it) | observe (adopted, read-only) | managed (adopted, Crossplane writes).
mode_of = lambda oxr -> str {
  _imp = oxr.spec?.$import
  "created" if not _imp?.existingName else ("observe" if (_imp?.mode or "observe") == "observe" else "managed")
}

# spec.providerConfigName -> the providerConfigRef every composed MR carries:
# a namespaced ProviderConfig in the XR's namespace, i.e. the (client) project
# the bucket is created in and billed to. Undefined keeps the provider default.
provider_config_ref = lambda oxr -> any {
  _n = oxr.spec?.providerConfigName
  {kind = "ProviderConfig", name = _n} if _n else Undefined
}

# One abstract lifecycleRules entry -> zero/one/two native GCS lifecycle rules.
_gcp_lifecycle = lambda r: any -> [any] {
  _prefix = r?.prefix or ""
  _cond = lambda days: int -> any {
    {age = days} if _prefix == "" else {age = days, matchesPrefix = [_prefix]}
  }
  _rules: [any] = []
  if r?.expirationDays != Undefined:
    _rules += [{action = {$type = "Delete"}, condition = _cond(r.expirationDays)}]

  if r?.transitionDays != Undefined and r?.transitionStorageClass != Undefined:
    _rules += [{
      action = {$type = "SetStorageClass", storageClass = _storage_class[r.transitionStorageClass]}
      condition = _cond(r.transitionDays)
    }]

  _rules
}

render = lambda oxr {
  _spec = oxr.spec
  _versioning = _spec?.versioning
  if _versioning == Undefined:
    _versioning = True

  _block = _spec?.blockPublicAccess
  if _block == Undefined:
    _block = True

  _uniform = _spec?.uniformAccess
  if _uniform == Undefined:
    _uniform = True

  _del = _spec?.deletionPolicy or "Delete"

  # Import: adopt an existing GCS bucket. Its name is the provider identifier,
  # so pinning crossplane.io/external-name is the whole adoption; observe mode
  # keeps Crossplane read-only until the old tool has let go.
  _imp = _spec?.$import
  _existing = _imp?.existingName
  _observe = _existing and (_imp?.mode or "observe") == "observe"
  _mp = ["Observe"] if _observe else (_orphan_policies if _del == "Orphan" else Undefined)
  _pcr = provider_config_ref(oxr)
  _annos = {"krm.kcl.dev/composition-resource-name" = "managed"}
  if _existing:
    _annos |= {"crossplane.io/external-name" = _existing}

  if _imp?.source:
    _annos |= {"cloud.example.org/imported-from" = _imp.source}

  if _imp?.address:
    _annos |= {"cloud.example.org/import-address" = _imp.address}

  # Native lifecycle = storageClass tier transition + any explicit rules.
  _lifecycle: [any] = []
  _sc = _spec?.storageClass
  if _sc and _sc != "standard":
    _lifecycle += [{
      action = {$type = "SetStorageClass", storageClass = _storage_class[_sc]}
      condition = {age = 0, sendAgeIfZero = True}
    }]

  _lifecycle += [_x for _r in (_spec?.lifecycleRules or []) for _x in _gcp_lifecycle(_r)]

  [backend.Bucket {
    metadata.annotations = _annos
    if _mp:
      spec.managementPolicies = _mp
    if _pcr:
      spec.providerConfigRef = _pcr
    spec.forProvider.location = _spec.region
    spec.forProvider.forceDestroy = _spec?.forceDestroy or False
    spec.forProvider.versioning = {enabled = _versioning}
    spec.forProvider.uniformBucketLevelAccess = _uniform
    spec.forProvider.publicAccessPrevention = "enforced" if _block else "inherited"
    spec.forProvider.requesterPays = _spec?.requesterPays or False
    if _sc:
      spec.forProvider.storageClass = _storage_class[_sc]
    if _spec?.tags:
      spec.forProvider.labels = _spec.tags
    if _spec?.encryptionKmsKeyId:
      spec.forProvider.encryption = {defaultKmsKeyName = _spec.encryptionKmsKeyId}
    if _spec?.retention:
      spec.forProvider.retentionPolicy = {
        retentionPeriod = _spec.retention.days * 86400
        isLocked = (_spec.retention?.mode or "governance") == "compliance"
      }
    if _spec?.logging:
      spec.forProvider.logging = {
        logBucket = _spec.logging.targetBucket
        if _spec.logging?.targetPrefix:
          logObjectPrefix = _spec.logging.targetPrefix
      }
    if _spec?.website:
      spec.forProvider.website = {
        mainPageSuffix = _spec.website?.indexDocument or "index.html"
        if _spec.website?.errorDocument:
          notFoundPage = _spec.website.errorDocument
      }
    if _spec?.cors:
      spec.forProvider.cors = [{
        origin = _c.origins
        method = _c.methods
        responseHeader = _c?.headers or []
        maxAgeSeconds = _c?.maxAgeSeconds or 3600
      } for _c in _spec.cors]
    if _lifecycle:
      spec.forProvider.lifecycleRule = _lifecycle
  }]
}

# spec.access -> one BucketIAMMember per member of each entry. The members
# live in workload identity pools of federation.gcpProjectNumber, named by the
# same binding (fed.pool_id): the pool and its provider condition (owner,
# workflows, ticket trigger) must already exist there, e.g. composed by a
# GcpProject from the same entry. Nothing here depends on observed state.
render_access = lambda oxr, ocds -> [any] {
  _spec = oxr.spec
  _access = fed.access_list(_spec?.access or [])
  _fed = _spec?.federation or {}
  assert not _access or _fed?.gcpProjectNumber, "bucket-gcp: spec.federation.gcpProjectNumber is required with spec.access — the project whose workload identity pools the members name"
  assert not _fed?.awsAccountId and not _fed?.awsPermissionsBoundary and not _fed?.azureResourceGroup, "bucket-gcp: spec.federation.awsAccountId / awsPermissionsBoundary / azureResourceGroup are not GCP fields — set gcpProjectNumber"
  _imp = _spec?.$import
  assert not _access or not _imp?.existingName or _imp?.mode == "manage", "bucket-gcp: spec.access writes the bucket's IAM, but import.mode observe promises Crossplane never writes — set import.mode manage or drop access"
  _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
  _pcr = provider_config_ref(oxr)
  [iammember.BucketIAMMember {
    metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "access-${fed.access_name(_a)}-${crypto.sha256(_m)[:8]}"}
    if _mp:
      spec.managementPolicies = _mp
    if _pcr:
      spec.providerConfigRef = _pcr
    if _imp?.existingName:
      spec.forProvider.bucket = _imp.existingName
    else:
      spec.forProvider.bucketSelector.matchControllerRef = True
    spec.forProvider.role = _access_roles[_a.role]
    spec.forProvider.member = _m
  } for _a in _access for _m in fed.gcp_members(_a, _fed.gcpProjectNumber)]
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
  _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
  _spec_access = fed.access_list(oxr.spec?.access or [])
  _name = (_at?.id) or oxr.spec?.$import?.existingName or oxr.metadata.name
  _dxr = {
    apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
    kind = oxr?.kind or "Bucket"
    metadata.name = oxr.metadata.name
    status = {
      provider = "gcp"
      mode = mode_of(oxr)
      ready = _at != Undefined and (_at?.id or "") != ""
      bucketName = _name
      "cloud-url" = "https://console.cloud.google.com/storage/browser/${_name}"
      endpoint = "${_name}.storage.googleapis.com"
      if _at:
        if _at?.url:
          url = _at.url
        if _at?.selfLink:
          selfLink = _at.selfLink
        if _at?.id:
          id = _at.id
        if _at?.location:
          region = _at.location
        if _at?.storageClass:
          storageClass = _at.storageClass
      if _spec_access:
        access = [{name = fed.access_name(_a), role = _a.role, members = fed.gcp_members(_a, oxr.spec.federation.gcpProjectNumber)} for _a in _spec_access]
    }
  }
  _dxr
}
