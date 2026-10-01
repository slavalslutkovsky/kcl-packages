# xup

A pythonic, multi-cloud CLI for Crossplane package management — inspired by
[Upbound's `up` CLI](https://docs.upbound.io/cli/), scoped to AWS, GCP and
Azure.

`xup` scaffolds and validates Crossplane package *source* (XRDs,
Compositions, examples) with one command per cloud instead of one file per
cloud written by hand. It does not reimplement OCI packaging: `xup build` /
`xup push` delegate to `crossplane` or `up`, whichever is on `PATH`, since
that's a solved problem in Go and re-solving it in Python would just be a
worse copy.

See [`docs/xup-vs-kcl-packages.md`](../../docs/xup-vs-kcl-packages.md) in the
repo root for how this compares to this repo's own KCL-based approach.

## Install

```bash
cd python/xup-cli
pip install -e .
```

## Usage

```bash
# Scaffold one XRD + one Composition per cloud for a "Bucket" claim.
xup init bucket-demo --kind Bucket --group storage.example.org --clouds aws,gcp,azure

# Structural validation: crossplane.yaml, XRD shape, Composition -> XRD refs.
xup validate bucket-demo

# List providers — xup's built-in catalog, or this repo's own registry.
xup providers --cloud aws
xup providers --registry ../../packages/providers/registry.yaml --cloud gcp

# Build/push delegate to `crossplane` or `up`, whichever is installed.
xup build bucket-demo -o bucket-demo.xpkg
xup push bucket-demo.xpkg xpkg.upbound.io/my-org/bucket-demo:v0.1.0
```

## Commands

| Command             | What it does                                                          |
|---------------------|------------------------------------------------------------------------|
| `xup init`           | Scaffold a package: `crossplane.yaml`, one XRD, one Composition + example per cloud |
| `xup validate`       | Structural checks: parseable meta file, XRD required fields, Composition→XRD refs |
| `xup providers`      | List known provider packages, from xup's catalog or a `registry.yaml` |
| `xup build`          | Build a `.xpkg` (delegates to `crossplane`/`up`)                      |
| `xup push`           | Push a `.xpkg` to an OCI registry (delegates to `crossplane`/`up`)     |

## Development

```bash
pip install -e . pytest
pytest tests/
```
