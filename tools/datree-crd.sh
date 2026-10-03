#!/usr/bin/env bash
# datree-crd.sh — rebuild CRD YAMLs from the schemas in datreeio/CRDs-catalog.
#
# Why this exists: KubeVirt and CDI generate their CustomResourceDefinitions in
# Go, inside virt-operator / cdi-operator, at install time. No CRD YAML for
# VirtualMachine or DataVolume exists in any upstream repo or release asset —
# kubevirt/kubevirt ships only manifests/generated/kv-resource.yaml, the CRD of
# the operator's OWN KubeVirt resource. So `just provider-repo` has nothing to
# fetch, and the schemas have to come from somewhere that extracted them from a
# live cluster. datreeio/CRDs-catalog does exactly that and publishes the
# `openAPIV3Schema` verbatim as JSON.
#
# This wraps those schemas back into the CRD envelope `kcl import -m crd`
# expects, so the generated KCL is still typed against the real API. The
# catalog ref is pinned by the caller (a commit SHA in the registry row), which
# is what keeps generation reproducible.
#
#   tools/datree-crd.sh <catalog-ref> <outdir> <group>/<file>.json:<Kind> ...
#
# e.g. tools/datree-crd.sh ad3b08c5 /tmp/crds \
#        kubevirt.io/virtualmachine_v1.json:VirtualMachine \
#        cdi.kubevirt.io/datavolume_v1beta1.json:DataVolume
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <catalog-ref> <outdir> <group>/<file>.json:<Kind> ..." >&2
    exit 2
fi

ref="$1"
outdir="$2"
shift 2
mkdir -p "$outdir"

for spec in "$@"; do
    path="${spec%%:*}"
    kind="${spec##*:}"
    group="${path%%/*}"
    file="${path##*/}"
    case "$spec" in
        */*.json:*) ;;
        *) echo "bad spec '$spec': want <group>/<file>.json:<Kind>" >&2; exit 2 ;;
    esac

    # datree names every file <kind>_<version>.json, which is where the served
    # version comes from — there is nothing else in the payload that carries it.
    version="${file##*_}"
    version="${version%.json}"
    plural="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')s"

    url="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${ref}/${path}"
    schema="$(curl -fsSL "$url")" || { echo "fetch failed: $url" >&2; exit 1; }

    # One served+storage version per CRD: the generator only ever reads the
    # storage version, and the catalog publishes one file per version anyway.
    printf '%s' "$schema" | SCHEMA_KIND="$kind" SCHEMA_GROUP="$group" \
        SCHEMA_PLURAL="$plural" SCHEMA_VERSION="$version" \
        yq -p=json -o=yaml '
          {
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": env(SCHEMA_PLURAL) + "." + env(SCHEMA_GROUP)},
            "spec": {
              "group": env(SCHEMA_GROUP),
              "scope": "Namespaced",
              "names": {
                "kind": env(SCHEMA_KIND),
                "plural": env(SCHEMA_PLURAL),
                "singular": (env(SCHEMA_KIND) | downcase),
                "listKind": env(SCHEMA_KIND) + "List"
              },
              "versions": [{
                "name": env(SCHEMA_VERSION),
                "served": true,
                "storage": true,
                "subresources": {"status": {}},
                "schema": {"openAPIV3Schema": .}
              }]
            }
          }
        ' > "${outdir}/${group}_${plural}.yaml"
    echo "wrote ${outdir}/${group}_${plural}.yaml (${kind} ${version})"
done
