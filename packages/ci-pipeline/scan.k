"""
scan: container vulnerability scanning as data, shared by every CI target of ci-pipeline.

A scanner is an image plus two POSIX shell snippets that run in it:

  report   scans one target and prints what it found. Findings never fail it.
  gate     scans one target and exits non-zero on a finding at or above `failOn`

Presets (`use:`):

  ods     Google On-Demand Scanning API. Paid per scan. Needs
          ondemandscanning.googleapis.com enabled in the project the build bills to, and
          roles/ondemandscanning.admin for the build identity. Reads the image from the build's
          Docker daemon. Findings stay in Artifact Analysis. `ODS_LOCATION` (us | europe | asia)
          is where the scan runs.
  trivy   Aqua Trivy. Free, OSS. Reads a `docker save` archive.
  grype   Anchore Grype. Free, OSS. Reads a `docker save` archive. Its image is
          distroless/busybox and runs as nonroot, so it never touches the Docker socket.
  snyk    Snyk Container. Paid. SNYK_TOKEN comes from the secret `snyk-token`. Reads an archive.

A custom scanner sets the same fields (`name`, `image`, `input`, `report`, `gate`, and
optionally `shell`, `unfixed`, `env`, `secrets`). A preset entry may override any of them, for
example a pinned image or env. Placeholders in snippets:

  {ref}            the image reference. It may hold shell variables ($IMAGE), so quote it: "{ref}"
  {archive}        path of the target's `docker save` archive (input: archive)
  {severities}     every severity at or above failOn, upper case, comma separated
  {severityRegex}  the same severities joined by |
  {threshold}      failOn, lower case
  {unfixed}        the scanner's `unfixed` flag when ignoreUnfixed is set, else empty

There is one step per scanner and target. Report steps (base images by default) come first
and are allowed to fail. Gate steps (the built image) come last and block the push.
"""
import regex


SEVERITIES = ["LOW", "MEDIUM", "HIGH", "CRITICAL"]

_SC_ODS_SCAN = """scan=$(gcloud artifacts docker images scan "{ref}" --location="$ODS_LOCATION" --format='value(response.scan)' --quiet)
gcloud artifacts docker images list-vulnerabilities "$scan" --format='table(vulnerability.effectiveSeverity,noteName.basename(),vulnerability.packageIssue[0].affectedPackage,vulnerability.packageIssue[0].affectedVersion.fullName,vulnerability.packageIssue[0].fixedVersion.fullName)'
"""

# The severities go through a file, not a pipe: in a pipe, sh reports grep's status, and a
# failed listing would read as "no findings".
_SC_ODS_GATE = """gcloud artifacts docker images list-vulnerabilities "$scan"{unfixed} --format='value(vulnerability.effectiveSeverity)' > /tmp/ods-severities
n=$(grep -Ecx '{severityRegex}' /tmp/ods-severities || true)
echo "{ref}: $n finding(s) at {threshold} or above"
[ "$n" -eq 0 ]
"""

PRESETS = {
    ods = {
        image = "gcr.io/google.com/cloudsdktool/cloud-sdk:594.0.0"
        input = "daemon"
        env = {ODS_LOCATION = "europe"}
        report = _SC_ODS_SCAN
        gate = _SC_ODS_SCAN + _SC_ODS_GATE
        unfixed = " --filter=vulnerability.fixAvailable=true"
    }
    trivy = {
        image = "docker.io/aquasec/trivy:0.76.2"
        input = "archive"
        report = "trivy image --input \"{archive}\" --scanners vuln --no-progress\n"
        gate = "trivy image --input \"{archive}\" --scanners vuln --no-progress --exit-code 1 --severity {severities}{unfixed}\n"
        unfixed = " --ignore-unfixed"
    }
    grype = {
        image = "docker.io/anchore/grype:v0.122.1-debug"
        shell = "/busybox/sh"
        input = "archive"
        # Cloud Build sets HOME=/builder/home, which nonroot cannot write.
        env = {GRYPE_DB_CACHE_DIR = "/tmp/grype-db", GRYPE_CHECK_FOR_APP_UPDATE = "false"}
        report = "/grype \"docker-archive:{archive}\"\n"
        gate = "/grype \"docker-archive:{archive}\" --fail-on {threshold}{unfixed}\n"
        unfixed = " --only-fixed"
    }
    snyk = {
        image = "docker.io/snyk/snyk:docker"
        input = "archive"
        secrets = {SNYK_TOKEN = "snyk-token"}
        # Exit 1 means "vulnerabilities found"; 2 and 3 are errors.
        report = "snyk container test \"docker-archive:{archive}\" || [ $? -eq 1 ]\n"
        gate = "snyk container test \"docker-archive:{archive}\" --severity-threshold={threshold}\n"
    }
}

schema Scanner:
    use?: "ods" | "trivy" | "grype" | "snyk"
    name?: str
    image?: str
    shell?: str
    input?: "daemon" | "archive"
    report?: str
    gate?: str
    unfixed?: str
    env?: {str:str}
    secrets?: {str:str}

    check:
        use or (name and image and input and report and gate), "a scanner is a preset (`use`) or a custom one with name, image, input, report and gate"
        not name or regex.match(name, r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"), "scanner name is lower-case [a-z0-9-]: ${name}"

schema Scan:
    """
    failOn         lowest severity that fails a gate
    ignoreUnfixed  gate only on findings that have a fix (needs every scanner's `unfixed`)
    baseImages     report (default): scanned, never blocking; gate: blocking; skip
    scanners       at least one
    """
    failOn: "LOW" | "MEDIUM" | "HIGH" | "CRITICAL" = "CRITICAL"
    ignoreUnfixed: bool = False
    baseImages: "report" | "gate" | "skip" = "report"
    scanners: [Scanner]

    check:
        scanners, "scan.scanners needs at least one scanner"


# A scanner entry with its preset filled in.
resolveScanner = lambda s: Scanner -> {str:} {
    _p = PRESETS[s.use] if s.use else {}
    {
        name = s.name or s.use
        image = s.image or _p.image
        shell = s.shell or _p.shell or "sh"
        input = s.input or _p.input
        report = s.report or _p.report
        gate = s.gate or _p.gate
        unfixed = s.unfixed or _p.unfixed
        env = (_p.env or {}) | (s.env or {})
        secrets = (_p.secrets or {}) | (s.secrets or {})
    }
}

_scFill = lambda tpl: str, cfg: Scan, s: {str:}, t: {str:} -> str {
    _i = [_j for _j, _v in SEVERITIES if _v == cfg.failOn][0]
    _sev = SEVERITIES[_i:]
    tpl.replace("{ref}", t.ref).replace("{archive}", t.archive or "").replace("{severities}", ",".join(_sev)).replace("{severityRegex}", "|".join(_sev)).replace("{threshold}", cfg.failOn.lower()).replace("{unfixed}", (s.unfixed or "") if cfg.ignoreUnfixed else "")
}

# Scan steps for `targets`, each {name, ref, archive, mode: gate | report | skip}. Steps carry
# `input`, so the caller knows whether to export archives first.
scanSteps = lambda cfg: Scan, targets: [{str:}] -> [{str:}] {
    _ss = [resolveScanner(_s) for _s in cfg.scanners]
    _names = [_s.name for _s in _ss]
    _dup = [_n for _i, _n in _names if _n in _names[:_i]]
    assert not _dup, "scanner names ${_dup} repeat; set `name` on one of them"
    _noFlag = [_s.name for _s in _ss if cfg.ignoreUnfixed and not _s.unfixed]
    assert not _noFlag, "ignoreUnfixed: scanner(s) ${_noFlag} have no flag for it (`unfixed`)"
    _ts = [_t for _t in targets if _t.mode == "report"] + [_t for _t in targets if _t.mode == "gate"]
    [{
        id = "scan-${_s.name}-${_t.name}"
        image = _s.image
        shell = _s.shell
        input = _s.input
        env = _s.env
        secrets = _s.secrets
        allowFailure = _t.mode == "report"
        script = "echo \"${_s.name}: ${_t.name}, " + ("gate: ${cfg.failOn} and above" if _t.mode == "gate" else "report only") + "\"\n" + _scFill(_s.gate if _t.mode == "gate" else _s.report, cfg, _s, _t)
    } for _t in _ts for _s in _ss]
}
