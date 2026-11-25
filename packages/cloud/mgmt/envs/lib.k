"""
mgmt-envs — a factory of mgmt-like control planes, one `Mgmt` XR per env.

  defaults.yaml ─┐
                 ├──► Env ──► render ──► Namespace cp-<env> + Mgmt mgmt-<env>   (mgmt-gcp composes it)
  envs/<env>.yaml┘                └────► prerequisites: what tier 0 must provide first

The XR is built against `mgmt-xrd` (the schemas `just xrd-schema mgmt` derives
from ../xrd/xrd.yaml), so an env file that the cluster's XRD would reject
fails the render instead.

Per env, unless its file says otherwise:

  project        <prefix>-mgmt-<env>, in the env's folder: \${<ENV>_FOLDER_ID},
                 substituted by Flux from cluster-identity
  cluster        mgmt-<env>
  network        nonprod: host <prefix>-net-dev, VPC dev; prod: <prefix>-net-prod,
                 VPC prod; subnet mgmt-<env> with ranges mgmt-<env>-pods and
                 mgmt-<env>-services
  identity       nonprod: the provider default (crossplane@); prod: the
                 namespaced ProviderConfig `prod` (crossplane-prod@)
  folder grants  none: only folders.platform is set, so the env's crossplane@
                 gets no roles outside its own project

What the env file sets under `spec` is deep-merged over all of that (maps
merge, lists and scalars replace).
"""

import regex
import mgmt_xrd.models.unknown as xr

schema Env:
  """One env file (`envs/<name>.yaml`); `name` is the file stem."""
  name: str
  tier: "nonprod" | "prod" = "prod" if name == "prod" else "nonprod"
  folder?: str
  providerConfig?: str
  spec: {str:} = {}

  check:
    regex.match(name, r"^[a-z][a-z0-9-]{1,11}$"), "env name '${name}' needs 2-12 characters: lowercase letters, digits, hyphens"

schema Defaults:
  """defaults.yaml: the Mgmt spec every env starts from."""
  spec: {str:}

  check:
    "prefix" in spec and "region" in spec, "defaults.yaml spec needs prefix and region"

# Deep, right-wins merge (maps merge, lists and scalars replace), as fleet's main.k.
merge = lambda base: {str:}, overlay: {str:} -> {str:} {
  {k: (merge(base[k], overlay[k]) if (k in base and k in overlay and typeof(base[k]) == "dict" and typeof(overlay[k]) == "dict") else (overlay[k] if k in overlay else base[k])) for k in ([_kb for _kb in base] + [_ko for _ko in overlay if _ko not in base])}
}

# The env's Mgmt spec: defaults, then the per-env conventions, then the env file.
envSpec = lambda d: Defaults, e: Env -> {str:} {
  # The env file may override prefix and region; the names derive from its values.
  _base = merge(d.spec, e.spec)
  _prefix = _base.prefix
  _region = _base.region
  _host = "${_prefix}-net-dev" if e.tier == "nonprod" else "${_prefix}-net-prod"
  _vpc = "dev" if e.tier == "nonprod" else "prod"
  _subnet = "mgmt-${e.name}"
  _conventions = {
    projectId = "${_prefix}-mgmt-${e.name}"
    folders.platform = e.folder or "$" + "{" + e.name.upper().replace("-", "_") + "_FOLDER_ID}"
    cluster.name = "mgmt-${e.name}"
    network = {
      hostProject = _host
      network = "https://www.googleapis.com/compute/v1/projects/${_host}/global/networks/${_vpc}"
      subnetwork = "https://www.googleapis.com/compute/v1/projects/${_host}/regions/${_region}/subnetworks/${_subnet}"
      podsRange = "${_subnet}-pods"
      servicesRange = "${_subnet}-services"
    }
    crossplane.compositionSelector.matchLabels.provider = "gcp"
  }
  _pc = e.providerConfig or ("prod" if e.tier == "prod" else "")
  merge(merge(d.spec, _conventions), e.spec) | ({providerConfigName = _pc} if _pc else {})
}

render = lambda d: Defaults, e: Env -> [any] {
  _namespace = "cp-${e.name}"
  [
    {
      apiVersion = "v1"
      kind = "Namespace"
      metadata.name = _namespace
      metadata.labels = {"platform.shluviza.com/control-plane" = e.name, "platform.shluviza.com/tier" = e.tier}
    }
    xr.Mgmt {
      metadata = {
        name = "mgmt-${e.name}"
        namespace = _namespace
        labels = {"platform.shluviza.com/control-plane" = e.name, "platform.shluviza.com/tier" = e.tier}
      }
      spec = xr.MgmtSpec {**envSpec(d, e)}
    }
  ]
}

# What has to exist before the env's XR can become Ready. None of it is in
# this repo's reach: the identity a Composition runs as has no rights on the
# hosts, the security keys or other folders (infra apps/mgmt, "Crossplane is
# the tier-1 IaC tool").
prerequisites = lambda d: Defaults, e: Env -> {str:} {
  _s = envSpec(d, e)
  _identity = "crossplane-prod@" if e.tier == "prod" else "crossplane@"
  _projectId = _s.projectId
  _folder = _s.folders.platform
  _placeholder = regex.match(_folder, r"^\$\{[A-Z0-9_]+\}$")
  _keys = _s.keys
  _foreignKeys = [k for _, k in _keys if not k.startswith("projects/${_projectId}/")]
  _postgres = (_s?.postgres?.enabled or False)
  _dns = (_s?.dns?.enabled if _s?.dns?.enabled != None else True)
  {
    env = e.name
    tier = e.tier
    project = _projectId
    identity = _identity
    gitops = [
      "Mgmt XRD and the mgmt-gcp Composition installed (vendor/kcl-packages/packages/cloud/mgmt/xrd/xrd.yaml, gcp/composition.yaml)"
      "the provider families of packages/cloud/mgmt/xrd/providers.yaml installed; platform/crossplane/providers has only cloudplatform and storage"
    ] + (["namespaced ProviderConfig `${_s.providerConfigName}` in cp-${e.name}, impersonating ${_identity} of the mgmt project"] if _s?.providerConfigName else []) + ([
      "${_folder[2:len(_folder) - 1]} in cluster-identity (infra apps/mgmt clusterIdentity): the numeric id of the folder the project goes in"
    ] if _placeholder else [])
    network = [
      "subnet ${_s.network.subnetwork.split('/')[-1]} with secondary ranges ${_s.network.podsRange} and ${_s.network.servicesRange} in ${_s.network.hostProject} (infra apps/network)"
      "${_identity} may set IAM on that subnet and on project ${_s.network.hostProject} (the composition grants the GKE agent networkUser, hostServiceAgentUser, securityAdmin there)"
      "${_identity} is Shared VPC Admin on the host's folder and on ${_folder}" + (": crossplane-prod@ has no xpnAdmin on network/ by design (prod attachments stay in apps/network)" if e.tier == "prod" else "")
    ]
    keys = ["${_identity} may set IAM on ${k} (CryptoKeyIAMMember for the env's service agents)" for k in _foreignKeys]
    other = (["Cloud SQL service agent: gcloud beta services identity create --service=sqladmin.googleapis.com --project=${_projectId}", "Kubernetes Secrets in cp-${e.name} for every postgres.databases[].passwordSecretRef"] if _postgres else []) + (["dns.enabled: the env gets its own public zone for ${_s.domain}, a duplicate of the org's; leave it off until the XRD takes a zone domain apart from the group domain"] if _dns else [])
  }
}
