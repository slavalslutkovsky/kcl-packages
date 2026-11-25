# backup (gcp) — Crossplane Composition logic (function-kcl module).
# Backup for GKE is a managed service: the plan is ONE resource, a
# BackupBackupPlan bound to a GKE cluster, and Google runs the schedule and
# keeps the backups in its own storage. There is no bucket, no vault and no
# in-cluster operator to compose — the backup agent is a GKE add-on
# (gkeBackupAgentConfig) that has to be enabled on the cluster itself, which
# this XR does not own (see the README).
#
# Typed against the gcp-gke schema package (provider-gcp-gke, namespaced
# `.m.` API group, so the MR lands in the XR's own namespace).
import gcp_gke.models.v1beta1.gke_gcpm_upbound_io_v1beta1_backup_backup_plan as gke

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# The XRD documents the cron shorthands, but the Backup for GKE API only
# documents "a standard cron string" (five fields, interpreted in UTC), so they
# are spelled out rather than trusted to its parser. @reboot and @every have no
# five-field form and fail the render.
_shorthands = {
    "@hourly" = "0 * * * *"
    "@daily" = "0 0 * * *"
    "@midnight" = "0 0 * * *"
    "@weekly" = "0 0 * * 0"
    "@monthly" = "0 0 1 * *"
    "@yearly" = "0 0 1 1 *"
    "@annually" = "0 0 1 1 *"
}

cron_for = lambda schedule: str -> str {
    _s = schedule.strip()
    _cron = _shorthands[_s] if _s in _shorthands else _s
    # Collapse runs of whitespace so the API sees canonical single-spaced fields.
    _fields = [_f for _f in _cron.split(" ") if _f]
    assert len(_fields) == 5, "backup-gcp: schedule \"${schedule}\" is not a five-field cron expression (or @hourly/@daily/@weekly/@monthly), which is all Backup for GKE accepts"
    " ".join(_fields)
}

# backupRetainDays is documented as an integer in 0..365; anything longer would
# be rejected by the API after the XR already looked accepted.
_max_retain_days = 365

# The API also caps backupRetainDays at 360 x the schedule's creation interval
# (so an hourly plan keeps at most 15 days, a daily one 360). That interval is
# only knowable for the regular shapes below — "every N minutes", "every N
# hours" and "once a day" — anything else (day-of-week, day-of-month, lists)
# returns 0 and is left to the API to judge.
interval_minutes = lambda cron: str -> int {
    _f = cron.split(" ")
    _m = _f[0]
    _h = _f[1]
    _step_m = _m.startswith("*/") and _m[2:].isdigit()
    _step_h = _h.startswith("*/") and _h[2:].isdigit()
    _cases = [
        {hit = _m == "*" and _h == "*", minutes = 1}
        {hit = _step_m and _h == "*", minutes = int(_m[2:]) if _step_m else 0}
        {hit = _m.isdigit() and _h == "*", minutes = 60}
        {hit = _m.isdigit() and _step_h, minutes = 60 * int(_h[2:]) if _step_h else 0}
        {hit = _m.isdigit() and _h.isdigit(), minutes = 1440}
    ]
    _hits = [_c.minutes for _c in _cases if _c.hit]
    _hits[0] if _hits and _f[2] == "*" and _f[3] == "*" and _f[4] == "*" else 0
}

max_retain_days = lambda cron: str -> int {
    _i = interval_minutes(cron)
    _cap = 360 * _i // 1440 if _i > 0 else _max_retain_days
    _cap if _cap < _max_retain_days else _max_retain_days
}

# A GKE cluster's full name is projects/<project>/locations/<location>/clusters/<name>.
parse_cluster_id = lambda id: str -> {str:str} {
    _p = id.split("/")
    assert len(_p) == 6 and _p[0] == "projects" and _p[2] == "locations" and _p[4] == "clusters" and all _x in _p {
        _x != ""
    }, "backup-gcp: spec.cluster.id must be projects/<project>/locations/<location>/clusters/<name>, got \"${id}\""
    {project = _p[1], location = _p[3], name = _p[5]}
}

# Backup for GKE plans live in a REGION, but a zonal GKE cluster's location is
# a zone (us-central1-a). GCP region names have exactly one dash
# (us-central1, northamerica-northeast1) and zones add a "-<letter>" suffix, so
# a second dash marks a zone and the region is everything before the last one.
region_for = lambda location: str -> str {
    _parts = location.split("-")
    "-".join(_parts[:2]) if len(_parts) > 2 else location
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    assert _spec?.cluster?.id, "backup-gcp: spec.cluster.id is required — the GKE cluster (projects/<project>/locations/<location>/clusters/<name>) the plan backs up"
    _cluster = parse_cluster_id(_spec.cluster.id)

    _cron = cron_for(_spec.schedule)
    _retain = _spec?.retentionDays or 30
    _cap = max_retain_days(_cron)
    assert _retain <= _cap, "backup-gcp: retentionDays ${_retain} exceeds the ${_cap} days Backup for GKE allows for schedule \"${_cron}\" (at most 365, and at most 360 x the backup interval)"

    # Tri-state: absent must mean the XRD default, and `or` would turn an
    # explicit false into it.
    _volumes = _spec?.snapshotVolumes
    if _volumes == Undefined:
        _volumes = True

    _namespaces = _spec?.includedNamespaces or []

    # Backup for GKE has no resource-type filter; the only type it can leave
    # out is Secrets, through a dedicated flag.
    _secrets = "secrets" not in (_spec?.excludedResources or [])

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    [gke.BackupBackupPlan {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            # forProvider has no name field: upjet takes the plan's name from the
            # external name, so pin it to the XR's rather than to the
            # MR's generated one.
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            # The full cluster name, verbatim — the API wants exactly this form.
            cluster = _spec.cluster.id
            project = _cluster.project
            location = region_for(_cluster.location)
            backupSchedule = {
                cronSchedule = _cron
                paused = _spec?.paused or False
            }
            # Always set: the API requires backupRetainDays whenever
            # cronSchedule is, and without it backups are never deleted.
            retentionPolicy.backupRetainDays = _retain
            backupConfig = {
                # Exactly one scope is allowed; an empty list means every
                # namespace to this XR, which the API spells allNamespaces.
                if _namespaces:
                    selectedNamespaces.namespaces = _namespaces
                else:
                    allNamespaces = True
                includeVolumeData = _volumes
                includeSecrets = _secrets
                # Encrypts the config portion (the Kubernetes objects); volume
                # data keeps the encryption of the disks it was snapshotted from.
                if _spec?.encryptionKmsKeyId:
                    encryptionKey.gcpKmsEncryptionKey = _spec.encryptionKmsKeyId
            }
            if _spec?.tags:
                labels = _spec.tags
        }
    }]
}

# Build the desired composite carrying observed status back to the XR.
# One composed MR, so readiness is its Ready condition — but upjet sets Ready
# as soon as the plan EXISTS, and a plan on a cluster without the backup agent
# add-on sits in CLUSTER_PENDING taking no backups. The XRD promises ready
# means "capable of taking a backup", so a reported state must also be READY.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _obs = (ocds["managed"]?.Resource?.status) if ("managed" in ocds) else Undefined
    _at = _obs?.atProvider

    _ready_cond = [_c for _c in (_obs?.conditions or []) if _c?.type == "Ready"]
    _cond_ok = len(_ready_cond) > 0 and _ready_cond[0]?.status == "True"
    _state = _at?.state or ""
    _ready = _cond_ok and _state in ["", "READY"]

    # The plan's id is fully derivable from the XR before anything reconciles;
    # prefer the observed one once the provider reports it.
    _cluster_id = oxr.spec?.cluster?.id or ""
    _cp = _cluster_id.split("/")
    _derived = "projects/${_cp[1]}/locations/${region_for(_cp[3])}/backupPlans/${_name}" if len(_cp) == 6 else ""
    _location = _at?.id or _derived

    _cond_msg = (_ready_cond[0]?.message or "not Ready") if _ready_cond else "not Ready"
    _reason = (": " + _at.stateReason) if _at?.stateReason else ""
    _not_ready = "BackupBackupPlan managed: ${_cond_msg}" if not _cond_ok else "BackupBackupPlan managed: plan is ${_state}${_reason}"
    _message = "" if _ready else _not_ready

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "BackupPlan"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = _ready
            if _location:
                storageLocation = _location
            if _state:
                phase = _state
            if _message:
                message = _message
        }
    }
}
