"""
Entry point for `bucket-import` — Terraform or Pulumi state in, `Bucket` XRs out.

  just bucket-import terraform terraform.tfstate          # or `terraform show -json > state.json`
  just bucket-import pulumi    <(pulumi stack export)
  kcl run packages/cloud/bucket/import -D state=state.json -D namespace=prod -D mode=observe -q

Every bucket the state knows becomes one XR that ADOPTS it: spec.import pins
the real cloud name, mode=observe (the default) keeps Crossplane read-only,
deletionPolicy=Orphan (the default) means deleting the XR can never delete
the bucket. The portable fields — versioning, public access, encryption,
retention, lifecycle, cors, logging, website, tags — are read off the state
so that `kubectl get bucket -o yaml` and the old tool agree from day one.
What could not be carried over is named in an import-notes annotation.

Options (-D):
  state=<path>          required; `terraform.tfstate`, `terraform show -json`
                        or `pulumi stack export` output — detected by shape
  source=terraform|pulumi   override the detection (recorded on the XR)
  namespace=default     where the XRs go
  mode=observe|manage   spec.import.mode for every XR
  deletionPolicy=Orphan|Delete
  report=true           print a BucketImportReport instead of the XRs: every
                        bucket with the addresses to remove from the old state
                        (its own and its companions'), what was dropped, and
                        the bucket-family resources that were skipped. A
                        report, not a manifest

`nx build bucket-import` runs this with no state at all: it maps the tiny
demo state below, so the readers and the mapper are exercised on every build.
"""

import file
import json
import manifests
import bucket_xrd.models.v1alpha1.cloud_example_org_v1alpha1_bucket as xrd
import .lib

_path = option("state", default="")
assert (not _path) or file.exists(_path), "state file not found: '${_path}' (relative to ${file.workdir()}). Pass an absolute path, or run from the directory that contains it."

# Two buckets Terraform made, enough to touch every reader path.
_demo = {
    version = 4
    resources = [
        {mode = "managed", type = "aws_s3_bucket", name = "demo", instances = [{
            attributes = {bucket = "demo-a1b2c3", region = "us-east-1", tags = {team = "platform"}, versioning = [{enabled = True}]}
        }]}
        {mode = "managed", type = "aws_s3_bucket_versioning", name = "demo", instances = [{
            attributes = {bucket = "demo-a1b2c3", versioning_configuration = [{status = "Enabled"}]}
        }]}
        {mode = "managed", type = "google_storage_bucket", name = "media", instances = [{
            attributes = {name = "media-demo-9z", location = "US", storage_class = "NEARLINE", versioning = [{enabled = False}], uniform_bucket_level_access = True, public_access_prevention = "enforced"}
        }]}
    ]
}
_doc = json.decode(file.read(_path)) if _path else _demo

_source = option("source", default="") or lib.detect(_doc)
assert _source in ["terraform", "pulumi"], "source must be terraform or pulumi, got '${_source}'"

_opts = lib.Options {
    namespace = option("namespace", default="default")
    mode = option("mode", default="observe")
    deletionPolicy = option("deletionPolicy", default="Orphan")
    source = _source
}

_records = lib.records(_doc, _source)
_found = lib.buckets(_records)
_skipped = lib.skipped(_records)

# Typed against the generated XRD schema: a tier the enum does not know, or a
# rule without an id, fails here rather than at the API server.
_xrs = [xrd.Bucket {**lib.xr(_f, _opts)} for _f in _found]

_report = option("report", default="")
_out = [{
    kind = "BucketImportReport"
    source = _source
    state = _path or "(demo)"
    buckets = [{name = _f.name, provider = _f.provider, address = _f.address, companions = _f.companions, xr = lib.k8s_name(_f.name), notes = _f.notes} for _f in _found]
    skipped = _skipped
}] if _report else _xrs

manifests.yaml_stream(_out)
