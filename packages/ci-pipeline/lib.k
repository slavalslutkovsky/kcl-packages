"""
ci-pipeline: one typed container-image pipeline, rendered for every CI it runs on.

  pipeline.yaml ──► Pipeline (typed; an unknown key fails)
                      │
                      └─ plan ──► steps. Each step is a container: image, shell, script, env, secrets
                           resolve   if the tag exists (immutable tags), pull it, do not rebuild
                           pull-base base images, from their mirrors (Artifact Registry remote repos)
                           build     docker build, each base image a --build-arg naming its mirror copy
                           export    docker save, only when a scanner reads archives
                           scan-*    scan.k: one step per scanner and target
                           push      docker push (skipped when the tag already existed)
                                │
                 cloudbuild.k ──┼─► Cloud Build config (gcloud builds submit --config)
                                │└► Crossplane Trigger MRs (cloudbuild.gcp.m.upbound.io/v1beta1)
                 gha.k ─────────┴─► GitHub Actions workflow (one job; steps run in containers via docker run)

THE COMMIT IS THE TAG. Every step sees GIT_SHA (Cloud Build: $COMMIT_SHA. Actions: the PR
head, else the pushed sha) and IMAGE_REPO. Each script sets IMAGE=$IMAGE_REPO:$GIT_SHA itself,
so no CI's expression syntax appears in a script.

NOTHING IS PULLED FROM UPSTREAM DIRECTLY. Every image a step runs in, and every base image, is
rewritten to its mirror (`mirrors`: upstream registry -> Artifact Registry remote repository).
With `requireMirror` (the default), an image whose registry has no mirror fails the render.
The one exception is the push target's own registry.
"""
import regex
import .scan as sc

_LB_STATE = ".ci-pipeline"

# Every script starts here: fail fast, and refuse to run without the commit.
_LB_PRELUDE = """set -eu
: "\${GIT_SHA:?GIT_SHA, the commit to build, is empty}"
IMAGE="$IMAGE_REPO:$GIT_SHA"
"""

_LB_SKIP_IF_EXISTS = """if [ -e ${_LB_STATE}/exists ]; then echo "$IMAGE already exists: not rebuilt, not pushed"; exit 0; fi
"""

schema Repo:
    owner: str
    name: str

schema Branches:
    """branches: GitHub-style globs (`main`, `release/**`)"""
    branches: [str] = ["main"]

schema Triggers:
    """
    push / pullRequest   the events that run the pipeline, filtered by target branch
    paths                globs. Only commits that change a matching path run it (both events)
    """
    push?: Branches
    pullRequest?: Branches
    paths?: [str]

    check:
        push or pullRequest, "triggers: at least one of push and pullRequest"

schema Image:
    """
    repository     push target without a tag: <host>/<path>. The tag is the commit sha
    context        build context, relative to the repository root
    dockerfile     default <context>/Dockerfile
    platform       --platform of the build
    baseImages     Dockerfile ARG -> upstream image. The build passes the mirror copy as the ARG
    immutableTags  an existing tag is pulled and scanned, never rebuilt or pushed again
    """
    repository: str
    context: str
    dockerfile?: str
    platform: str = "linux/amd64"
    baseImages: {str:str} = {}
    immutableTags: bool = True

    check:
        regex.match(repository, r"^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+$"), "image.repository is <host>/<path> without a tag: ${repository}"
        all_true([regex.match(_k, r"^[A-Za-z_][A-Za-z0-9_]*$") for _k in baseImages]), "image.baseImages keys are Dockerfile ARG names"

schema Tools:
    """docker: the image of the resolve, pull, build, export and push steps"""
    docker: str = "gcr.io/cloud-builders/docker:24.0.9"

schema CloudBuildTrigger:
    """
    project             project the trigger and its builds live in
    serviceAccount      email of the identity builds run as (user-specified service account)
    location            `global` for the GitHub App (1st gen) connection. A 2nd-gen
                        `repository` sets the location to the region of its connection
    repository          2nd gen: projects/<p>/locations/<l>/connections/<c>/repositories/<r>.
                        Unset: 1st-gen GitHub App on repo.owner/repo.name
    namespace           namespace of the Trigger MRs (namespaced, Crossplane v2)
    providerConfig      ProviderConfig name and kind
    """
    project: str
    serviceAccount: str
    location: str = "global"
    repository?: str
    namespace: str = "default"
    providerConfig: str = "default"
    providerConfigKind: "ProviderConfig" | "ClusterProviderConfig" = "ProviderConfig"

    check:
        regex.match(serviceAccount, r"^[^@\s]+@[^@\s]+$"), "cloudBuild.trigger.serviceAccount is an email: ${serviceAccount}"

schema CloudBuild:
    """
    machineType   options.machineType, e.g. E2_HIGHCPU_8. Unset: the default pool's machine
    logging       options.logging. A user-specified service account needs CLOUD_LOGGING_ONLY
                  (or a logs bucket)
    trigger       set to render Trigger MRs (-D target=cloudbuild-trigger)
    """
    machineType?: str
    logging: str = "CLOUD_LOGGING_ONLY"
    trigger?: CloudBuildTrigger

schema GitHub:
    """
    runner                    runs-on
    workloadIdentityProvider  google-github-actions/auth inputs. Defaults are the Actions
    serviceAccount            variables infra `bootstrap` writes into application repos
    actions                   pinned action refs: checkout, auth, login
    """
    runner: str = "ubuntu-latest"
    workloadIdentityProvider: str = "\${{ vars.GCP_WIF_PROVIDER }}"
    serviceAccount: str = "\${{ vars.GCP_SA }}"
    actions: {str:str} = {
        checkout = "actions/checkout@v7"
        auth = "google-github-actions/auth@v2"
        login = "docker/login-action@v3"
    }

schema Pipeline:
    name: str
    repo: Repo
    triggers: Triggers
    image: Image
    mirrors: {str:str} = {}
    requireMirror: bool = True
    scan?: sc.Scan
    tools: Tools = Tools {}
    timeoutMinutes: int = 60
    cloudBuild: CloudBuild = CloudBuild {}
    github: GitHub = GitHub {}

    check:
        regex.match(name, r"^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$"), "name is a DNS label of at most 42 characters: ${name}"
        all_true([regex.match(_m, r"^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+$") for _, _m in mirrors]), "mirrors map an upstream registry to <host>/<path>"

# ── Images and mirrors ───────────────────────────────────────────────────────
host = lambda ref: str -> str {
    ref.split("/")[0]
}

# docker.io/library/rust:1, library/rust:1 and rust:1 are the same image.
_lbSplit = lambda ref: str -> {str:str} {
    _first = host(ref)
    _hasRegistry = "/" in ref and ("." in _first or ":" in _first or _first == "localhost")
    _registry = _first if _hasRegistry else "docker.io"
    _path = ref[len(_first) + 1:] if _hasRegistry else ref
    {
        registry = _registry
        path = "library/" + _path if _registry == "docker.io" and "/" not in _path else _path
    }
}

# `ref` as pulled through its mirror.
mirror = lambda p: Pipeline, ref: str -> str {
    _r = _lbSplit(ref)
    _m = p.mirrors[_r.registry] if _r.registry in p.mirrors else ""
    assert _m or not p.requireMirror or _r.registry == host(p.image.repository), "${ref}: no mirror for registry ${_r.registry} (add it to `mirrors`, or set requireMirror: false)"
    _m.rstrip("/") + "/" + _r.path if _m else ref
}

_lbSlug = lambda s: str -> str {
    regex.replace(s.lower(), r"[^a-z0-9-]+", "-").strip("-")
}

# A GitHub branch glob list as one RE2 regex (Cloud Build trigger filters).
branchRegex = lambda branches: [str] -> str {
    _one = lambda b: str -> str {
        regex.replace(regex.replace(regex.replace(regex.replace(b, r"([.+()^$|{}\[\]\\])", r"\$1"), r"\*\*", "<DSTAR>"), r"\*", "[^/]*"), "<DSTAR>", ".*").replace("?", ".")
    }
    "^(" + "|".join([_one(_b) for _b in branches]) + ")$"
}

# ── Plan ─────────────────────────────────────────────────────────────────────
# env: what every step gets besides GIT_SHA. steps: in order, every image already mirrored.
# registries: hosts of every image pulled or pushed (a CI target logs in to its own).
plan = lambda p: Pipeline -> {str:} {
    _bases = [{arg = _k, ref = mirror(p, _v)} for _k, _v in p.image.baseImages]
    _dockerfile = p.image.dockerfile or p.image.context.rstrip("/") + "/Dockerfile"
    _baseMode = p.scan.baseImages if p.scan else "skip"
    _targets = [{
        name = _t.name
        ref = _t.ref
        mode = _t.mode
        archive = "${_LB_STATE}/scan/${_t.name}.tar"
    } for _t in [{name = "base-" + _lbSlug(_b.arg), ref = _b.ref, mode = _baseMode} for _b in _bases] + [{name = "image", ref = "$IMAGE", mode = "gate"}] if _t.mode != "skip"]
    _scans = sc.scanSteps(p.scan, _targets) if p.scan else []
    _archives = [_t for _t in _targets if any_true([_s.input == "archive" for _s in _scans])]
    _resolve = [{
        id = "resolve"
        image = p.tools.docker
        script = """mkdir -p ${_LB_STATE}
rm -f ${_LB_STATE}/exists
if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
  echo "$IMAGE exists and tags are immutable: pulling it to scan, not rebuilding"
  docker pull "$IMAGE"
  touch ${_LB_STATE}/exists
fi
"""
    }] if p.image.immutableTags else []
    _pull = [{
        id = "pull-base"
        image = p.tools.docker
        script = "".join(["docker pull ${_b.ref}\n" for _b in _bases])
    }] if _bases else []
    _build = [{
        id = "build"
        image = p.tools.docker
        env = {DOCKER_BUILDKIT = "1"}
        script = _LB_SKIP_IF_EXISTS + "docker build --platform ${p.image.platform} \\\n" + "".join(["  --build-arg ${_b.arg}=${_b.ref} \\\n" for _b in _bases]) + "  -f ${_dockerfile} -t \"$IMAGE\" ${p.image.context}\n"
    }]
    # Archives are world-readable: some scanners run as nonroot.
    _export = [{
        id = "export"
        image = p.tools.docker
        script = "mkdir -p ${_LB_STATE}/scan\n" + "".join(["docker save -o ${_t.archive} \"${_t.ref}\"\n" for _t in _archives]) + "chmod a+r ${_LB_STATE}/scan/*.tar\n"
    }] if _archives else []
    _push = [{
        id = "push"
        image = p.tools.docker
        script = _LB_SKIP_IF_EXISTS + "docker push \"$IMAGE\"\n"
    }]
    _steps = [{
        id = _s.id
        image = mirror(p, _s.image)
        shell = _s.shell or "sh"
        # Exactly one trailing newline: the Actions heredoc terminator must start its own line.
        script = _LB_PRELUDE + _s.script.rstrip("\n") + "\n"
        env = _s.env or {}
        secrets = _s.secrets or {}
        allowFailure = _s.allowFailure or False
    } for _s in _resolve + _pull + _build + _export + _scans + _push]
    _hosts = [host(_r) for _r in [_s.image for _s in _steps] + [_b.ref for _b in _bases] + [p.image.repository]]
    {
        env = {IMAGE_REPO = p.image.repository}
        steps = _steps
        registries = [_h for _i, _h in _hosts if _h not in _hosts[:_i]]
    }
}
