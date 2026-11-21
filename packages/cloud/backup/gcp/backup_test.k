import runtime
import .backup

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "BackupPlan", metadata = {name = "nightly", namespace = "default"}, spec = _spec}
}

_cluster_id = "projects/acme-prod/locations/europe-west1/clusters/main"
# The minimum a gcp BackupPlan needs: when, and which cluster.
_minimal = {schedule = "0 2 * * *", cluster = {id = _cluster_id}}

_plan = lambda _spec {
    backup.render(_build(_spec))[0]
}

_fp = lambda _spec {
    _plan(_spec).spec.forProvider
}

# runtime.catch returns the assertion message, or nothing when the render succeeds.
_fails = lambda _spec {
    runtime.catch(lambda {
        backup.render(_build(_spec))
    })
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = backup.render(_build(_minimal))
    assert len(items) == 1, "Backup for GKE is one managed resource"
    _p = items[0]
    assert _p.apiVersion == "gke.gcp.m.upbound.io/v1beta1", "must be the namespaced provider-gcp-gke API group"
    assert _p.kind == "BackupBackupPlan", "wrong kind for the plan"
    assert _p.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "the plan must be named for status lookups"
    assert _p.metadata.annotations["crossplane.io/external-name"] == "nightly", "the plan's GCP name must be pinned to the XR name"
    assert _p.spec.managementPolicies == ["*"], "Delete is the default lifecycle"
    assert _p.spec?.providerConfigRef == Undefined, "providerConfigRef stays at the schema default"
    _f = _p.spec.forProvider
    assert _f.cluster == _cluster_id, "the cluster's full name must pass through verbatim"
    assert _f.project == "acme-prod", "project comes from the cluster id"
    assert _f.location == "europe-west1", "a regional cluster's location is already a region"
    assert _f.backupSchedule.cronSchedule == "0 2 * * *", "a five-field cron must reach the API verbatim"
    assert _f.backupSchedule.paused == False, "a plan runs unless it is paused"
    assert _f.retentionPolicy.backupRetainDays == 30, "retentionDays defaults to 30"
    assert _f.backupConfig.allNamespaces == True, "empty includedNamespaces means every namespace"
    assert _f.backupConfig?.selectedNamespaces == Undefined, "allNamespaces and selectedNamespaces are mutually exclusive"
    assert _f.backupConfig.includeVolumeData == True, "snapshotVolumes defaults to true"
    assert _f.backupConfig.includeSecrets == True, "Secrets are backed up unless excluded"
    assert _f.backupConfig?.encryptionKey == Undefined, "no CMEK unless asked for"
    assert _f?.labels == Undefined, "no labels unless asked for"
}

# ---- render: cluster --------------------------------------------------------
test_cluster_id_parsing = lambda {
    assert backup.parse_cluster_id(_cluster_id) == {project = "acme-prod", location = "europe-west1", name = "main"}, "the id must split into project, location and name"
    assert backup.region_for("us-central1") == "us-central1", "a region stays a region"
    assert backup.region_for("us-central1-a") == "us-central1", "a zone maps to its region"
    assert backup.region_for("northamerica-northeast1-b") == "northamerica-northeast1", "multi-part region names must survive"
    _zonal = _fp({schedule = "0 2 * * *", cluster = {id = "projects/acme-dev/locations/us-central1-a/clusters/dev"}})
    assert _zonal.location == "us-central1", "Backup for GKE plans live in a region, even for a zonal cluster"
    assert _zonal.cluster == "projects/acme-dev/locations/us-central1-a/clusters/dev", "the cluster keeps its zonal full name"
    assert _zonal.project == "acme-dev", "project comes from the cluster id"
}

test_cluster_required = lambda {
    _missing = _fails({schedule = "0 2 * * *"})
    assert not _fails(_minimal), "a well-formed plan must render"
    assert _missing and "backup-gcp:" in _missing and "spec.cluster.id" in _missing, "a gcp plan without a cluster must fail the render"
    _bad = _fails({schedule = "0 2 * * *", cluster = {id = "main"}})
    assert _bad and "backup-gcp:" in _bad, "a bare cluster name must fail the render"
    _arn = _fails({schedule = "0 2 * * *", cluster = {id = "projects/p/zones/us-central1-a/clusters/main"}})
    assert _arn and "projects/<project>/locations/<location>/clusters/<name>" in _arn, "only the locations/ form is a GKE full name"
}

# ---- render: schedule -------------------------------------------------------
test_schedule_shorthands = lambda {
    assert _fp(_minimal | {schedule = "@hourly", retentionDays = 7}).backupSchedule.cronSchedule == "0 * * * *", "@hourly must be spelled out"
    assert _fp(_minimal | {schedule = "@daily"}).backupSchedule.cronSchedule == "0 0 * * *", "@daily must be spelled out"
    assert _fp(_minimal | {schedule = "@weekly"}).backupSchedule.cronSchedule == "0 0 * * 0", "@weekly must be spelled out"
    assert _fp(_minimal | {schedule = "@monthly"}).backupSchedule.cronSchedule == "0 0 1 * *", "@monthly must be spelled out"
    assert _fp(_minimal | {schedule = " 0  2 * * * "}).backupSchedule.cronSchedule == "0 2 * * *", "whitespace must be normalised"
    _bad = _fails(_minimal | {schedule = "@reboot"})
    assert _bad and "backup-gcp:" in _bad, "a schedule with no five-field form must fail the render"
    assert _fails(_minimal | {schedule = "0 2 * *"}), "a four-field cron must fail the render"
}

test_pause = lambda {
    assert _fp(_minimal | {paused = True}).backupSchedule.paused == True, "paused must stop new backups without deleting the plan"
}

# ---- render: retention ------------------------------------------------------
test_retention = lambda {
    assert _fp(_minimal | {retentionDays = 7}).retentionPolicy.backupRetainDays == 7, "retentionDays must pass through"
    assert _fp(_minimal | {schedule = "@weekly", retentionDays = 365}).retentionPolicy.backupRetainDays == 365, "365 is the documented maximum"
    _over = _fails(_minimal | {schedule = "@weekly", retentionDays = 366})
    assert _over and "backup-gcp:" in _over, "retention past 365 days must fail the render"
    _daily = _fails(_minimal | {retentionDays = 361})
    assert _daily and "360" in _daily, "a daily plan keeps at most 360 backups' worth of days"
    _hourly = _fails(_minimal | {schedule = "@hourly"})
    assert _hourly and "15 days" in _hourly, "an hourly plan keeps at most 15 days — the default 30 must fail"
    assert _fp(_minimal | {schedule = "0 */6 * * *", retentionDays = 90}).retentionPolicy.backupRetainDays == 90, "every 6 hours allows 90 days"
    assert _fails(_minimal | {schedule = "0 */6 * * *", retentionDays = 91}), "every 6 hours allows no more than 90 days"
    assert backup.interval_minutes("15 3 * * 1") == 0, "irregular shapes are left to the API"
}

# ---- render: backup scope ---------------------------------------------------
test_namespaces = lambda {
    _c = _fp(_minimal | {includedNamespaces = ["zerg", "dbs"]}).backupConfig
    assert _c.selectedNamespaces.namespaces == ["zerg", "dbs"], "includedNamespaces must narrow the backup"
    assert _c?.allNamespaces == Undefined, "allNamespaces and selectedNamespaces are mutually exclusive"
    assert _fp(_minimal | {includedNamespaces = []}).backupConfig.allNamespaces == True, "an explicit empty list still means every namespace"
}

test_secrets_exclusion = lambda {
    assert _fp(_minimal | {excludedResources = ["events", "secrets"]}).backupConfig.includeSecrets == False, "excluding secrets must drop them"
    assert _fp(_minimal | {excludedResources = ["events", "events.events.k8s.io"]}).backupConfig.includeSecrets == True, "other exclusions are ignored"
}

test_volumes = lambda {
    assert _fp(_minimal | {snapshotVolumes = False}).backupConfig.includeVolumeData == False, "an explicit false must not be overridden by the default"
}

test_encryption = lambda {
    _key = "projects/acme-prod/locations/europe-west1/keyRings/backup/cryptoKeys/gke"
    assert _fp(_minimal | {encryptionKmsKeyId = _key}).backupConfig.encryptionKey.gcpKmsEncryptionKey == _key, "the CMEK must reach the backup config"
}

test_tags = lambda {
    assert _fp(_minimal | {tags = {team = "platform"}}).labels == {team = "platform"}, "tags label the plan"
}

# ---- render: lifecycle and ignored fields ----------------------------------
test_orphan = lambda {
    assert _plan(_minimal | {deletionPolicy = "Orphan"}).spec.managementPolicies == ["Observe", "Create", "Update", "LateInitialize"], "Orphan must drop Delete from the management policies"
    assert _plan(_minimal | {deletionPolicy = "Delete"}).spec.managementPolicies == ["*"], "Delete keeps full management"
}

test_ignored_fields = lambda {
    _ignored = _minimal | {
        labelSelector = {backup = "nightly"}
        includedResources = ["deployments.apps"]
        defaultVolumesToFsBackup = True
        destination = {provider = "gcp", bucket = "unused"}
        cluster = {id = _cluster_id, region = "unused", snapshotResourceGroup = "unused"}
    }
    assert backup.render(_build(_ignored)) == backup.render(_build(_minimal)), "fields Backup for GKE cannot express must not change the render"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = backup.status(_build(_minimal), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "BackupPlan", "dxr kind must echo the composite"
    assert dxr.metadata.name == "nightly", "dxr must be named after the XR"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status.ready == False, "a plan nothing has reconciled must not be ready"
    assert dxr.status.storageLocation == "projects/acme-prod/locations/europe-west1/backupPlans/nightly", "the plan's full name is derivable before creation"
    assert dxr.status?.phase == Undefined, "no phase until the plan is observed"
    assert dxr.status.message == "BackupBackupPlan managed: not Ready", "the message must name the composed resource"
}

_observed = lambda _conds, _at {
    {managed = {Resource = {status = {conditions = _conds, atProvider = _at}}}}
}

_ready_cond = {type = "Ready", status = "True", reason = "Available", lastTransitionTime = "2026-11-20T00:00:00Z"}
_synced = {type = "Synced", status = "True", reason = "ReconcileSuccess", lastTransitionTime = "2026-11-20T00:00:00Z"}
_plan_id = "projects/acme-prod/locations/europe-west1/backupPlans/nightly"

test_status_ready = lambda {
    dxr = backup.status(_build(_minimal), _observed([_synced, _ready_cond], {id = _plan_id, state = "READY"}))
    assert dxr.status.ready == True, "a Ready plan in state READY is a working plan"
    assert dxr.status.phase == "READY", "the Backup for GKE state must be surfaced"
    assert dxr.status.storageLocation == _plan_id, "the observed id is the storage location"
    assert dxr.status?.message == Undefined, "a healthy plan has nothing to say"
}

# upjet reports Ready once the plan exists; a plan whose cluster lacks the
# backup agent sits in CLUSTER_PENDING and takes no backups.
test_status_cluster_pending = lambda {
    dxr = backup.status(_build(_minimal), _observed([_ready_cond], {id = _plan_id, state = "CLUSTER_PENDING", stateReason = "Backup for GKE agent not enabled"}))
    assert dxr.status.ready == False, "a plan that cannot back up yet must not read as ready"
    assert dxr.status.phase == "CLUSTER_PENDING", "the pending state must be surfaced"
    assert dxr.status.message == "BackupBackupPlan managed: plan is CLUSTER_PENDING: Backup for GKE agent not enabled", "the state reason must say why"
}

test_status_not_ready = lambda {
    dxr = backup.status(_build(_minimal), _observed([
        {type = "Ready", status = "False", reason = "ReconcileError", message = "create failed: gkebackup.googleapis.com is disabled", lastTransitionTime = "2026-11-20T00:00:00Z"}
    ], {}))
    assert dxr.status.ready == False, "a failing plan must not read as ready"
    assert dxr.status.message == "BackupBackupPlan managed: create failed: gkebackup.googleapis.com is disabled", "the condition's own message must be surfaced"
    assert dxr.status?.phase == Undefined, "no state until the provider reports one"
    _no_msg = backup.status(_build(_minimal), _observed([{type = "Ready", status = "False", reason = "Creating", lastTransitionTime = "2026-11-20T00:00:00Z"}], {}))
    assert _no_msg.status.message == "BackupBackupPlan managed: not Ready", "without a condition message the resource is still named"
}
