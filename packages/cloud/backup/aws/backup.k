# backup (aws) — Crossplane Composition logic (function-kcl module).
# AWS Backup for EKS. Typed against the aws-backup and aws-iam schema
# packages. AWS Backup splits a plan across three objects — WHERE recovery
# points live is the Vault, WHEN and for HOW LONG is the Plan, WHAT gets
# protected is the Selection — and it runs every job as an IAM role. The XR is
# one object so the four can never drift apart.
#
# An EKS backup is a composite recovery point: the cluster state (every
# Kubernetes object, the add-ons, access entries, node groups) plus a nested
# recovery point per EBS/EFS/S3 persistent volume. AWS Backup always protects
# the whole cluster, which is why the XR's namespace, resource and label
# filters are ignored here (a superset of what was asked) rather than failing
# the render.
#
# Everything regional is placed in the cluster's own region, parsed out of
# spec.cluster.id: AWS Backup can only select a resource from a plan in the
# resource's region.
import json
import regex
import aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_vault as vault
import aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_plan as plan
import aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_selection as selection
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role as role
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role_policy_attachment as attachment

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# ---- spec.cluster.id --------------------------------------------------------

# arn:<partition>:eks:<region>:<account>:cluster/<name>. The partition is kept
# so the AWS-managed policy ARNs below resolve in aws-cn and aws-us-gov too.
cluster_of = lambda arn: str -> {str:str} {
    assert regex.match(arn, r"^arn:aws[a-z-]*:eks:[a-z0-9-]+:[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]*$"), "backup-aws: spec.cluster.id must be the EKS cluster ARN (arn:aws:eks:<region>:<account>:cluster/<name>), got '${arn}'"
    _p = arn.split(":")
    {partition = _p[1], region = _p[3], account = _p[4], name = _p[5][len("cluster/")::]}
}

# ---- spec.schedule ----------------------------------------------------------

# Standard cron shorthands, spelled out so they go through the same rewrite.
_shorthands = {
    "@yearly" = "0 0 1 1 *"
    "@annually" = "0 0 1 1 *"
    "@monthly" = "0 0 1 * *"
    "@weekly" = "0 0 * * 0"
    "@daily" = "0 0 * * *"
    "@midnight" = "0 0 * * *"
    "@hourly" = "0 * * * *"
}

# Cron's day numbers (SUN=0); AWS numbers the same days 1-7 (SUN=1).
_day_numbers = {"SUN" = 0, "MON" = 1, "TUE" = 2, "WED" = 3, "THU" = 4, "FRI" = 5, "SAT" = 6}

# One day-of-week token -> cron's own number, 0-7 (7 is Sunday again).
_cron_day = lambda tok: str -> int {
    _u = tok.upper()
    assert _u in _day_numbers or (tok.isdigit() and int(tok) <= 7), "backup-aws: day-of-week '${tok}' is neither 0-7 nor a day name (SUN-SAT)"
    _day_numbers[_u] if _u in _day_numbers else int(tok)
}

# One comma-separated day-of-week element -> AWS. Names pass through
# uppercased (AWS knows SUN-SAT). Numbers are shifted by one — "1-5" (MON-FRI)
# handed over verbatim would quietly run Sunday..Thursday on AWS. A numeric
# range is expanded and re-compacted, because cron's 7 (Sunday) lands on AWS
# 1 and would otherwise produce a backwards range: "5-7" (FRI-SUN) becomes
# "1,6,7".
dow_element = lambda part: str -> str {
    assert "/" not in part, "backup-aws: AWS cron has no step values in day-of-week, got '${part}'"
    _ends = part.split("-")
    assert len(_ends) in [1, 2], "backup-aws: malformed day-of-week element '${part}'"
    _named = all _e in _ends {
        _e.upper() in _day_numbers
    }
    _lo = _cron_day(_ends[0])
    _hi = _cron_day(_ends[-1])
    assert _lo <= _hi, "backup-aws: day-of-week range '${part}' runs backwards"
    _aws = sorted([_d % 7 + 1 for _d in range(_lo, _hi + 1)])
    _days = [_d for _i, _d in _aws if _i == 0 or _aws[_i - 1] != _d]
    _contiguous = _days == [_days[0] + _i for _i in range(len(_days))]
    part.upper() if _named else ("${_days[0]}" if len(_days) == 1 else ("${_days[0]}-${_days[-1]}" if _contiguous else ",".join(["${_d}" for _d in _days])))
}

# Five-field cron -> AWS's six-field `cron(m h dom mon dow year)`, evaluated in
# UTC. Two AWS rules shape the rewrite:
#   - exactly one of day-of-month / day-of-week must be `?`. Standard cron runs
#     when EITHER restricted day field matches, which AWS cannot express, so a
#     schedule restricting both fails instead of being narrowed;
#   - AWS Backup refuses jobs less than an hour apart, so the minute field must
#     be a single value (one run per matching hour at most).
aws_schedule = lambda expr: str -> str {
    _raw = expr.strip()
    assert not _raw.startswith("@") or _raw.lower() in _shorthands, "backup-aws: unsupported cron shorthand '${_raw}' (use @hourly, @daily, @weekly, @monthly or @yearly)"
    _five = _shorthands[_raw.lower()] if _raw.startswith("@") else _raw
    _f = _five.split()
    assert len(_f) == 5, "backup-aws: schedule must be a five-field cron expression, got '${expr}'"
    assert _f[0].isdigit() and int(_f[0]) <= 59, "backup-aws: AWS Backup runs at most hourly, so the minute field of '${expr}' must be a single value 0-59, got '${_f[0]}'"
    _dom_any = _f[2] in ["*", "?"]
    _dow_any = _f[4] in ["*", "?"]
    assert _dom_any or _dow_any, "backup-aws: schedule '${expr}' restricts both day-of-month and day-of-week; cron runs when EITHER matches, while AWS cron needs one of them to be '?', so it cannot be translated"
    _dom = ("*" if _dom_any else _f[2]) if _dow_any else "?"
    _dow = "?" if _dow_any else ",".join([dow_element(_p) for _p in _f[4].split(",")])
    "cron(${_f[0]} ${_f[1]} ${_dom} ${_f[3].upper()} ${_dow} *)"
}

# ---- spec.paused ------------------------------------------------------------

# Pausing withdraws the Selection: the Plan and every recovery point stay, AWS
# just has nothing left to back up. Under deletionPolicy Orphan the Selection
# carries no Delete policy, so simply dropping it would orphan it in AWS and
# the backups would carry on. It is therefore kept for one more pass with full
# management, and dropped (and so deleted in AWS) once the observed object
# shows the policy took.
#   active      — composed with the XR's policies
#   withdrawing — paused under Orphan, composed with ["*"] until observed so
#   absent      — not composed
selection_state = lambda oxr, ocds -> str {
    _spec = oxr.spec
    _orphan = (_spec?.deletionPolicy or "Delete") == "Orphan"
    _obs = (ocds["selection"]?.Resource) if ("selection" in ocds) else Undefined
    _policies = (_obs?.spec?.managementPolicies or ["*"]) if _obs else []
    _deletable = "*" in _policies or "Delete" in _policies
    "active" if not (_spec?.paused or False) else ("withdrawing" if _orphan and _obs and not _deletable else "absent")
}

# composition-resource-name -> kind, in dependency order (status reports the
# first one that is not Ready).
_kinds = {
    "vault" = "Vault"
    "role" = "Role"
    "role-backup" = "RolePolicyAttachment"
    "role-restore" = "RolePolicyAttachment"
    "managed" = "Plan"
    "selection" = "Selection"
}

composed_names = lambda oxr, ocds -> [str] {
    [_n for _n in _kinds if _n != "selection" or selection_state(oxr, ocds) != "absent"]
}

# ---- render -----------------------------------------------------------------
render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name

    # The vault name is pinned to the XR name, and vault, plan, rule and
    # selection names all share AWS's [A-Za-z0-9_-]{2,50} (the vault's is the
    # strictest), while a Kubernetes name may carry dots and run to 253.
    assert regex.match(_name, r"^[A-Za-z0-9_-]{2,50}$"), "backup-aws: metadata.name '${_name}' names the backup vault, which AWS limits to 2-50 letters, digits, '-' and '_'"
    assert _spec?.cluster?.id, "backup-aws: spec.cluster.id is required — the ARN of the EKS cluster to protect (arn:aws:eks:<region>:<account>:cluster/<name>)"
    _c = cluster_of(_spec.cluster.id)
    _region = _c.region
    _kms = _spec?.encryptionKmsKeyId or ""
    assert not _kms or regex.match(_kms, r"^arn:aws[a-z-]*:kms:"), "backup-aws: encryptionKmsKeyId becomes the vault's kmsKeyArn and must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>), got '${_kms}'"
    _tags = _spec?.tags or {}
    _schedule = aws_schedule(_spec.schedule)
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _sel = selection_state(oxr, ocds)
    _xr = "${oxr.metadata?.namespace or 'default'}/${_name}"

    _policy = lambda which: str -> str {
        "arn:${_c.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyFor${which}"
    }

    _items: [any] = [vault.Vault {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "vault"
            # The vault has no forProvider name: its AWS name IS the external
            # name. Pinned so status.storageLocation is known up front.
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        # Encrypts the EKS cluster-state recovery points; nested volume
        # recovery points keep their own storage's encryption (EBS/EFS/S3).
        if _kms:
            spec.forProvider.kmsKeyArn = _kms
        # forceDestroy is deliberately never set: deleting a plan must not purge
        # the recovery points it took. With Delete the vault waits (stuck) until
        # they expire or are deleted by hand.
        if _tags:
            spec.forProvider.tags = _tags
    }]

    # A role of our own rather than the AWSServiceRoleForBackup service-linked
    # role: an EKS backup works by creating an EKS access entry for the role it
    # runs as, and the service-linked role is not allowed to create one. The
    # name is left to Crossplane (the generated metadata.name): IAM is global,
    # so an XR-derived name would collide across regions and namespaces.
    _items += [role.Role {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "role"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.assumeRolePolicy = json.encode({
            Version = "2012-10-17"
            Statement = [{Effect = "Allow", Principal = {Service = "backup.amazonaws.com"}, Action = "sts:AssumeRole"}]
        })
        spec.forProvider.description = "AWS Backup service role for BackupPlan ${_xr} (EKS cluster ${_c.name})"
    }]

    # Backup covers the EKS cluster state plus its EBS and EFS volumes (and the
    # access entry it needs); Restores is what `aws backup start-restore-job`
    # runs as when handed this role.
    _items += [attachment.RolePolicyAttachment {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "role-${_w.name}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.policyArn = _policy(_w.policy)
        spec.forProvider.roleSelector.matchControllerRef = True
    } for _w in [{name = "backup", policy = "Backup"}, {name = "restore", policy = "Restores"}]]

    _items += [plan.Plan {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.name = _name
        spec.forProvider.$rule = [{
            ruleName = _name
            # The only Vault this composite owns.
            targetVaultNameSelector.matchControllerRef = True
            schedule = _schedule
            # Explicit, because the XRD promises UTC.
            scheduleExpressionTimezone = "Etc/UTC"
            lifecycle.deleteAfter = _spec?.retentionDays or 30
            if _tags:
                recoveryPointTags = _tags
        }]
        if _tags:
            spec.forProvider.tags = _tags
    }]

    if _sel != "absent":
        _items += [selection.Selection {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "selection"}
            if _sel == "withdrawing":
                spec.managementPolicies = ["*"]
            elif _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.name = _name
            spec.forProvider.planIdSelector.matchControllerRef = True
            spec.forProvider.iamRoleArnSelector.matchControllerRef = True
            spec.forProvider.resources = [_spec.cluster.id]
        }]

    _items
}

# ---- status -----------------------------------------------------------------

# Build the desired composite carrying observed status back to the XR.
# AWS Backup reports no plan state of its own, so readiness is the
# Crossplane view: every composed managed resource Ready, and the message names
# the first one that is not — the Selection last, since it is the one that
# fails when the role or plan behind it is broken.
status = lambda oxr, ocds {
    _ready_cond = lambda n: str -> any {
        _conds = (ocds[n]?.Resource?.status?.conditions or []) if n in ocds else []
        _r = [_c for _c in _conds if _c?.type == "Ready"]
        _r[0] if _r else Undefined
    }
    _why = lambda n: str -> str {
        _cond = _ready_cond(n)
        _what = ("not created yet" if n not in ocds else ("waiting for its Ready condition" if not _cond else (_cond?.message or _cond?.reason or "not Ready")))
        "${n} (${_kinds[n]}): ${_what}"
    }
    _pending = [_n for _n in composed_names(oxr, ocds) if (_ready_cond(_n)?.status or "") != "True"]

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "BackupPlan"
        metadata.name = oxr.metadata.name
        status = {
            provider = "aws"
            ready = len(_pending) == 0
            # The vault's external name is pinned to the XR name.
            storageLocation = oxr.metadata.name
            if _pending:
                message = _why(_pending[0])
        }
    }
}
