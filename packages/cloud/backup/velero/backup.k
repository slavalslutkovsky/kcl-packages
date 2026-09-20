# backup (velero) — Crossplane Composition logic (function-kcl module).
# The self-hosted backend: Velero is an operator, not a Crossplane provider, so
# this renders velero.io/v1 objects DIRECTLY — Crossplane v2 composes arbitrary
# namespaced resources, so there is no provider MR wrapper, no
# providerConfigRef and no managementPolicies (deletionPolicy is documented as
# ignored here: the Schedule and the location are owned by the XR and go with
# it, while the backups already in the bucket outlive both).
#
# Three objects, because Velero splits a plan across three: WHEN and WHAT is
# the Schedule, WHERE the metadata goes is the BackupStorageLocation, and
# WHERE volume snapshots go is the VolumeSnapshotLocation. The XR is one
# object so the three can never drift apart.
#
# All three land in the XR's own namespace, which is the whole reason the XRD
# says a BackupPlan belongs in Velero's namespace: the server watches only the
# namespace it runs in, and a namespaced XR may only compose into its own.
import velero.models.v1.velero_io_v1_schedule as backend
import velero.models.v1.velero_io_v1_backup_storage_location as storage
import velero.models.v1.velero_io_v1_volume_snapshot_location as snapshots

# Velero expresses a backup's lifetime as a Go duration, and the coarsest unit
# time.ParseDuration accepts is the hour: days have to be multiplied out.
ttl_hours = lambda days: int -> str {
    "${days * 24}h"
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _dest = _spec.destination

    # Tri-state: absent must mean the XRD default, and `or` would turn an
    # explicit false into it.
    _snapshot = _spec?.snapshotVolumes
    if _snapshot == Undefined:
        _snapshot = True

    _fs = _spec?.defaultVolumesToFsBackup or False

    # File-level backup reads volume contents through the pod, so there are no
    # storage-layer snapshots to place and a snapshot location would be an
    # object Velero never writes to.
    _snapshotting = _snapshot and not _fs

    # Velero's `config` is a provider-specific free map of strings. The aws
    # plugin reads `region`, and `s3Url` points it at an S3-compatible server
    # instead of AWS — which then needs path-style addressing, because those
    # servers serve every bucket off one host and have no per-bucket DNS.
    _config = {
        if _dest?.region:
            region = _dest.region
        if _dest?.s3Url:
            s3Url = _dest.s3Url
            s3ForcePathStyle = "true"
    }

    # A snapshot location talks to the cloud's volume-snapshot API, never to
    # object storage, so an s3Url there would be meaningless.
    _snapshot_config = {region = _dest.region} if _dest?.region else {}

    _credential = {name = _dest.credentialsSecret.name, key = _dest.credentialsSecret?.key or "cloud"} if _dest?.credentialsSecret else Undefined

    # An empty includedNamespaces means "every namespace" to this XR; Velero
    # spells that as the field being absent, so never emit an empty list.
    _namespaces = _spec?.includedNamespaces or []

    [storage.BackupStorageLocation {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "storage-location"}
        # No namespace: Crossplane places composed namespaced resources in the
        # XR's own namespace, which for a BackupPlan is Velero's.
        metadata.name = _name
        # The XRD's enum is already Velero's own plugin naming, so it passes
        # through untranslated.
        spec.provider = _dest.provider
        spec.objectStorage = {
            bucket = _dest.bucket
            if _dest?.prefix:
                prefix = _dest.prefix
        }
        if _config:
            spec.config = _config
        if _credential:
            spec.credential = _credential
        # Never the cluster default: a plan addresses its own location by name,
        # and the default is a single cluster-wide slot that two plans would
        # fight over.
        spec.default = False
    }] + ([snapshots.VolumeSnapshotLocation {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "snapshot-location"}
        metadata.name = _name
        spec.provider = _dest.provider
        if _snapshot_config:
            spec.config = _snapshot_config
        if _credential:
            spec.credential = _credential
    }] if _snapshotting else []) + [backend.Schedule {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        metadata.name = _name
        spec.schedule = _spec.schedule
        spec.paused = _spec?.paused or False
        # The template is the Backup that every tick stamps out.
        spec.template = {
            ttl = ttl_hours(_spec?.retentionDays or 30)
            if _namespaces:
                includedNamespaces = _namespaces
            if _spec?.includedResources:
                includedResources = _spec.includedResources
            if _spec?.excludedResources:
                excludedResources = _spec.excludedResources
            if _spec?.labelSelector:
                labelSelector.matchLabels = _spec.labelSelector
            snapshotVolumes = _snapshot
            defaultVolumesToFsBackup = _fs
            # By name, so the plan can never be adopted by whatever location
            # happens to be the cluster default.
            storageLocation = _name
            if _snapshotting:
                volumeSnapshotLocations = [_name]
            # Labels on the Backup objects, not on what is inside them.
            if _spec?.tags:
                metadata.labels = _spec.tags
        }
    }]
}

# Build the desired composite carrying observed status back to the XR.
# Two objects have to be healthy for a backup to actually happen: the Schedule
# must have passed validation, and the location must have answered a bucket
# probe. Either one alone is a plan that silently never lands anything, so
# readiness is the AND and the failing half's message is surfaced.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _sched = (ocds["managed"]?.Resource?.status) if ("managed" in ocds) else Undefined
    _loc = (ocds["storage-location"]?.Resource?.status) if ("storage-location" in ocds) else Undefined

    _phase = _sched?.phase or ""
    _loc_phase = _loc?.phase or ""

    # The location reports why it is Unavailable; the Schedule reports why it
    # failed validation as a list.
    _errors = _sched?.validationErrors or []
    _message = _loc?.message or ("; ".join(_errors) if _errors else "")

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "BackupPlan"
        metadata.name = _name
        status = {
            provider = "velero"
            ready = _phase == "Enabled" and _loc_phase == "Available"
            # Composed alongside the Schedule and named after the XR, so it is
            # known before anything has reconciled.
            storageLocation = _name
            if _phase:
                phase = _phase
            if _loc_phase:
                storageLocationPhase = _loc_phase
            if _sched?.lastBackup:
                lastBackup = _sched.lastBackup
            if _message:
                message = _message
        }
    }
}
