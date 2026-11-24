# Tests for ci-pipeline: mirrors, the scan module, immutable tags, and each CI rendering.
# Run: kcl test
import runtime
import .lib
import .cloudbuild
import .gha

_fxBase = {
  name = "app"
  repo = {owner = "o", name = "r"}
  triggers = {push = {branches = ["main"]}, pullRequest = {branches = ["main"]}, paths = ["apps/app/**"]}
  image = {
    repository = "me-west1-docker.pkg.dev/p/docker/app"
    context = "apps/app"
    baseImages = {BUILD = "rust:1", RUN = "gcr.io/distroless/cc-debian12:nonroot"}
  }
  mirrors = {"docker.io" = "me-west1-docker.pkg.dev/p/docker-hub", "gcr.io" = "me-west1-docker.pkg.dev/p/gcr"}
  scan = {scanners = [{use = "ods"}]}
}

_fxP = lambda _fxOver: {str:} -> lib.Pipeline {
  lib.Pipeline {**({_k: _v for _k, _v in _fxBase if _k not in _fxOver} | _fxOver)}
}

_fxImage = lambda _fxOver: {str:} -> {str:} {
  {_k: _v for _k, _v in _fxBase.image if _k not in _fxOver} | _fxOver
}

_fxStep = lambda _fxPl: lib.Pipeline, _fxId: str -> {str:} {
  [_s for _s in lib.plan(_fxPl).steps if _s.id == _fxId][0]
}

_fxIds = lambda _fxPl: lib.Pipeline -> [str] {
  [_s.id for _s in lib.plan(_fxPl).steps]
}

# ── Mirrors ──────────────────────────────────────────────────────────────────
test_base_and_tool_images_come_from_mirrors = lambda {
  _p = _fxP({})
  _build = _fxStep(_p, "build").script
  assert "--build-arg BUILD=me-west1-docker.pkg.dev/p/docker-hub/library/rust:1 " in _build, _build
  assert "--build-arg RUN=me-west1-docker.pkg.dev/p/gcr/distroless/cc-debian12:nonroot " in _build, _build
  assert all_true([_s.image.startswith("me-west1-docker.pkg.dev/p/") for _s in lib.plan(_p).steps]), "every step image is pulled through a mirror"
  assert lib.plan(_p).registries == ["me-west1-docker.pkg.dev"]
}

test_unmirrored_registry_fails_unless_allowed = lambda {
  _e = runtime.catch(lambda {
    lib.plan(_fxP({image = _fxImage({
      baseImages = {X = "quay.io/a/b:1"}
    })}))
  })
  assert "no mirror for registry quay.io" in _e, _e
  _p = _fxP({image = _fxImage({
    baseImages = {X = "quay.io/a/b:1"}
  }), requireMirror = False})
  assert "--build-arg X=quay.io/a/b:1 " in _fxStep(_p, "build").script
}

test_push_registry_needs_no_mirror = lambda {
  _p = _fxP({image = _fxImage({
    baseImages = {X = "me-west1-docker.pkg.dev/p/docker/base:1"}
  })})
  assert "--build-arg X=me-west1-docker.pkg.dev/p/docker/base:1 " in _fxStep(_p, "build").script
}

test_branch_globs_become_one_regex = lambda {
  assert lib.branchRegex(["main", "release/**", "v*.x"]) == r"^(main|release/.*|v[^/]*\.x)$"
}

# ── Scan ─────────────────────────────────────────────────────────────────────
test_base_images_report_before_the_image_gates_the_push = lambda {
  _p = _fxP({})
  assert _fxIds(_p) == ["resolve", "pull-base", "build", "scan-ods-base-build", "scan-ods-base-run", "scan-ods-image", "push"], "${_fxIds(_p)}"
  assert _fxStep(_p, "scan-ods-base-build").allowFailure
  assert not _fxStep(_p, "scan-ods-image").allowFailure
  _gate = _fxStep(_p, "scan-ods-image").script
  assert "images scan \"$IMAGE\"" in _gate, _gate
  assert "grep -Ecx 'CRITICAL'" in _gate, "default failOn is CRITICAL"
  assert "grep -Ecx" not in _fxStep(_p, "scan-ods-base-build").script, "report steps do not gate"
  _high = _fxP({
    scan = {failOn = "HIGH", scanners = [{use = "ods"}]}
  })
  assert "grep -Ecx 'HIGH|CRITICAL'" in _fxStep(_high, "scan-ods-image").script
  _skip = _fxP({
    scan = {baseImages = "skip", scanners = [{use = "ods"}]}
  })
  assert [_i for _i in _fxIds(_skip) if _i.startswith("scan-")] == ["scan-ods-image"]
}

test_archives_are_exported_only_for_archive_scanners = lambda {
  assert "export" not in _fxIds(_fxP({})), "ods reads the daemon"
  _p = _fxP({
    scan = {failOn = "HIGH", scanners = [{use = "trivy"}, {use = "grype"}]}
  })
  _export = _fxStep(_p, "export").script
  assert "docker save -o .ci-pipeline/scan/image.tar \"$IMAGE\"" in _export, _export
  assert "docker save -o .ci-pipeline/scan/base-build.tar \"me-west1-docker.pkg.dev/p/docker-hub/library/rust:1\"" in _export, _export
  assert "--exit-code 1 --severity HIGH,CRITICAL\n" in _fxStep(_p, "scan-trivy-image").script
  _grype = _fxStep(_p, "scan-grype-image")
  assert _grype.shell == "/busybox/sh" and _grype.image == "me-west1-docker.pkg.dev/p/docker-hub/anchore/grype:v0.122.1-debug"
  assert "--fail-on high\n" in _grype.script
}

test_ignore_unfixed_needs_a_flag_on_every_scanner = lambda {
  _p = _fxP({
    scan = {ignoreUnfixed = True, scanners = [{use = "trivy"}, {use = "ods"}]}
  })
  assert "--ignore-unfixed" in _fxStep(_p, "scan-trivy-image").script
  assert "--filter=vulnerability.fixAvailable=true" in _fxStep(_p, "scan-ods-image").script
  _e = runtime.catch(lambda {
    lib.plan(_fxP({
      scan = {ignoreUnfixed = True, scanners = [{use = "snyk"}]}
    }))
  })
  assert "have no flag for it" in _e, _e
}

test_custom_scanner_and_preset_overrides = lambda {
  _p = _fxP({
    scan = {scanners = [
      {name = "acme", image = "acme/scan:1", input = "archive", report = "acme \"{archive}\"", gate = "acme \"{archive}\" --min {threshold} --list {severityRegex}", secrets = {ACME_KEY = "acme-key"}}
      {use = "ods", env = {ODS_LOCATION = "us"}}
    ]}
  })
  _s = _fxStep(_p, "scan-acme-image")
  assert _s.image == "me-west1-docker.pkg.dev/p/docker-hub/acme/scan:1"
  assert _s.script.endswith("acme \".ci-pipeline/scan/image.tar\" --min critical --list CRITICAL\n"), _s.script
  assert _s.secrets == {ACME_KEY = "acme-key"}
  assert _fxStep(_p, "scan-ods-image").env == {ODS_LOCATION = "us"}
  _e = runtime.catch(lambda {
    lib.plan(_fxP({
      scan = {scanners = [{use = "ods"}, {use = "ods"}]}
    }))
  })
  assert "repeat" in _e, _e
}

# ── Immutable tags ───────────────────────────────────────────────────────────
test_an_existing_tag_is_scanned_not_rebuilt = lambda {
  _p = _fxP({})
  assert "docker manifest inspect \"$IMAGE\"" in _fxStep(_p, "resolve").script
  assert "if [ -e .ci-pipeline/exists ]; then" in _fxStep(_p, "build").script
  assert "if [ -e .ci-pipeline/exists ]; then" in _fxStep(_p, "push").script
  assert "exists" not in _fxStep(_p, "scan-ods-image").script, "scans run either way"
  _m = _fxP({image = _fxImage({immutableTags = False})})
  assert "resolve" not in _fxIds(_m)
  assert "exists" not in _fxStep(_m, "push").script
}

# ── Cloud Build ──────────────────────────────────────────────────────────────
test_cloudbuild_escapes_scripts_and_substitutes_the_commit = lambda {
  _p = _fxP({scan = {scanners = [{use = "snyk"}]}, cloudBuild = {machineType = "E2_HIGHCPU_8"}})
  _c = cloudbuild.config(_p)
  _plan = lib.plan(_p)
  assert all_true([_s.env[0] == "GIT_SHA=$COMMIT_SHA" for _s in _c.steps])
  assert all_true(["$" not in _s.args[1].replace("$$", "") for _s in _c.steps]), "every $ in a script is escaped"
  assert [_s.args[1].replace("$$", "$") for _s in _c.steps] == [_s.script for _s in _plan.steps]
  assert _c.options == {logging = "CLOUD_LOGGING_ONLY", machineType = "E2_HIGHCPU_8"}
  assert _c.timeout == "3600s"
  assert _c.availableSecrets.secretManager == [{env = "SNYK_TOKEN", versionName = "projects/$PROJECT_ID/secrets/snyk-token/versions/latest"}]
  _snyk = [_s for _s in _c.steps if _s.id == "scan-snyk-image"][0]
  assert _snyk.secretEnv == ["SNYK_TOKEN"] and not _snyk.allowFailure
  assert [_s for _s in _c.steps if _s.id == "scan-snyk-base-run"][0].allowFailure == True
}

test_triggers_one_per_event = lambda {
  _p = _fxP({
    cloudBuild = {
      trigger = {project = "ci", serviceAccount = "cb@ci.iam.gserviceaccount.com"}
    }
  })
  _ts = cloudbuild.triggers(_p)
  assert [_t.metadata.name for _t in _ts] == ["app-push", "app-pr"]
  _push = _ts[0].spec.forProvider
  _pr = _ts[1].spec.forProvider
  assert _push.github.push.branch == "^(main)$" and not _push.github.pullRequest
  assert _pr.github.pullRequest.commentControl == "COMMENTS_ENABLED_FOR_EXTERNAL_CONTRIBUTORS_ONLY"
  assert _push.includedFiles == ["apps/app/**"]
  assert _push.serviceAccount == "projects/-/serviceAccounts/cb@ci.iam.gserviceaccount.com"
  assert len(_push.build.step) == len(cloudbuild.config(_p).steps)
  _gen2 = _fxP({
    cloudBuild = {
      trigger = {project = "ci", serviceAccount = "cb@ci.iam.gserviceaccount.com", location = "me-west1", repository = "projects/ci/locations/me-west1/connections/gh/repositories/r"}
    }
  })
  _f = cloudbuild.triggers(_gen2)[0].spec.forProvider
  assert _f.repositoryEventConfig.repository == "projects/ci/locations/me-west1/connections/gh/repositories/r" and not _f.github
  _e = runtime.catch(lambda {
    cloudbuild.triggers(_fxP({}))
  })
  assert "needs cloudBuild.trigger" in _e, _e
}

# ── GitHub Actions ───────────────────────────────────────────────────────────
test_gha_runs_each_step_in_its_image = lambda {
  _p = _fxP({
    scan = {scanners = [{use = "snyk"}]}
  })
  _w = gha.workflow(_p)
  _job = _w.jobs.app
  assert _job["if"], "fork pull requests are skipped"
  assert _w["on"].pull_request.paths == ["apps/app/**"]
  assert [_s.uses for _s in _job.steps[:3:]] == ["actions/checkout@v7", "google-github-actions/auth@v2", "docker/login-action@v3"]
  _snyk = [_s for _s in _job.steps if _s.name == "scan-snyk-image"][0]
  assert _snyk.env.SNYK_TOKEN == "$" + "{{ secrets.SNYK_TOKEN }}"
  assert "  -e SNYK_TOKEN \\\n" in _snyk.run
  assert "--entrypoint sh me-west1-docker.pkg.dev/p/docker-hub/snyk/snyk:docker -s <<'CI_PIPELINE_STEP'\n" in _snyk.run
  assert _snyk.run.endswith("\nCI_PIPELINE_STEP\n")
  assert [_s for _s in _job.steps if _s.name == "scan-snyk-base-run"][0]["continue-on-error"] == True
  _pushOnly = gha.workflow(_fxP({
    triggers = {
      push = {branches = ["main"]}
    }
  }))
  assert not _pushOnly.jobs.app["if"] and not _pushOnly["on"].pull_request
}
