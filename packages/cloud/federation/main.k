"""
Entry point for the `federation` library: what one list of access entries
becomes on each cloud. Library use: `import federation.lib as fed`.

  kcl run packages/cloud/federation/main.k
  kcl run packages/cloud/federation/main.k -D access='[{"client": "gitlab", "owner": "acme", "audiences": ["sts.amazonaws.com"]}]'
"""

import .lib

_demo = [
  {client = "github", owner = "acme", role = "write"}
  {client = "github", ticket = "jira", workflows = ["acme/ops/.github/workflows/jira.yml"], subjects = ["repo:acme/ops:job_workflow_ref:acme/ops/.github/workflows/jira.yml@refs/heads/main"]}
]
_access = lib.access_list(option("access") or _demo)

gcp = {lib.access_name(_a): lib.gcp_members(_a, "123456789012") for _a in _access}
gcpPools = lib.expand([{_k: _v for _k, _v in _e if _k != "role"} for _e in option("access") or _demo])
aws = {lib.access_name(_a): lib.aws_trust(_a, "111122223333") for _a in _access}
azure = {lib.access_name(_a): {issuer = lib.issuer_uri(_a), subjects = lib.azure_subjects(_a), audiences = lib.audiences_for(_a, "azure")} for _a in _access if _a.subjects}
