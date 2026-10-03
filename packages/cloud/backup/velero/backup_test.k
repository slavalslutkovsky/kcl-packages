import .backup

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec, _ns: str = "velero" {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "BackupPlan", metadata = {name = "nightly", namespace = _ns}, spec = _spec}
}

# The minimum a BackupPlan needs: when, and where to.
_dest = {provider = "aws", bucket = "acme-backups"}
_minimal = {schedule = "0 2 * * *", destination = _dest}

# Composed resources by their composition-resource-name.
_by_name = lambda _spec {
    {r.metadata.annotations["krm.kcl.dev/composition-resource-name"]: r for r in backup.render(_build(_spec))}
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = backup.render(_build(_minimal))
    assert len(items) == 3, "a plan with volume snapshots must emit a location, a snapshot location and a schedule"
    _named = _by_name(_minimal)
    assert sorted([_k for _k in _named]) == ["managed", "snapshot-location", "storage-location"], "every composed resource must be named"
    assert _named["managed"].apiVersion == "velero.io/v1", "must be the Velero CRDs, composed directly"
    assert _named["managed"].kind == "Schedule", "the schedule is the managed resource"
    assert _named["storage-location"].kind == "BackupStorageLocation", "wrong kind for the object-store location"
    assert _named["snapshot-location"].kind == "VolumeSnapshotLocation", "wrong kind for the snapshot location"
    assert all _k, _r in _named {
        _r.metadata.name == "nightly"
    }, "every object must be named after the XR — status.storageLocation promises that name"
    assert all _k, _r in _named {
        _r.metadata?.namespace == Undefined
    }, "no namespace: Crossplane places composed resources in the XR's namespace, which is Velero's own"
}

# ---- render: storage location -----------------------------------------------

# A plain cloud bucket: no endpoint override, so no s3Url and no path-style.
test_storage_location_plain_bucket = lambda {
    _bsl = _by_name({schedule = "0 2 * * *", destination = {provider = "aws", bucket = "acme-backups", prefix = "prod", region = "eu-west-1"}})["storage-location"]
    assert _bsl.spec.provider == "aws", "the XRD enum is Velero's plugin name, passed through"
    assert _bsl.spec.objectStorage.bucket == "acme-backups", "the bucket must be the destination bucket"
    assert _bsl.spec.objectStorage.prefix == "prod", "prefix must scope the plan inside a shared bucket"
    assert _bsl.spec.config == {region = "eu-west-1"}, "a plain bucket needs the region and nothing else"
    assert _bsl.spec.default == False, "a plan's location must never claim the cluster-wide default slot"
}

test_storage_location_no_optional_fields = lambda {
    _bsl = _by_name(_minimal)["storage-location"]
    assert _bsl.spec.objectStorage?.prefix == Undefined, "no prefix unless asked for — the bucket root"
    assert _bsl.spec?.config == Undefined, "no config block when there is nothing provider-specific to say"
    assert _bsl.spec?.credential == Undefined, "no credential ref means the server's ambient identity"
}

# An S3-compatible endpoint (in-cluster RustFS, MinIO) addresses buckets by
# path, so s3Url must drag s3ForcePathStyle along with it.
test_storage_location_s3_endpoint = lambda {
    _bsl = _by_name({schedule = "0 2 * * *", destination = {
        provider = "aws"
        bucket = "cluster-backups"
        region = "us-east-1"
        s3Url = "http://rustfs.rustfs.svc.cluster.local:9000"
    }})["storage-location"]
    assert _bsl.spec.config == {
        region = "us-east-1"
        s3Url = "http://rustfs.rustfs.svc.cluster.local:9000"
        s3ForcePathStyle = "true"
    }, "an s3Url endpoint must also force path-style addressing: those servers have no per-bucket DNS"
}

test_storage_location_credentials = lambda {
    _bsl = _by_name({schedule = "0 2 * * *", destination = _dest | {
        credentialsSecret = {name = "rustfs-creds"}
    }})["storage-location"]
    assert _bsl.spec.credential.name == "rustfs-creds", "credentialsSecret must wire the location's credential"
    assert _bsl.spec.credential.key == "cloud", "credentialsSecret.key must default to Velero's own convention"
    _keyed = _by_name({schedule = "0 2 * * *", destination = _dest | {
        credentialsSecret = {name = "rustfs-creds", key = "aws"}
    }})["storage-location"]
    assert _keyed.spec.credential.key == "aws", "an explicit key must win"
}

# ---- render: snapshot location ----------------------------------------------

# The snapshot location exists only when there are snapshots to put in it.
test_snapshot_location_rule = lambda {
    assert "snapshot-location" in _by_name(_minimal), "snapshotVolumes defaults to true, so the location must be there"
    assert "snapshot-location" not in _by_name(_minimal | {snapshotVolumes = False}), "no snapshots -> no snapshot location"
    assert "snapshot-location" not in _by_name(_minimal | {defaultVolumesToFsBackup = True}), "file-level backup takes no storage-layer snapshots, so the location would never be written to"
    assert len(backup.render(_build(_minimal | {snapshotVolumes = False}))) == 2, "dropping the snapshot location must not drop anything else"
}

# Snapshots go to the cloud's volume API, not to the object store, so an
# endpoint override has no business being on the snapshot location.
test_snapshot_location_config = lambda {
    _vsl = _by_name({schedule = "0 2 * * *", destination = {
        provider = "aws"
        bucket = "cluster-backups"
        region = "us-east-1"
        s3Url = "http://rustfs.rustfs.svc.cluster.local:9000"
        credentialsSecret = {name = "rustfs-creds"}
    }})["snapshot-location"]
    assert _vsl.spec.provider == "aws", "the snapshot location uses the same plugin"
    assert _vsl.spec.config == {region = "us-east-1"}, "only the region belongs on a snapshot location — an s3Url there is meaningless"
    assert _vsl.spec.credential.name == "rustfs-creds", "the snapshot location shares the destination's credentials"
    assert _vsl.spec.credential.key == "cloud", "the snapshot location credential must default the same way"
    assert _by_name(_minimal)["snapshot-location"].spec?.config == Undefined, "no region -> no config block"
}

# ---- render: schedule -------------------------------------------------------
test_schedule_cron_and_pause = lambda {
    _s = _by_name(_minimal)["managed"].spec
    assert _s.schedule == "0 2 * * *", "the cron must reach Velero verbatim"
    assert _s.paused == False, "a plan runs unless it is paused"
    assert _by_name(_minimal | {paused = True})["managed"].spec.paused == True, "paused must stop new backups without deleting the plan"
}

# Velero's coarsest duration unit is the hour, so retention in days is
# multiplied out rather than handed over as "30d" (which it cannot parse).
test_schedule_ttl = lambda {
    assert _by_name(_minimal)["managed"].spec.template.ttl == "720h", "retentionDays defaults to 30 -> 720h"
    assert _by_name(_minimal | {retentionDays = 7})["managed"].spec.template.ttl == "168h", "retentionDays must become hours"
    assert _by_name(_minimal | {retentionDays = 1})["managed"].spec.template.ttl == "24h", "the minimum retention is still a whole day"
}

test_schedule_template_defaults = lambda {
    _t = _by_name(_minimal)["managed"].spec.template
    assert _t.snapshotVolumes == True, "snapshotVolumes defaults to true"
    assert _t.defaultVolumesToFsBackup == False, "file-level backup is opt-in"
    assert _t.storageLocation == "nightly", "the template must point at the composed location BY NAME, never at the cluster default"
    assert _t.volumeSnapshotLocations == ["nightly"], "snapshots must land in the composed snapshot location"
    assert _t?.includedNamespaces == Undefined, "an empty includedNamespaces means every namespace, which Velero spells as absence"
    assert _t?.includedResources == Undefined, "no resource filter unless asked for"
    assert _t?.excludedResources == Undefined, "no resource filter unless asked for"
    assert _t?.labelSelector == Undefined, "no selector unless asked for"
    assert _t?.metadata == Undefined, "no labels unless asked for"
}

test_schedule_template_selectors = lambda {
    _t = _by_name(_minimal | {
        includedNamespaces = ["zerg", "dbs"]
        includedResources = ["persistentvolumeclaims", "deployments.apps"]
        excludedResources = ["events", "events.events.k8s.io"]
        labelSelector = {"backup" = "nightly"}
        tags = {team = "platform"}
    })["managed"].spec.template
    assert _t.includedNamespaces == ["zerg", "dbs"], "includedNamespaces must narrow the backup"
    assert _t.includedResources == ["persistentvolumeclaims", "deployments.apps"], "includedResources must pass through verbatim"
    assert _t.excludedResources == ["events", "events.events.k8s.io"], "excludedResources must pass through verbatim"
    assert _t.labelSelector.matchLabels == {"backup" = "nightly"}, "labelSelector must become matchLabels"
    assert _t.metadata.labels == {team = "platform"}, "tags label the Backup objects, so `velero backup get -l` can find them"
}

# The self-hosted case: plain local storage, no CSI snapshot support.
test_schedule_fs_backup = lambda {
    _t = _by_name(_minimal | {defaultVolumesToFsBackup = True})["managed"].spec.template
    assert _t.defaultVolumesToFsBackup == True, "file-level backup must reach the template"
    assert _t?.volumeSnapshotLocations == Undefined, "there is no snapshot location to point at"
    assert _t.storageLocation == "nightly", "the metadata and the file copies still go to the object store"
}

# ---- render: ignored fields -------------------------------------------------

# Velero CRs are not Crossplane managed resources, so there are no
# managementPolicies to set; the XRD documents the field as ignored.
test_deletion_policy_ignored = lambda {
    _plain = backup.render(_build(_minimal))
    _orphan = backup.render(_build(_minimal | {deletionPolicy = "Orphan"}))
    assert _plain == _orphan, "deletionPolicy must be ignored by the velero backend"
}

# ---- status -----------------------------------------------------------------

# The location name is derived from the XR, so it is known before anything has
# reconciled — readiness is not.
test_status_pre_creation = lambda {
    dxr = backup.status(_build(_minimal), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "BackupPlan", "dxr kind must echo the composite"
    assert dxr.metadata.name == "nightly", "dxr must be named after the XR"
    assert dxr.status.provider == "velero", "provider must be velero"
    assert dxr.status.ready == False, "a plan nothing has reconciled must not be ready"
    assert dxr.status.storageLocation == "nightly", "the location name is derivable, so report it immediately"
    assert dxr.status?.phase == Undefined, "no phase until the Schedule is observed"
    assert dxr.status?.storageLocationPhase == Undefined, "no phase until the location is observed"
    assert dxr.status?.lastBackup == Undefined, "no lastBackup until one has run"
    assert dxr.status?.message == Undefined, "nothing to complain about yet"
}

_ocds_ready = {
    managed = {
        Resource = {
            status = {phase = "Enabled", lastBackup = "2026-09-19T02:00:31Z"}
        }
    }
    "storage-location" = {
        Resource = {
            status = {phase = "Available", lastValidationTime = "2026-09-19T02:05:00Z"}
        }
    }
}

test_status_ready = lambda {
    dxr = backup.status(_build(_minimal), _ocds_ready)
    assert dxr.status.ready == True, "an enabled schedule over an available location is a working plan"
    assert dxr.status.phase == "Enabled", "the Schedule phase must be surfaced"
    assert dxr.status.storageLocationPhase == "Available", "the location phase must be surfaced"
    assert dxr.status.lastBackup == "2026-09-19T02:00:31Z", "lastBackup must be the schedule's own timestamp"
    assert dxr.status?.message == Undefined, "a healthy plan has nothing to say"
}

# Half a plan is no plan: an enabled schedule writing to a bucket Velero
# cannot reach lands nothing, and must not read as ready.
test_status_needs_both_halves = lambda {
    _bad_loc = backup.status(_build(_minimal), {
        managed = {
            Resource = {
                status = {phase = "Enabled"}
            }
        }
        "storage-location" = {
            Resource = {
                status = {phase = "Unavailable", message = "BackupStorageLocation \"nightly\" is unavailable: bucket not found"}
            }
        }
    })
    assert _bad_loc.status.ready == False, "an unreachable bucket must not read as ready"
    assert _bad_loc.status.message == "BackupStorageLocation \"nightly\" is unavailable: bucket not found", "the location's own message must say why"

    _bad_sched = backup.status(_build(_minimal), {
        managed = {
            Resource = {
                status = {phase = "FailedValidation", validationErrors = ["invalid schedule", "unknown storage location"]}
            }
        }
        "storage-location" = {
            Resource = {
                status = {phase = "Available"}
            }
        }
    })
    assert _bad_sched.status.ready == False, "a schedule that failed validation must not read as ready"
    assert _bad_sched.status.message == "invalid schedule; unknown storage location", "the schedule's validation errors must be joined into the message"

    _new = backup.status(_build(_minimal), {
        managed = {
            Resource = {
                status = {phase = "New"}
            }
        }
        "storage-location" = {
            Resource = {
                status = {phase = "Available"}
            }
        }
    })
    assert _new.status.ready == False, "a schedule Velero has not accepted yet is not ready"
}
