"""
GitHub Actions: the plan as one workflow with one job.

Actions steps run on the runner, not in an image. Each plan step therefore runs through
`docker run` with its own image. Its script arrives on stdin through a quoted heredoc, so the
runner's shell expands nothing in it. Inside the container:

  /var/run/docker.sock   the runner's daemon, for build, pull, save and push
  DOCKER_CONFIG          a copy of the runner's ~/.docker (registry logins)
  $GITHUB_WORKSPACE      mounted at the same path and used as the working directory. Paths
                         in scripts, and the gcloud credentials file written by
                         google-github-actions/auth, stay valid

Identity: Workload Identity Federation (`github.workloadIdentityProvider`, `serviceAccount`),
then a docker login to every Artifact Registry host the plan pulls from or pushes to. A
`docker://` step cannot do this, because Actions pulls those images before the first step,
which is before any login.

Fork pull requests are skipped: they get no OIDC token. GIT_SHA is the PR head (what the PR
shows), not GitHub's merge commit. A secret `ENV` is read from the repository secret `ENV`.
"""

import regex
import .lib

_GH_SHA = "\${{ github.event.pull_request.head.sha || github.sha }}"

# Exported by google-github-actions/auth; gcloud inside a step needs them.
_GH_PASSTHROUGH = ["GOOGLE_APPLICATION_CREDENTIALS", "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", "CLOUDSDK_CORE_PROJECT"]

_ghRun = lambda s: {str:}, names: [str] -> str {
  """cfg=$(mktemp -d)
if [ -f "$HOME/.docker/config.json" ]; then cp "$HOME/.docker/config.json" "$cfg/"; fi
docker run --rm -i --network host \\
  -v /var/run/docker.sock:/var/run/docker.sock \\
  -v "$cfg:/ci-docker-config" -e DOCKER_CONFIG=/ci-docker-config \\
  -v "$GITHUB_WORKSPACE:$GITHUB_WORKSPACE" -w "$GITHUB_WORKSPACE" \\
""" + "".join(["  -e ${_n} \\\n" for _n in names]) + "  --entrypoint ${s.shell} ${s.image} -s <<'CI_PIPELINE_STEP'\n" + s.script + "CI_PIPELINE_STEP\n"
}

workflow = lambda p: lib.Pipeline -> {str:} {
  _plan = lib.plan(p)
  _open = "$" + "{{"
  _expr = [_s.id for _s in _plan.steps if _open in _s.script]
  assert not _expr, "step(s) ${_expr}: a script must not contain " + _open + ", which Actions would evaluate"
  _on = {
    push = {branches = p.triggers.push.branches, paths = p.triggers.paths or Undefined} if p.triggers.push else Undefined
    pull_request = {branches = p.triggers.pullRequest.branches, paths = p.triggers.paths or Undefined} if p.triggers.pullRequest else Undefined
  }
  _ar = [_h for _h in _plan.registries if regex.match(_h, r"^[a-z0-9-]+-docker\.pkg\.dev$")]
  _job = {
    "if" = "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository" if p.triggers.pullRequest else Undefined
    "runs-on" = p.github.runner
    "timeout-minutes" = p.timeoutMinutes
    env = {GIT_SHA = _GH_SHA} | _plan.env
    steps = [
      {uses = p.github.actions.checkout, "with" = {ref = _GH_SHA}}
      {
        id = "auth"
        uses = p.github.actions.auth
        "with" = {
          workload_identity_provider = p.github.workloadIdentityProvider
          service_account = p.github.serviceAccount
          token_format = "access_token"
        }
      }
    ] + [{
      uses = p.github.actions.login
      "with" = {
        registry = _h
        username = "oauth2accesstoken"
        password = "\${{ steps.auth.outputs.access_token }}"
      }
    } for _h in _ar] + [{
      name = _s.id
      env = _s.env | {_k: _open + " secrets." + _k + " }}" for _k in _s.secrets} or Undefined
      run = _ghRun(_s, ["GIT_SHA"] + [_k for _k in _plan.env] + [_k for _k in _s.env] + [_k for _k in _s.secrets] + _GH_PASSTHROUGH)
      "continue-on-error" = True if _s.allowFailure else Undefined
    } for _s in _plan.steps]
  }
  {
    name = p.name
    "on" = _on
    permissions = {contents = "read", "id-token" = "write"}
    jobs = {"${p.name}" = _job}
  }
}
