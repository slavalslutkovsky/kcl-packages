"""
Cloud Build: the plan as a build config (`gcloud builds submit --config`) or as Crossplane
Trigger MRs carrying the same build inline. A trigger takes push OR pull request, so each
event gets its own Trigger: <name>-push and <name>-pr.

Steps run sequentially, in plan order. Every step is `<shell> -c <script>`. `$` in scripts and
env values is escaped as `$$`, so Cloud Build substitutes only GIT_SHA=$COMMIT_SHA (and
$PROJECT_ID in secret names). The push happens in a step and not through `images:`, because
with immutable tags an existing image is not pushed again. The tradeoff: the build records no
image digest or provenance for it.

A secret (`secrets: {ENV: <secret id>}`) is read from Secret Manager in the build's project:
projects/$PROJECT_ID/secrets/<id>/versions/latest.
"""
import .lib
import gcp_cloudbuild.models.v1beta1.cloudbuild_gcpm_upbound_io_v1beta1_trigger as cbt

_cbEsc = lambda s: str -> str {
    s.replace("$", "$$")
}

_cbSteps = lambda p: lib.Pipeline -> [{str:}] {
    _plan = lib.plan(p)
    [{
        id = _s.id
        name = _s.image
        entrypoint = _s.shell
        args = ["-c", _cbEsc(_s.script)]
        env = ["GIT_SHA=$COMMIT_SHA"] + ["${_k}=${_cbEsc(_v)}" for _k, _v in _plan.env | _s.env]
        secretEnv = [_k for _k in _s.secrets] or Undefined
        allowFailure = True if _s.allowFailure else Undefined
    } for _s in _plan.steps]
}

# Everything of the build except its steps, whose field name differs: `steps` in a config
# file, `step` in a Trigger.
_cbRest = lambda p: lib.Pipeline -> {str:} {
    _secrets = {_k: _v for _s in lib.plan(p).steps for _k, _v in _s.secrets}
    {
        timeout = "${p.timeoutMinutes * 60}s"
        options = {
            logging = p.cloudBuild.logging
            machineType = p.cloudBuild.machineType or Undefined
        }
        availableSecrets = {
            secretManager = [{env = _k, versionName = "projects/$PROJECT_ID/secrets/${_v}/versions/latest"} for _k, _v in _secrets]
        } if _secrets else Undefined
        tags = [p.name]
    }
}

config = lambda p: lib.Pipeline -> {str:} {
    {steps = _cbSteps(p)} | _cbRest(p)
}

_cbTrigger = lambda p: lib.Pipeline, event: str -> cbt.Trigger {
    _t = p.cloudBuild.trigger
    _push = event == "push"
    _name = p.name + ("-push" if _push else "-pr")
    _branches = p.triggers.push.branches if _push else p.triggers.pullRequest.branches
    # Fork pull requests wait for a maintainer's /gcbrun: the build runs as the trigger's
    # service account.
    _filter = {branch = lib.branchRegex(_branches)} | ({} if _push else {commentControl = "COMMENTS_ENABLED_FOR_EXTERNAL_CONTRIBUTORS_ONLY"})
    _event = {push = _filter} if _push else {pullRequest = _filter}
    cbt.Trigger {
        metadata = {name = _name, namespace = _t.namespace}
        spec = {
            providerConfigRef = {kind = _t.providerConfigKind, name = _t.providerConfig}
            forProvider = {
                project = _t.project
                location = _t.location
                name = _name
                description = "${p.name}: build, scan and push ${p.image.repository} on ${'push' if _push else 'pull request'} (ci-pipeline)"
                serviceAccount = "projects/-/serviceAccounts/${_t.serviceAccount}"
                github = {owner = p.repo.owner, name = p.repo.name} | _event if not _t.repository else Undefined
                repositoryEventConfig = {repository = _t.repository} | _event if _t.repository else Undefined
                includedFiles = p.triggers.paths or Undefined
                build = {step = _cbSteps(p)} | _cbRest(p)
            }
        }
    }
}

triggers = lambda p: lib.Pipeline -> [cbt.Trigger] {
    assert p.cloudBuild.trigger, "Trigger output needs cloudBuild.trigger (project, serviceAccount)"
    _events = (["push"] if p.triggers.push else []) + (["pullRequest"] if p.triggers.pullRequest else [])
    [_cbTrigger(p, _e) for _e in _events]
}
