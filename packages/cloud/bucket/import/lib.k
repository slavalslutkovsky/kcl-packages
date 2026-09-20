"""
bucket-import — reads what Terraform or Pulumi knows about a bucket and writes
the `Bucket` XR that adopts it (spec.import), in the XRD's own field names.

Two readers, one mapper:

  terraform_records(state)  raw `terraform.tfstate` (v4) OR `terraform show -json`
  pulumi_records(export)    `pulumi stack export`
  buckets(records)          -> [Found]   one per bucket, companions folded in
  to_xr(found, opts)        -> Bucket    typed against bucket-xrd, so a value the
                                         XRD would reject fails here first

Terraform spells nested blocks as single-element lists in snake_case; Pulumi
spells the same things as camelCase objects. `_g` looks a field up under every
spelling it has and `_one` unwraps the list-of-one, so the mapper below is
written once. Anything that cannot be said in the portable schema — a disabled
lifecycle rule, INTELLIGENT_TIERING, a versions-based condition — is dropped
AND named in `Found.notes`, which lands on the XR as an annotation. A silent
drop would look like a clean migration and be a wrong one.
"""

# ---- schema -----------------------------------------------------------------
schema Found:
    """One bucket the old tool manages, in portable terms."""
    provider: "aws" | "gcp" | "azure"
    # Exact cloud name; becomes spec.import.existingName.
    name: str
    # Where it lives in the old tool: a Terraform address or a Pulumi URN.
    address: str
    # Bucket XR spec fields that the state could speak for (never import/crossplane).
    spec: {str:any}
    # Azure only — the resource group the ARM id needs.
    resourceGroup?: str
    # Addresses of the S3 companions folded in — `terraform state rm` / `pulumi
    # state delete` must take these too, or the old tool recreates them.
    companions: [str] = []
    # What was dropped on the way, one line each.
    notes: [str] = []

schema Record:
    """One resource out of a state file, before it is joined to its bucket."""
    provider: "aws" | "gcp" | "azure"

    # bucket | versioning | publicaccessblock | ... (see _roles) — the S3 companion
    # resource kinds, spelled without separators so Terraform and Pulumi agree.
    role: str
    # The bucket it belongs to (its own name for role=bucket).
    key: str
    address: str
    attrs: {str:any}

# ---- lookup helpers ---------------------------------------------------------

# First present, non-null value among the spellings of one field.
_g = lambda d: any, keys: [str] -> any {
    _hits = [d[k] for k in keys if d and k in d and d[k] != None]
    _hits[0] if _hits else Undefined
}

# Terraform's block-as-list-of-one -> the block; Pulumi's object passes through.
_one = lambda v: any -> any {
    (v[0] if len(v) > 0 else Undefined) if typeof(v) == "list" else v
}

# ---- roles ------------------------------------------------------------------

# The S3 companion kinds this package folds into a Bucket, by their name with
# every separator removed: Terraform `aws_s3_bucket_public_access_block` and
# Pulumi `aws:s3/bucketPublicAccessBlock:BucketPublicAccessBlock` both become
# `publicaccessblock`. Anything else under aws_s3_bucket_* (policy, acl, an
# object, notification, ...) is not a portable Bucket concern and is reported.
_roles = ["bucket", "versioning", "publicaccessblock", "ownershipcontrols", "serversideencryptionconfiguration", "lifecycleconfiguration", "objectlockconfiguration", "corsconfiguration", "logging", "websiteconfiguration", "requestpaymentconfiguration"]

# Terraform resource type -> (provider, role), or Undefined for a type this
# package does not read.
_tf_role = lambda t: str -> any {
    _r = Undefined
    if t == "aws_s3_bucket":
        _r = {provider = "aws", role = "bucket"}
    elif t.startswith("aws_s3_bucket_"):
        _r = {provider = "aws", role = t[len("aws_s3_bucket_")::].replace("_", "")}
    elif t == "google_storage_bucket":
        _r = {provider = "gcp", role = "bucket"}
    elif t == "azurerm_storage_account":
        _r = {provider = "azure", role = "bucket"}

    _r
}

# Pulumi type token -> (provider, role). `aws:s3/bucketVersioningV2:BucketVersioningV2`
# carries the kind between the slash and the colon; pulumi-aws v7 dropped the
# V2 suffixes, so both spellings map to the same role.
_pulumi_role = lambda t: str -> any {
    _r = Undefined
    if t.startswith("aws:s3/"):
        _tok = t[len("aws:s3/")::].split(":")[0]
        _tok = _tok[len("bucket")::] if _tok.startswith("bucket") else "?" + _tok
        _tok = _tok[:len(_tok) - 2:] if _tok.endswith("V2") else _tok
        _r = {provider = "aws", role = _tok.lower() if _tok else "bucket"}
    elif t == "gcp:storage/bucket:Bucket":
        _r = {provider = "gcp", role = "bucket"}
    elif t == "azure:storage/account:Account":
        _r = {provider = "azure", role = "bucket"}

    _r
}

# The bucket a record belongs to: its own name for the bucket itself, the
# `bucket` field for an S3 companion.
_key_of = lambda role: str, attrs: {str:any} -> str {
    (_g(attrs, ["bucket", "name"]) if role == "bucket" else _g(attrs, ["bucket"])) or ""
}

# ---- readers ----------------------------------------------------------------

# `terraform show -json`: values.root_module.resources[] with `address` and
# `values`, modules nested under child_modules[] (recursively).
_show_records = lambda mod: any -> [Record] {
    _own = [Record {
        provider = _tf_role(_r.type).provider
        role = _tf_role(_r.type).role
        key = _key_of(_tf_role(_r.type).role, _r.values)
        address = _r.address
        attrs = _r.values
    } for _r in (mod?.resources or []) if _r?.mode == "managed" and _tf_role(_r.type) != Undefined]
    _own + [_x for _m in (mod?.child_modules or []) for _x in _show_records(_m)]
}

# Raw tfstate (v4): resources[] with `module`, `type`, `name` and instances[]
# holding `attributes` and, for count/for_each, an `index_key`.
_state_records = lambda state: any -> [Record] {
    [Record {
        provider = _tf_role(_r.type).provider
        role = _tf_role(_r.type).role
        key = _key_of(_tf_role(_r.type).role, _i.attributes)
        address = _tf_address(_r, _i)
        attrs = _i.attributes
    } for _r in (state?.resources or []) if (_r?.mode or "managed") == "managed" and _tf_role(_r.type) != Undefined for _i in (_r?.instances or [])]
}

# module.x.aws_s3_bucket.this["logs"] — the address `terraform state rm` takes.
_tf_address = lambda r: any, i: any -> str {
    _base = ((r.module + ".") if r?.module else "") + r.type + "." + r.name
    _k = i?.index_key
    _base if _k == Undefined else (_base + "[${_k}]" if typeof(_k) == "int" else _base + "[\"${_k}\"]")
}

# Every resource this package can read, from either Terraform JSON shape.
terraform_records = lambda state: any -> [Record] {
    _show_records(state.values.root_module) if state?.values?.root_module else _state_records(state)
}

# `pulumi stack export`: deployment.resources[] with `type`, `urn`, `outputs`.
pulumi_records = lambda export: any -> [Record] {
    [Record {
        provider = _pulumi_role(_r.type).provider
        role = _pulumi_role(_r.type).role
        key = _key_of(_pulumi_role(_r.type).role, _r?.outputs or {})
        address = _r.urn
        attrs = _r?.outputs or {}
    } for _r in (export?.deployment?.resources or []) if _pulumi_role(_r?.type or "") != Undefined and _r?.outputs]
}

# "terraform" or "pulumi", from the shape of the document.
detect = lambda doc: any -> str {
    "pulumi" if doc?.deployment != Undefined else "terraform"
}

records = lambda doc: any, source: str -> [Record] {
    pulumi_records(doc) if source == "pulumi" else terraform_records(doc)
}

# Resources the reader recognised as bucket-shaped but cannot fold in
# (aws_s3_bucket_policy, an acl, an object ...): reported, never guessed at.
skipped = lambda recs: [Record] -> [str] {
    [_r.address for _r in recs if _r.role not in _roles]
}

# ---- tier maps --------------------------------------------------------------

# S3 storage classes that the abstract tiers can express; the rest are noted.
_aws_tier = {"STANDARD_IA" = "nearline", "ONEZONE_IA" = "nearline", "GLACIER_IR" = "cold", "GLACIER" = "cold", "DEEP_ARCHIVE" = "archive"}
_gcp_tier = {"STANDARD" = "standard", "MULTI_REGIONAL" = "standard", "REGIONAL" = "standard", "NEARLINE" = "nearline", "COLDLINE" = "cold", "ARCHIVE" = "archive"}
_azure_tier = {"Hot" = "standard", "Cool" = "nearline", "Cold" = "cold"}

# ---- aws --------------------------------------------------------------------

# One S3 lifecycle rule (companion `rule`/`rules` entry, or the legacy inline
# `lifecycle_rule`) -> {rule, notes}. `rule` is Undefined when nothing portable
# is left of it.
_aws_rule = lambda r: any, legacy: bool -> any {
    _id = r?.id or "rule"
    _notes: [str] = []
    _enabled = (r?.enabled == True) if legacy else ((r?.status or "Enabled") == "Enabled")
    _prefix = (r?.prefix if legacy else _one(_g(r, ["filter", "filters"]))?.prefix) or ""
    _exp = _one(_g(r, ["expiration", "expirations"]))?.days
    _tr = _one(_g(r, ["transition", "transitions"]))
    _cls = _g(_tr or {}, ["storage_class", "storageClass"])
    _out = {id = _id, prefix = _prefix}
    if _exp:
        _out |= {expirationDays = _exp}

    if _tr and _tr?.days != Undefined and _cls in _aws_tier:
        _out |= {transitionDays = _tr.days, transitionStorageClass = _aws_tier[_cls]}
    elif _tr and _cls:
        _notes += ["lifecycle rule ${_id}: transition to ${_cls} has no portable tier, dropped"]

    _portable = "expirationDays" in _out or "transitionDays" in _out
    if not _enabled:
        _notes += ["lifecycle rule ${_id}: disabled in the old tool, dropped"]
    elif not _portable and not _notes:
        _notes += ["lifecycle rule ${_id}: only conditions the schema cannot express (noncurrent versions, dates, size, tags), dropped"]

    {rule = _out if (_enabled and _portable) else Undefined, notes = _notes}
}

_aws_spec = lambda b: {str:any}, c: {str:any} -> any {
    _notes: [str] = []
    _s = {region = _g(b, ["region"])}
    _tags = _g(b, ["tags"])
    if _tags:
        _s |= {tags = _tags}

    if _g(b, ["force_destroy", "forceDestroy"]) == True:
        _s |= {forceDestroy = True}

    # Versioning: the companion wins; else the legacy inline block; else off.
    _vc = _one(_g(c?.versioning or {}, ["versioning_configuration", "versioningConfiguration"]))
    _s |= {versioning = (_vc.status == "Enabled") if _vc else (_one(_g(b, ["versioning", "versionings"]))?.enabled == True)}

    _pab = c?.publicaccessblock
    if _pab:
        _s |= {blockPublicAccess = all k in ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"] {_g(_pab, [k, _camel(k)]) == True}}
        if not _s.blockPublicAccess and any k in ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"] {_g(_pab, [k, _camel(k)]) == True}:
            _notes += ["public access block is partial in the old tool; blockPublicAccess is all-or-nothing, set false"]


    _own = _one(_g(c?.ownershipcontrols or {}, ["rule", "rules"]))
    if _own:
        _s |= {uniformAccess = _g(_own, ["object_ownership", "objectOwnership"]) == "BucketOwnerEnforced"}

    # SSE: KMS keys are portable; SSE-S3 (AES256) is what the composition leaves
    # the bucket at anyway, so it maps to "no key".
    _sse = _one(_g(c?.serversideencryptionconfiguration or {}, ["rule", "rules"])) or _one(_g(_one(_g(b, ["server_side_encryption_configuration", "serverSideEncryptionConfigurations"])) or {}, ["rule", "rules"]))
    _def = _one(_g(_sse or {}, ["apply_server_side_encryption_by_default", "applyServerSideEncryptionByDefault"]))
    _kms = _g(_def or {}, ["kms_master_key_id", "kmsMasterKeyId"])
    if _def and _g(_def, ["sse_algorithm", "sseAlgorithm"]) == "aws:kms" and _kms:
        _s |= {encryptionKmsKeyId = _kms}

    if (_g(c?.requestpaymentconfiguration or {}, ["payer"]) or _g(b, ["request_payer", "requestPayer"])) == "Requester":
        _s |= {requesterPays = True}

    _lock = _one(_g(_one(_g(c?.objectlockconfiguration or {}, ["rule", "rules"])) or {}, ["default_retention", "defaultRetention"]))
    if _lock:
        _days = _lock?.days or ((_lock?.years or 0) * 365)
        if _days:
            _s |= {
                retention = {days = _days, mode = (_lock?.mode or "GOVERNANCE").lower()}
            }


    _log = c?.logging or _one(_g(b, ["logging", "loggings"]))
    _target = _g(_log or {}, ["target_bucket", "targetBucket"])
    if _target:
        _s |= {logging = {targetBucket = _target} | ({targetPrefix = _g(_log, ["target_prefix", "targetPrefix"])} if _g(_log, ["target_prefix", "targetPrefix"]) else {})}

    _web = c?.websiteconfiguration
    _web_legacy = _one(_g(b, ["website", "websites"]))
    if _web:
        _s |= {website = {indexDocument = _one(_g(_web, ["index_document", "indexDocument"]))?.suffix or "index.html"} | ({errorDocument = _one(_g(_web, ["error_document", "errorDocument"])).key} if _one(_g(_web, ["error_document", "errorDocument"]))?.key else {})}
    elif _web_legacy and _g(_web_legacy, ["index_document", "indexDocument"]):
        _s |= {website = {indexDocument = _g(_web_legacy, ["index_document", "indexDocument"])} | ({errorDocument = _g(_web_legacy, ["error_document", "errorDocument"])} if _g(_web_legacy, ["error_document", "errorDocument"]) else {})}

    _cors = _g(c?.corsconfiguration or {}, ["cors_rule", "corsRules"]) or _g(b, ["cors_rule", "corsRules"])
    if _cors:
        _s |= {cors = [{
            origins = _g(_r, ["allowed_origins", "allowedOrigins"]) or []
            methods = _g(_r, ["allowed_methods", "allowedMethods"]) or []
            headers = _g(_r, ["allowed_headers", "allowedHeaders"]) or []
            maxAgeSeconds = _g(_r, ["max_age_seconds", "maxAgeSeconds"]) or 3600
        } for _r in _cors]}

    _lc = c?.lifecycleconfiguration
    _rules = [_aws_rule(_r, False) for _r in (_g(_lc or {}, ["rule", "rules"]) or [])] if _lc else [_aws_rule(_r, True) for _r in (_g(b, ["lifecycle_rule", "lifecycleRules"]) or [])]
    _kept = [_r.rule for _r in _rules if _r.rule]
    _notes += [_n for _r in _rules for _n in _r.notes]
    if _kept:
        _s |= {lifecycleRules = _kept}

    {spec = _s, notes = _notes}
}

# snake_case -> camelCase, for the field names Pulumi spells differently.
_camel = lambda k: str -> str {
    _parts = k.split("_")
    _parts[0] + "".join([_p.capitalize() for _p in _parts[1::]])
}

# ---- gcp --------------------------------------------------------------------
_gcp_spec = lambda b: {str:any} -> any {
    _notes: [str] = []
    _tier = _gcp_tier[_g(b, ["storage_class", "storageClass"]) or "STANDARD"]
    _s = {region = _g(b, ["location"]), storageClass = _tier}
    _s |= {versioning = _one(_g(b, ["versioning", "versionings"]))?.enabled == True}
    if _g(b, ["force_destroy", "forceDestroy"]) == True:
        _s |= {forceDestroy = True}

    _ubla = _g(b, ["uniform_bucket_level_access", "uniformBucketLevelAccess"])
    if _ubla != Undefined:
        _s |= {uniformAccess = _ubla == True}

    _pap = _g(b, ["public_access_prevention", "publicAccessPrevention"])
    if _pap:
        _s |= {blockPublicAccess = _pap == "enforced"}

    if _g(b, ["requester_pays", "requesterPays"]) == True:
        _s |= {requesterPays = True}

    _labels = _g(b, ["labels"])
    if _labels:
        _s |= {tags = _labels}

    _kms = _g(_one(_g(b, ["encryption", "encryptions"])) or {}, ["default_kms_key_name", "defaultKmsKeyName"])
    if _kms:
        _s |= {encryptionKmsKeyId = _kms}

    _ret = _one(_g(b, ["retention_policy", "retentionPolicy"]))
    _period = _g(_ret or {}, ["retention_period", "retentionPeriod"])
    if _period:
        _days = int(_period / 86400)
        if _days * 86400 != _period:
            _notes += ["retention period ${_period}s is not whole days, rounded down to ${_days}"]

        if _days >= 1:
            _s |= {
                retention = {days = _days, mode = "compliance" if _g(_ret, ["is_locked", "isLocked"]) == True else "governance"}
            }


    _log = _one(_g(b, ["logging", "loggings"]))
    _target = _g(_log or {}, ["log_bucket", "logBucket"])
    if _target:
        _s |= {logging = {targetBucket = _target} | ({targetPrefix = _g(_log, ["log_object_prefix", "logObjectPrefix"])} if _g(_log, ["log_object_prefix", "logObjectPrefix"]) else {})}

    _web = _one(_g(b, ["website", "websites"]))
    _index = _g(_web or {}, ["main_page_suffix", "mainPageSuffix"])
    if _index:
        _s |= {website = {indexDocument = _index} | ({errorDocument = _g(_web, ["not_found_page", "notFoundPage"])} if _g(_web, ["not_found_page", "notFoundPage"]) else {})}

    _cors = _g(b, ["cors"])
    if _cors:
        _s |= {cors = [{
            origins = _g(_r, ["origin", "origins"]) or []
            methods = _g(_r, ["method", "methods"]) or []
            headers = _g(_r, ["response_header", "responseHeaders"]) or []
            maxAgeSeconds = _g(_r, ["max_age_seconds", "maxAgeSeconds"]) or 3600
        } for _r in _cors]}

    # Native rules: a SetStorageClass at age 0 to the bucket's own tier is the
    # composition's tier injection and folds back into storageClass; the rest
    # become one abstract rule each, or a note when they hinge on a condition
    # the schema cannot express.
    _native = _g(b, ["lifecycle_rule", "lifecycleRules"]) or []
    _mapped = [_gcp_rule(_native[_i], _i, _tier) for _i in range(len(_native))]
    _kept = [_m.rule for _m in _mapped if _m.rule]
    _notes += [_n for _m in _mapped for _n in _m.notes]
    if _kept:
        _s |= {lifecycleRules = _kept}

    {spec = _s, notes = _notes}
}

_gcp_rule = lambda r: any, i: int, tier: str -> any {
    _a = _one(_g(r, ["action", "actions"])) or {}
    _c = _one(_g(r, ["condition", "conditions"])) or {}
    _type = _g(_a, ["type"])
    _age = _g(_c, ["age"])
    _cls = _g(_a, ["storage_class", "storageClass"])
    _prefixes = _g(_c, ["matches_prefix", "matchesPrefixes"]) or []
    _id = "rule-${i + 1}"
    _base = {id = _id} | ({prefix = _prefixes[0]} if _prefixes else {})
    _out = Undefined
    _notes: [str] = []
    if _type == "SetStorageClass" and (_age or 0) == 0 and _cls in _gcp_tier and _gcp_tier[_cls] == tier:
        # the tier itself, already spec.storageClass
        _out = Undefined
    elif _age == Undefined or _age == None:
        _notes += ["lifecycle rule ${_id}: no age condition (versions, dates or state instead), dropped"]
    elif _type == "Delete":
        _out = _base | {expirationDays = _age}
    elif _type == "SetStorageClass" and _cls in _gcp_tier:
        _out = _base | {transitionDays = _age, transitionStorageClass = _gcp_tier[_cls]}
    else:
        _notes += ["lifecycle rule ${_id}: action ${_type} to ${_cls} is not portable, dropped"]
    if len(_prefixes) > 1:
        _notes += ["lifecycle rule ${_id}: matches ${len(_prefixes)} prefixes, only the first is kept"]

    {rule = _out, notes = _notes}
}

# ---- azure ------------------------------------------------------------------
_azure_spec = lambda b: {str:any} -> any {
    _tier = _g(b, ["access_tier", "accessTier"]) or "Hot"
    _s = {region = _g(b, ["location"]), storageClass = _azure_tier[_tier] if _tier in _azure_tier else "standard"}
    _tags = _g(b, ["tags"])
    if _tags:
        _s |= {tags = _tags}

    {spec = _s, notes = ([] if _tier in _azure_tier else ["access tier ${_tier} has no portable tier, left at standard"])}
}

# ---- fold -------------------------------------------------------------------

# Every bucket in the records, with its companions folded in. Order follows
# the state file, so the output is stable across runs.
buckets = lambda recs: [Record] -> [Found] {
    _roots = [_r for _r in recs if _r.role == "bucket"]
    [_fold(_b, [_c for _c in recs if _c.provider == _b.provider and _c.role != "bucket" and _c.role in _roles and _c.key == _b.key]) for _b in _roots]
}

_fold = lambda b: Record, cs: [Record] -> Found {
    _c = {_x.role = _x.attrs for _x in cs}
    _m = _aws_spec(b.attrs, _c) if b.provider == "aws" else (_gcp_spec(b.attrs) if b.provider == "gcp" else _azure_spec(b.attrs))
    Found {
        provider = b.provider
        name = b.key
        address = b.address
        spec = _m.spec
        if b.provider == "azure":
            resourceGroup = _g(b.attrs, ["resource_group_name", "resourceGroupName"])
        companions = [_x.address for _x in cs]
        notes = _m.notes
    }
}

# ---- xr ---------------------------------------------------------------------

# A DNS-1123 label out of a cloud name: S3 allows dots, Terraform's random
# suffixes are fine, uppercase is not.
k8s_name = lambda name: str -> str {
    _chars = [c if c in "abcdefghijklmnopqrstuvwxyz0123456789-" else "-" for c in name.lower()]
    _n = "".join(_chars).strip("-")
    _n[:63:].rstrip("-")
}

schema Options:
    namespace: str = "default"
    mode: "observe" | "manage" = "observe"
    deletionPolicy: "Delete" | "Orphan" = "Orphan"
    source: "terraform" | "pulumi" | "other" = "terraform"

# The Bucket XR that adopts one Found: the state's portable fields, plus the
# import block that pins the real name. Kept as a plain dict here — main.k
# instantiates the generated Bucket schema over it, so the XRD validates the
# result without this file depending on the models package for its tests.
xr = lambda f: Found, o: Options -> {str:any} {
    _imp = {existingName = f.name, mode = o.mode, source = o.source, address = f.address}
    if f?.resourceGroup:
        _imp |= {resourceGroup = f.resourceGroup}

    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "Bucket"
        metadata = {
            name = k8s_name(f.name)
            namespace = o.namespace
            if f.notes:
                annotations = {"cloud.example.org/import-notes" = "; ".join(f.notes)}
        }
        spec = f.spec | {
            deletionPolicy = o.deletionPolicy
            import = _imp
            crossplane.compositionSelector.matchLabels.provider = f.provider
        }
    }
}
