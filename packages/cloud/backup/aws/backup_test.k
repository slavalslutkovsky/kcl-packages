import .backup
import json
import runtime

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "BackupPlan", metadata = {name = "nightly", namespace = "platform"}, spec = _spec}
}

_arn = "arn:aws:eks:eu-west-1:123456789012:cluster/prod"
# The minimum an aws BackupPlan needs: when, and which cluster.
_minimal = {schedule = "0 2 * * *", cluster = {id = _arn}}
_orphan = ["Observe", "Create", "Update", "LateInitialize"]

_render = lambda _spec, _obs {
    backup.render(_build(_spec), _obs)
}

# Composed resources by their composition-resource-name.
_by_name = lambda _spec {
    {r.metadata.annotations["krm.kcl.dev/composition-resource-name"]: r for r in _render(_spec, {})}
}

_names = lambda items: [any] -> [str] {
    [_r.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _r in items]
}

# The Plan's single rule. `rule` is a KCL keyword, so the schema escapes it as
# $rule; the rendered object is indexed by the plain key.
_rule = lambda _spec {
    _by_name(_spec)["managed"].spec.forProvider["rule"][0]
}

_err = lambda f -> str {
    runtime.catch(f) or ""
}

_cron = lambda expr: str -> str {
    backup.aws_schedule(expr)
}

_cron_err = lambda expr: str -> str {
    _err(lambda {
        backup.aws_schedule(expr)
    })
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    _named = _by_name(_minimal)
    assert sorted([_k for _k in _named]) == ["managed", "role", "role-backup", "role-restore", "selection", "vault"], "every composed resource must be named"
    assert _named["vault"].apiVersion == "backup.aws.m.upbound.io/v1beta1", "the vault must be a namespaced (.m.) AWS Backup MR"
    assert _named["vault"].kind == "Vault", "wrong kind for the vault"
    assert _named["managed"].kind == "Plan", "the plan is the managed resource"
    assert _named["selection"].kind == "Selection", "wrong kind for the selection"
    assert _named["role"].apiVersion == "iam.aws.m.upbound.io/v1beta1", "the role must be a namespaced (.m.) IAM MR"
    assert _named["role"].kind == "Role", "wrong kind for the role"
    assert _named["role-backup"].kind == "RolePolicyAttachment", "wrong kind for the backup policy attachment"
    assert _named["role-restore"].kind == "RolePolicyAttachment", "wrong kind for the restore policy attachment"
    assert _named["vault"].metadata.annotations["crossplane.io/external-name"] == "nightly", "the vault name is pinned to the XR name — status.storageLocation promises it"
    assert "crossplane.io/external-name" not in _named["role"].metadata.annotations, "IAM is global: an XR-derived role name would collide across regions and namespaces"
    assert all _k, _r in _named {
        _r.spec?.providerConfigRef == Undefined
    }, "providerConfigRef stays at the schema default"
    assert all _k, _r in _named {
        _r.spec.managementPolicies == ["*"]
    }, "deletionPolicy Delete means full management"
}

# ---- render: cluster ARN ----------------------------------------------------
test_cluster_arn_parsing = lambda {
    assert backup.cluster_of(_arn) == {partition = "aws", region = "eu-west-1", account = "123456789012", name = "prod"}, "the ARN must split into partition, region, account and name"
    assert backup.cluster_of("arn:aws-us-gov:eks:us-gov-west-1:123456789012:cluster/gov_1").partition == "aws-us-gov", "GovCloud ARNs must parse"
    _named = _by_name(_minimal)
    assert all _n in ["vault", "managed", "selection"] {
        _named[_n].spec.forProvider.region == "eu-west-1"
    }, "every regional MR must land in the cluster's own region, read from the ARN"
    assert _named["selection"].spec.forProvider.resources == [_arn], "the selection must protect exactly the cluster ARN"
    _gov = _by_name({schedule = "0 2 * * *", cluster = {id = "arn:aws-us-gov:eks:us-gov-west-1:123456789012:cluster/gov"}})
    assert _gov["role-backup"].spec.forProvider.policyArn == "arn:aws-us-gov:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup", "managed policy ARNs must follow the cluster's partition"
}

test_cluster_arn_assert = lambda {
    _missing = _err(lambda {
        _render({schedule = "0 2 * * *"}, {})
    })
    assert "backup-aws: spec.cluster.id is required" in _missing, "a plan without a cluster must fail the render, got: ${_missing}"
    _bare = _err(lambda {
        _render({schedule = "0 2 * * *", cluster = {id = "prod"}}, {})
    })
    assert "backup-aws: spec.cluster.id must be the EKS cluster ARN" in _bare, "a bare cluster name (KubernetesCluster status.name) must be refused, got: ${_bare}"
    assert "must be the EKS cluster ARN" in _err(lambda {
        backup.cluster_of("arn:aws:ecs:eu-west-1:123456789012:cluster/prod")
    }), "an ECS cluster ARN must be refused"
    assert "must be the EKS cluster ARN" in _err(lambda {
        backup.cluster_of("arn:aws:eks:eu-west-1:1234:cluster/prod")
    }), "an account id must be twelve digits"
    assert "must be the EKS cluster ARN" in _err(lambda {
        backup.cluster_of("arn:aws:eks:eu-west-1:123456789012:nodegroup/prod/ng/abc")
    }), "only cluster ARNs are protectable"
}

test_name_assert = lambda {
    _msg = _err(lambda {
        backup.render({metadata = {name = "nightly.prod"}, spec = _minimal}, {})
    })
    assert "backup-aws: metadata.name 'nightly.prod' names the backup vault" in _msg, "a name AWS would reject for the vault must fail the render, got: ${_msg}"
}

# ---- render: schedule -------------------------------------------------------
test_cron_translation = lambda {
    _table = {
        # every day at a fixed time: dow becomes '?'
        "0 2 * * *" = "cron(0 2 * * ? *)"
        "15 23 * * *" = "cron(15 23 * * ? *)"
        # hourly and hour steps
        "0 * * * *" = "cron(0 * * * ? *)"
        "0 */6 * * *" = "cron(0 */6 * * ? *)"
        # weekday ranges: numbers shift by one, names pass uppercased
        "30 1 * * 1-5" = "cron(30 1 ? * 2-6 *)"
        "0 3 * * MON-FRI" = "cron(0 3 ? * MON-FRI *)"
        "0 3 * * mon-fri" = "cron(0 3 ? * MON-FRI *)"
        "0 3 * * 0-6" = "cron(0 3 ? * 1-7 *)"
        "0 3 * * 0-7" = "cron(0 3 ? * 1-7 *)"
        # numeric day-of-week lists, Sunday as 0 and as 7
        "0 4 * * 0,6" = "cron(0 4 ? * 1,7 *)"
        "0 4 * * 1,3,5" = "cron(0 4 ? * 2,4,6 *)"
        "0 4 * * 7" = "cron(0 4 ? * 1 *)"
        "0 4 * * 0" = "cron(0 4 ? * 1 *)"
        "0 4 * * sat,sun" = "cron(0 4 ? * SAT,SUN *)"
        # a range running into Sunday (7) wraps on AWS and is spelled as a list
        "0 4 * * 5-7" = "cron(0 4 ? * 1,6,7 *)"
        "0 4 * * 1-2,6" = "cron(0 4 ? * 2-3,7 *)"
        # day-of-month restricted: dom passes, dow becomes '?'
        "0 5 1,15 * *" = "cron(0 5 1,15 * ? *)"
        "0 5 */2 jan *" = "cron(0 5 */2 JAN ? *)"
        "0 5 1 1-6 *" = "cron(0 5 1 1-6 ? *)"
        # shorthands
        "@hourly" = "cron(0 * * * ? *)"
        "@daily" = "cron(0 0 * * ? *)"
        "@midnight" = "cron(0 0 * * ? *)"
        "@weekly" = "cron(0 0 ? * 1 *)"
        "@monthly" = "cron(0 0 1 * ? *)"
        "@yearly" = "cron(0 0 1 1 ? *)"
        # surrounding and repeated whitespace is not significant
        "  0   2 * * *  " = "cron(0 2 * * ? *)"
    }
    _wrong = {_in: _cron(_in) for _in in _table if _cron(_in) != _table[_in]}
    assert not _wrong, "cron translation mismatch (input: got): ${_wrong}"
    assert _rule(_minimal).schedule == "cron(0 2 * * ? *)", "the plan rule must carry the translated schedule"
    assert _rule(_minimal).scheduleExpressionTimezone == "Etc/UTC", "the XRD promises UTC"
}

test_cron_untranslatable = lambda {
    _both = _cron_err("0 2 1 * 1")
    assert "backup-aws: schedule '0 2 1 * 1' restricts both day-of-month and day-of-week" in _both, "cron ORs restricted day fields, AWS cannot — must fail, got: ${_both}"
    assert "backup-aws: AWS Backup runs at most hourly" in _cron_err("*/15 * * * *"), "sub-hourly schedules must fail"
    assert "backup-aws: AWS Backup runs at most hourly" in _cron_err("0,30 * * * *"), "two runs an hour must fail"
    assert "backup-aws: AWS cron has no step values in day-of-week" in _cron_err("0 2 * * 1-5/2"), "dow steps must fail"
    assert "backup-aws: day-of-week '8' is neither 0-7 nor a day name" in _cron_err("0 2 * * 8"), "out-of-range dow must fail"
    assert "backup-aws: day-of-week range '5-1' runs backwards" in _cron_err("0 2 * * 5-1"), "backwards dow ranges must fail"
    assert "backup-aws: unsupported cron shorthand '@reboot'" in _cron_err("@reboot"), "@reboot has no schedule to translate"
    assert "backup-aws: schedule must be a five-field cron expression" in _cron_err("0 2 * *"), "four fields must fail"
    assert "backup-aws: schedule must be a five-field cron expression" in _cron_err("0 0 2 * * ?"), "six-field (Quartz/AWS) input must fail"
    # through render, too: the plan must not be composed with a narrowed schedule
    assert "restricts both day-of-month and day-of-week" in _err(lambda {
        _render({schedule = "0 2 1 * MON", cluster = {id = _arn}}, {})
    }), "render must refuse an untranslatable schedule"
}

# ---- render: plan -----------------------------------------------------------
test_plan_shape = lambda {
    _p = _by_name(_minimal)["managed"].spec.forProvider
    assert _p.name == "nightly", "the plan is named after the XR"
    assert len(_p["rule"]) == 1, "one rule per plan"
    _r = _p["rule"][0]
    assert _r.ruleName == "nightly", "the rule is named after the XR"
    assert _r.targetVaultNameSelector.matchControllerRef == True, "the rule must target the composed vault"
    assert _r?.targetVaultName == Undefined, "the vault is resolved by selector, never by a literal name"
    assert _r?.recoveryPointTags == Undefined, "no recovery point tags unless asked for"
    assert _p?.tags == Undefined, "no plan tags unless asked for"
}

test_retention = lambda {
    assert _rule(_minimal).lifecycle.deleteAfter == 30, "retentionDays defaults to 30"
    assert _rule(_minimal | {retentionDays = 7}).lifecycle.deleteAfter == 7, "retentionDays must become lifecycle.deleteAfter"
    assert _rule(_minimal | {retentionDays = 1}).lifecycle?.coldStorageAfter == Undefined, "no cold-storage transition is ever composed"
}

test_tags = lambda {
    _t = {team = "platform", env = "prod"}
    _named = _by_name(_minimal | {tags = _t})
    assert _named["vault"].spec.forProvider.tags == _t, "tags must land on the vault"
    assert _named["managed"].spec.forProvider.tags == _t, "tags must land on the plan"
    assert _named["managed"].spec.forProvider["rule"][0].recoveryPointTags == _t, "tags must land on every recovery point"
    assert _named["role"].spec.forProvider?.tags == Undefined, "the XRD promises vault, plan and recovery points only"
}

# ---- render: vault ----------------------------------------------------------
test_vault_kms = lambda {
    _key = "arn:aws:kms:eu-west-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    _v = _by_name(_minimal | {encryptionKmsKeyId = _key})["vault"].spec.forProvider
    assert _v.kmsKeyArn == _key, "encryptionKmsKeyId must become the vault's kmsKeyArn"
    assert _by_name(_minimal)["vault"].spec.forProvider?.kmsKeyArn == Undefined, "no key means the AWS-owned default key"
    _msg = _err(lambda {
        _render(_minimal | {encryptionKmsKeyId = "1234abcd-12ab-34cd-56ef-1234567890ab"}, {})
    })
    assert "backup-aws: encryptionKmsKeyId becomes the vault's kmsKeyArn and must be a KMS key ARN" in _msg, "a bare key id must fail the render, got: ${_msg}"
}

# Deleting a plan must never purge the recovery points it took.
test_vault_never_force_destroyed = lambda {
    assert _by_name(_minimal)["vault"].spec.forProvider?.forceDestroy == Undefined, "forceDestroy must never be set"
    assert _by_name(_minimal | {deletionPolicy = "Delete"})["vault"].spec.forProvider?.forceDestroy == Undefined, "not even with deletionPolicy Delete"
}

# ---- render: role -----------------------------------------------------------
test_role = lambda {
    _named = _by_name(_minimal)
    _trust = json.decode(_named["role"].spec.forProvider.assumeRolePolicy)
    assert _trust.Statement == [{Effect = "Allow", Principal = {Service = "backup.amazonaws.com"}, Action = "sts:AssumeRole"}], "only AWS Backup may assume the role"
    assert _named["role-backup"].spec.forProvider.policyArn == "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup", "backup policy"
    assert _named["role-restore"].spec.forProvider.policyArn == "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores", "restore policy"
    assert all _n in ["role-backup", "role-restore"] {
        _named[_n].spec.forProvider.roleSelector.matchControllerRef == True
    }, "attachments must bind the composed role"
    _s = _named["selection"].spec.forProvider
    assert _s.iamRoleArnSelector.matchControllerRef == True, "the selection must run as the composed role"
    assert _s.planIdSelector.matchControllerRef == True, "the selection must belong to the composed plan"
}

# ---- render: ignored fields -------------------------------------------------

# AWS Backup protects the whole cluster, so the filters only ever narrow what
# was asked for to a superset; destination is the composed vault's job.
test_ignored_fields = lambda {
    _plain = _render(_minimal, {})
    _noisy = _render(_minimal | {
        includedNamespaces = ["zerg"]
        includedResources = ["deployments.apps"]
        excludedResources = ["events"]
        labelSelector = {backup = "nightly"}
        snapshotVolumes = False
        defaultVolumesToFsBackup = True
        destination = {provider = "aws", bucket = "ignored"}
        cluster = {id = _arn, region = "us-east-1", snapshotResourceGroup = "rg"}
    }, {})
    assert _plain == _noisy, "filters, volume knobs, destination and the azure-only cluster fields must be ignored"
}

# ---- render: paused ---------------------------------------------------------
test_pause_drops_selection = lambda {
    _paused = _by_name(_minimal | {paused = True})
    assert "selection" not in _paused, "paused must withdraw the selection"
    assert sorted([_k for _k in _paused]) == ["managed", "role", "role-backup", "role-restore", "vault"], "pausing must not touch the vault, plan or role — the recovery points stay"
    assert "selection" in _by_name(_minimal | {paused = False}), "an explicit paused: false keeps it"
}

# Orphan strips Delete from every MR, so dropping the selection outright would
# leave it running in AWS. It is flipped to full management first, and only
# dropped once the observed object carries the new policy.
test_pause_under_orphan = lambda {
    _spec = _minimal | {paused = True, deletionPolicy = "Orphan"}
    _orphaned = {
        selection = {
            Resource = {
                spec = {managementPolicies = _orphan}
            }
        }
    }
    _flip = [_r for _r in _render(_spec, _orphaned) if _r.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "selection"]
    assert len(_flip) == 1, "an observed orphan-policy selection must be kept for one more pass"
    assert _flip[0].spec.managementPolicies == ["*"], "... with full management, so its removal deletes it in AWS"
    _flipped = {
        selection = {
            Resource = {
                spec = {managementPolicies = ["*"]}
            }
        }
    }
    assert "selection" not in _names(_render(_spec, _flipped)), "once the full policy is observed, the selection must be dropped"
    assert "selection" not in _names(_render(_spec, {})), "nothing observed, nothing to withdraw"
}

# ---- render: deletion policy ------------------------------------------------
test_orphan = lambda {
    _named = _by_name(_minimal | {deletionPolicy = "Orphan"})
    assert all _k, _r in _named {
        _r.spec.managementPolicies == _orphan
    }, "Orphan must drop Delete from every managed resource"
}

# ---- status -----------------------------------------------------------------
_ok = {status = "True", type = "Ready", reason = "Available"}
_ready_all = {_n: {
    Resource = {
        status = {conditions = [{type = "Synced", status = "True"}, _ok]}
    }
} for _n in ["vault", "role", "role-backup", "role-restore", "managed", "selection"]}

test_status_pre_creation = lambda {
    dxr = backup.status(_build(_minimal), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "BackupPlan", "dxr kind must echo the composite"
    assert dxr.metadata.name == "nightly", "dxr must be named after the XR"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.ready == False, "a plan nothing has reconciled must not be ready"
    assert dxr.status.storageLocation == "nightly", "the vault name is pinned, so report it immediately"
    assert dxr.status?.phase == Undefined, "AWS Backup reports no phase"
    assert dxr.status.message == "vault (Vault): not created yet", "the first missing resource must be named, got: ${dxr.status.message}"
}

test_status_ready = lambda {
    dxr = backup.status(_build(_minimal), _ready_all)
    assert dxr.status.ready == True, "every composed MR Ready is a working plan"
    assert dxr.status?.message == Undefined, "a healthy plan has nothing to say"
    assert dxr.status?.phase == Undefined, "AWS Backup reports no phase"
}

test_status_not_ready = lambda {
    _bad = _ready_all | {
        selection = {
            Resource = {
                status = {conditions = [{type = "Ready", status = "False", reason = "ReconcileError", message = "create failed: IAM role is not assumable by AWS Backup"}]}
            }
        }
    }
    dxr = backup.status(_build(_minimal), _bad)
    assert dxr.status.ready == False, "one failing MR fails the plan"
    assert dxr.status.message == "selection (Selection): create failed: IAM role is not assumable by AWS Backup", "the failing MR's own condition message must be surfaced, got: ${dxr.status.message}"

    _reason_only = backup.status(_build(_minimal), _ready_all | {
        managed = {
            Resource = {
                status = {conditions = [{type = "Ready", status = "False", reason = "Creating"}]}
            }
        }
    })
    assert _reason_only.status.message == "managed (Plan): Creating", "without a message the reason must do, got: ${_reason_only.status.message}"

    _no_cond = backup.status(_build(_minimal), _ready_all | {
        "role-restore" = {
            Resource = {
                status = {}
            }
        }
    })
    assert _no_cond.status.message == "role-restore (RolePolicyAttachment): waiting for its Ready condition", "an observed MR without conditions is not ready, got: ${_no_cond.status.message}"

    # Dependency order: the vault is reported before a later failure.
    _two = backup.status(_build(_minimal), {k: v for k, v in _ready_all if k not in ["vault", "selection"]})
    assert _two.status.message == "vault (Vault): not created yet", "the first non-Ready resource in composition order must be named"
}

# A paused plan composes no selection, so its absence must not hold readiness.
test_status_paused = lambda {
    _spec = _minimal | {paused = True}
    _ocds = {k: v for k, v in _ready_all if k != "selection"}
    dxr = backup.status(_build(_spec), _ocds)
    assert dxr.status.ready == True, "a paused plan with every composed MR Ready is ready"
    assert dxr.status?.message == Undefined, "a withdrawn selection is not a fault"
}
