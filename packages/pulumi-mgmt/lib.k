"""
pulumi-mgmt: the mgmt Pulumi stack (shluviza/infra `apps/mgmt`) as data.

  Pulumi.<stack>.yaml ──► StackConfig ──► render ──► stack spec (YAML or JSON)

`render` derives every resource `apps/mgmt/index.ts` and `src/flux.ts` declare
from the same stack config, with the same logical names, so a program that
instantiates the spec produces the same URNs as the TypeScript program and
adopts its state without replacements. The spec follows Pulumi YAML's
conventions (it is not a runnable Pulumi YAML program, see `Spec`):

  resources   map key → {type, name, properties, options}
                type        the canonical Pulumi type token, as in the URN:
                            `gcp:organizations/project:Project`, and for the
                            infra repo's components the token they register:
                            `org:gcp-gke:GkeCluster`, `app:db:PostgresInstance`
                name        the logical name the TypeScript program passes
                properties  that type's Args (`gcp.organizations.ProjectArgs`,
                            `GkeClusterArgs`, ...), typed by the schemas below:
                            a field the Args type lacks fails the render
                options     `dependsOn`, as references to other keys
  variables   values computed from other resources' outputs (fn::split, ...)
  fluxBootstrap
              the `bootstrapFlux(args, opts)` call of src/flux.ts, present
              only with mgmt:fluxBootstrap true. A function, not a component:
              its resources are top-level, and it parses the GitHub App JSON
              out of Secret Manager, which no Pulumi YAML builtin can
  outputs     the stack exports

References are Pulumi YAML interpolations of map keys: `\${project.projectId}`,
`\${network.outputs["networkHosts"]["mgmt"]["subnet"]}`.
"""

import regex

# ── Spec envelope ────────────────────────────────────────────────────────────
_TOKEN = r"^[A-Za-z0-9-]+:[A-Za-z0-9/._-]*:[A-Za-z0-9]+$"

schema ResourceOptions:
  """The resource options index.ts sets. `dependsOn` entries are references (`\${apis}`)."""
  dependsOn?: [str]

schema Resource:
  """One `new <Type>(name, properties, options)`."""
  $type: str
  name: str
  properties: any
  options?: ResourceOptions

  check:
    regex.match($type, _TOKEN), "'{}' is not a Pulumi type token (<package>:<module>:<Type>)".format($type)
    name, "resource of type {} needs a logical name".format($type)

schema FunctionCall:
  """A call of an exported TypeScript function that creates resources, e.g. `bootstrapFlux`."""
  module: str
  function: str
  args: any
  options?: ResourceOptions

schema Spec:
  """The rendered stack. Top-level keys of the output."""
  project: str
  stack: str
  description?: str
  config: StackConfig
  variables: {str:any}
  resources: {str:Resource}
  fluxBootstrap?: FunctionCall
  outputs: {str:any}

  check:
    len({"{}::{}".format(r.$type, r.name): 0 for _, r in resources}) == len(resources), "two resources share a type and logical name: their URNs would collide"

# ── Stack config (Pulumi.<stack>.yaml `config:`) ─────────────────────────────
schema OrgConfig:
  """
    `org:*` — the same keys and shape checks as infra `packages/org-config`.
    A missing or misshapen value fails the render, as it fails the preview.
    """
  orgId: str
  customerId: str
  billingAccount: str
  orgDomain: str
  bootstrapUser: str
  prefix: str = "shl"
  githubOrg: str
  backupRegion: str = "europe-west4"
  stateBucket?: str

  check:
    regex.match(orgId, r"^\d{10,14}$"), "org:orgId is '${orgId}', which is not a numeric organization id"
    regex.match(customerId, r"^C[0-9a-z]{6,10}$"), "org:customerId is '${customerId}', which is not a Cloud Identity customer id"
    regex.match(billingAccount, r"^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$"), "org:billingAccount is '${billingAccount}', which is not a billing account id"
    regex.match(orgDomain, r"^[a-z0-9.-]+\.[a-z]{2,}$"), "org:orgDomain is '${orgDomain}', which is not a domain name"
    regex.match(bootstrapUser, r"^[^@\s]+@[a-z0-9.-]+\.[a-z]{2,}$"), "org:bootstrapUser is '${bootstrapUser}', which is not an email address"

schema MgmtConfig:
  """`mgmt:*` — every key index.ts reads, with its defaults. An unknown key fails the render."""
  fluxBootstrap: bool = False
  postgres: bool = False
  adminGroup: str = "gcp-organization-admins"
  developerGroup: str = "gcp-devops"
  crossplaneKsa: str = "crossplane-gcp"
  esoKsa: str = "external-secrets"
  zone?: str
  postgresTier: str = "db-custom-1-3840"
  nodeMachineType: str = "e2-standard-4"
  minNodesPerZone: int = 3
  maxNodesPerZone: int = 5
  ciMachineType: str = "e2-standard-4"
  ciMaxNodesPerZone: int = 4
  fluxOperatorVersion?: str
  fluxVersion: str = "2.x"
  gitopsRepoUrl: str = "https://github.com/shluviza/gitops.git"
  gitopsBranch: str = "main"
  gitopsPath: str = "clusters/mgmt/gke"
  fluxHostname?: str

  check:
    (not fluxBootstrap) or fluxOperatorVersion, "mgmt:fluxBootstrap needs mgmt:fluxOperatorVersion (config.require in index.ts)"

schema StackConfig:
  region: str
  org: OrgConfig
  mgmt: MgmtConfig

_BOOL_KEYS = ["fluxBootstrap", "postgres"]
_INT_KEYS = ["minNodesPerZone", "maxNodesPerZone", "ciMaxNodesPerZone"]

_toBool = lambda key: str, v: any -> bool {
  # pulumi.Config.getBoolean: exactly "true" or "false".
  assert typeof(v) == "bool" or v in ["true", "false"], "${key} is '${v}', which is not a boolean"
  v if typeof(v) == "bool" else v == "true"
}

_toInt = lambda key: str, v: any -> int {
  assert typeof(v) == "int" or (typeof(v) == "str" and regex.match(v, r"^-?\d+$")), "${key} is '${v}', which is not an integer"
  int(v)
}

fromStack = lambda stack: {str:}, project: str -> StackConfig {
  """Typed config from a Pulumi stack file: `config` keys are `<namespace>:<key>`, values strings."""
  _cfg = stack.config or {}
  _ns = lambda ns: str -> {str:} {
    {k[len(ns) + 1::]: _cfg[k] for k in _cfg if k.startswith(ns + ":")}
  }
  _mgmt = _ns(project)
  assert "gcp:region" in _cfg, "gcp:region is required (packages/org-config)"
  StackConfig {
    region = _cfg["gcp:region"]
    org = OrgConfig {**_ns("org")}
    mgmt = MgmtConfig {**{k: (_toBool("${project}:${k}", v) if k in _BOOL_KEYS else (_toInt("${project}:${k}", v) if k in _INT_KEYS else v)) for k, v in _mgmt}}
  }
}

# ── Resource Args (the fields index.ts sets, Pulumi's names and types) ───────
schema StackReferenceArgs:
  name: str

schema ProjectArgs:
  projectId: str
  name: str
  folderId: str
  billingAccount: str
  autoCreateNetwork: bool
  deletionPolicy: "PREVENT" | "ABANDON" | "DELETE"
  labels: {str:str}

schema EnableApisArgs:
  """infra packages/gcp-apis `EnableApisArgs`: ServiceArgs without `service`, plus `apis`."""
  project: str
  apis: [str]
  disableOnDestroy?: bool
  disableDependentServices?: bool

  check:
    len({a: 0 for a in apis}) == len(apis), "EnableApis lists an API twice"

schema SharedVPCServiceProjectArgs:
  hostProject: str
  serviceProject: str

schema ServiceIdentityArgs:
  project: str
  service: str

schema IamMemberArgs:
  """role + member, common to every *IAMMember / *IamMember Args."""
  role: str
  member: str

  check:
    role.startswith("roles/"), "role '${role}' is not a predefined role"

schema ProjectIAMMemberArgs(IamMemberArgs):
  project: str

schema FolderIAMMemberArgs(IamMemberArgs):
  folder: str

schema SubnetworkIAMMemberArgs(IamMemberArgs):
  project: str
  region: str
  subnetwork: str

schema CryptoKeyIAMMemberArgs(IamMemberArgs):
  cryptoKeyId: str

schema ServiceAccountIAMMemberArgs(IamMemberArgs):
  serviceAccountId: str

schema BillingAccountIamMemberArgs(IamMemberArgs):
  billingAccountId: str

schema RepositoryIamMemberArgs(IamMemberArgs):
  project: str
  location: str
  repository: str

schema BucketIAMMemberArgs(IamMemberArgs):
  bucket: str

schema DnsManagedZoneIamMemberArgs(IamMemberArgs):
  project: str
  managedZone: str

schema SecretIamMemberArgs(IamMemberArgs):
  project: str
  secretId: str

schema AccountArgs:
  project: str
  accountId: str
  displayName: str

  check:
    regex.match(accountId, r"^[a-z][-a-z0-9]{4,28}[a-z0-9]$"), "service account id '${accountId}' needs 6-30 characters: lowercase letters, digits, hyphens"

schema PostgresInstanceArgs:
  """infra packages/gcp-postgres `PostgresInstanceArgs`."""
  project: str
  tier: str
  edition?: "ENTERPRISE" | "ENTERPRISE_PLUS"
  databaseVersion?: str
  isProd: bool
  availabilityType?: "ZONAL" | "REGIONAL"
  diskSizeGb?: int
  region: str
  databaseName?: str
  dbUser?: str
  accessors?: [str]
  privateNetwork?: str
  encryptionKeyName?: str

schema PostgresDatabaseArgs:
  """infra packages/gcp-postgres `PostgresDatabaseArgs`."""
  project: str
  region: str
  isProd: bool
  instance: str
  databaseName: str
  dbUser: str
  accessors?: [str]

schema AdmissionWhitelistPattern:
  namePattern: str

schema AdmissionRule:
  evaluationMode: "ALWAYS_ALLOW" | "REQUIRE_ATTESTATION" | "ALWAYS_DENY"
  enforcementMode: "ENFORCED_BLOCK_AND_AUDIT_LOG" | "DRYRUN_AUDIT_LOG_ONLY"

schema BinaryAuthorizationPolicyArgs:
  project: str
  globalPolicyEvaluationMode: "ENABLE" | "DISABLE"
  admissionWhitelistPatterns: [AdmissionWhitelistPattern]
  defaultAdmissionRule: AdmissionRule

schema NodeTaint:
  """infra packages/gcp-gke `NodeTaint`."""
  key: str
  value: str
  effect: "NO_SCHEDULE" | "PREFER_NO_SCHEDULE" | "NO_EXECUTE"

schema NodePoolSpec:
  """infra packages/gcp-gke `NodePoolSpec`."""
  machineType: str
  minNodesPerZone: int
  maxNodesPerZone: int
  diskType?: "pd-standard" | "pd-balanced" | "pd-ssd"
  diskSizeGb?: int
  labels?: {str:str}
  taints?: [NodeTaint]
  spot?: bool

  check:
    minNodesPerZone >= 0 and maxNodesPerZone >= max(1, minNodesPerZone), "node pool needs 0 <= min <= max and max >= 1 per zone"

type LoggingComponent = "SYSTEM_COMPONENTS" | "WORKLOADS" | "APISERVER" | "CONTROLLER_MANAGER" | "SCHEDULER" | "KCP_VPA"
type MonitoringPackage = "POD" | "DEPLOYMENT" | "STATEFULSET" | "DAEMONSET" | "HPA" | "STORAGE" | "JOBSET" | "CADVISOR" | "KUBELET" | "APISERVER" | "SCHEDULER" | "CONTROLLER_MANAGER"

schema GkeClusterArgs:
  """infra packages/gcp-gke `GkeClusterArgs`, with the constructor's checks."""
  project: str
  name: str
  location: str
  network: str
  subnetwork: str
  podsRange: str
  servicesRange: str
  nodeServiceAccount: str
  databaseEncryptionKey: str
  securityGroup: str
  nodePools: {str:NodePoolSpec}
  binaryAuthorization?: bool
  loggingComponents?: [LoggingComponent]
  monitoringPackages?: [MonitoringPackage]
  deletionProtection?: bool

  check:
    any_true([not p.taints for _, p in nodePools]), "${name}: every node pool is tainted; system pods need an untainted one"

schema DockerConfig:
  immutableTags: bool

schema RepositoryArgs:
  project: str
  location: str
  repositoryId: str
  description: str
  format: "DOCKER"
  dockerConfig: DockerConfig
  labels: {str:str}

schema LifecycleRuleAction:
  $type: "Delete" | "SetStorageClass" | "AbortIncompleteMultipartUpload"

schema LifecycleRuleCondition:
  age: int

schema LifecycleRule:
  action: LifecycleRuleAction
  condition: LifecycleRuleCondition

schema BucketArgs:
  project: str
  name: str
  location: str
  uniformBucketLevelAccess: bool
  publicAccessPrevention: "enforced" | "inherited"
  lifecycleRules: [LifecycleRule]
  forceDestroy: bool
  labels: {str:str}

schema DnssecConfig:
  state: "on" | "off" | "transfer"

schema ManagedZoneArgs:
  project: str
  name: str
  dnsName: str
  description: str
  visibility: "public" | "private"
  dnssecConfig: DnssecConfig
  labels: {str:str}

  check:
    dnsName.endswith("."), "dnsName '${dnsName}' must be fully qualified (trailing dot)"

schema AddressArgs:
  project: str
  region: str
  name: str
  addressType: "EXTERNAL" | "INTERNAL"
  description: str
  labels: {str:str}

schema RecordSetArgs:
  project: str
  managedZone: str
  name: str
  $type: "A" | "AAAA" | "CNAME" | "MX" | "TXT" | "NS" | "SRV" | "CAA"
  ttl: int
  rrdatas: [str]

  check:
    name.endswith("."), "record name '${name}' must be fully qualified (trailing dot)"

schema SecretReplica:
  location: str

schema SecretUserManaged:
  replicas: [SecretReplica]

schema SecretReplication:
  userManaged: SecretUserManaged

schema SecretArgs:
  project: str
  secretId: str
  replication: SecretReplication
  labels: {str:str}

schema FluxBootstrapArgs:
  """infra apps/mgmt/src/flux.ts `FluxBootstrapArgs`."""
  project: str
  githubAppSecretId: str
  dnsEndpoint: str
  operatorVersion: str
  fluxVersion: str
  repoUrl: str
  branch: str
  path: str
  clusterIdentity: {str:str}
  webHostname: str

# ── Constants from index.ts ──────────────────────────────────────────────────
_APIS = [
  "container.googleapis.com"
  "compute.googleapis.com"
  "binaryauthorization.googleapis.com"
  "logging.googleapis.com"
  "monitoring.googleapis.com"
  "iam.googleapis.com"
  "iamcredentials.googleapis.com"
  "sts.googleapis.com"
  "secretmanager.googleapis.com"
  "cloudkms.googleapis.com"
  "artifactregistry.googleapis.com"
  "servicenetworking.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "serviceusage.googleapis.com"
  "cloudbilling.googleapis.com"
  "billingbudgets.googleapis.com"
  "storage.googleapis.com"
  "sqladmin.googleapis.com"
  "pubsub.googleapis.com"
  "dns.googleapis.com"
  "bigquery.googleapis.com"
  "run.googleapis.com"
  "redis.googleapis.com"
  "workflows.googleapis.com"
]

_PROJECT_LIFECYCLE_ROLES = [
  "roles/resourcemanager.projectCreator"
  "roles/billing.projectManager"
  "roles/serviceusage.serviceUsageAdmin"
  "roles/resourcemanager.projectIamAdmin"
  "roles/resourcemanager.tagUser"
]

_PLATFORM_ROLES = [
  "roles/container.admin"
  "roles/compute.networkAdmin"
  "roles/compute.securityAdmin"
  "roles/compute.instanceAdmin.v1"
  "roles/compute.loadBalancerAdmin"
  "roles/servicenetworking.networksAdmin"
  "roles/cloudsql.admin"
  "roles/redis.admin"
  "roles/run.admin"
  "roles/workflows.admin"
  "roles/storage.admin"
  "roles/pubsub.admin"
  "roles/bigquery.admin"
  "roles/artifactregistry.admin"
  "roles/secretmanager.admin"
  "roles/dns.admin"
  "roles/cloudkms.admin"
  "roles/iam.serviceAccountAdmin"
  "roles/iam.serviceAccountUser"
]

# Workspace mail and verification, copied from the registrar (index.ts, "DNS").
_DKIM = '"v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0/cxE2CqQNo1Z1Xcmm6d0cXOq3LvvnKbULPpVvvlxqSCLkOq6MjvWzpr1uHyOWBgi1l9lmHDj9Ae/YWmMWjcruUbJIxt7lQepuPWiZ62lvH++mHPN1zMykD3LyxdH0nnaEvxJGu0BV1a5qZ1wWrpUzUZ1GmTfWD3KKSdf7WE7LbfqHd/Mz4x+y4OA4QJrBKpkzk" ' + '"aZHLB/M+RnYPV4m2hFE5kt5ktdk0U+pMsw0O45jx2Q/bnLd7gam/Ti2fSh6glYW+9hSv3D8Soaj5bblX63f+uMHt9nXKSRESRlVBPXtc3rzjM5jjwTvwrO+R4sGn20gy23p7xI6A2D9bPGXVoawIDAQAB"'

# ── Helpers ──────────────────────────────────────────────────────────────────
# A Pulumi YAML interpolation: ref("project.projectId") is `${project.projectId}`.
ref = lambda expr: str -> str {
  "$" + "{" + expr + "}"
}

# `${<stack>.outputs["a"]["b"]}`: a StackReference output, by key path.
stackOutput = lambda stack: str, path: [str] -> str {
  ref(stack + ".outputs" + "".join(['["' + p + '"]' for p in path]))
}

# index.ts roleSlug: resource names derive from the role.
roleSlug = lambda role: str -> str {
  role.removeprefix("roles/").replace(".", "-")
}

# Parameters are `_`-prefixed: in a schema or config body, `member = member`
# resolves the right-hand side as the attribute being defined, not the parameter.
_entry = lambda _key: str, _token: str, _name: str, _props: any, _deps: [str] -> {str:} {
  {
    key = _key
    resource = Resource {
      $type = _token
      name = _name
      properties = _props
      options = ResourceOptions {dependsOn = _deps} if _deps else Undefined
    }
  }
}

# ── Render ───────────────────────────────────────────────────────────────────
render = lambda c: StackConfig, _projectName: str, _stackName: str -> Spec {
  _o = c.org
  _m = c.mgmt
  _region = c.region
  _prefix = _o.prefix
  _billing = _o.billingAccount
  _domain = _o.orgDomain
  _group = lambda role: str -> str {
    role + "@" + _domain
  }
  _labels = lambda _purpose: str -> {str:str} {
    {"managed-by" = "pulumi", tier = "0", org = _prefix, purpose = _purpose}
  }
  _projectId = ref("project.projectId")
  _adminGroup = _group(_m.adminGroup)
  _developerGroup = _group(_m.developerGroup)
  _zone = _m.zone or _region + "-a"
  _crossplaneKsa = {namespace = "crossplane-system", name = _m.crossplaneKsa}
  _esoKsa = {namespace = "external-secrets", name = _m.esoKsa}
  _afterApis = [ref("apis")]
  _host = lambda field: str -> str {
    stackOutput("network", ["networkHosts", "mgmt", field])
  }
  _devHost = lambda field: str -> str {
    stackOutput("network", ["networkHosts", "dev", field])
  }
  _folder = lambda output: str -> str {
    stackOutput("organization", [output])
  }
  _gkeAgentMember = ref("gkeAgent.member")
  _apisAgent = "serviceAccount:" + ref("project.number") + "@cloudservices.gserviceaccount.com"

  # Self link https://www.googleapis.com/compute/v1/projects/<p>/regions/<r>/subnetworks/<name>:
  # element 10 is the name, index.ts `selfLink.split('/').pop()`.
  _subnetName = lambda selfLink: str -> {str:} {
    {"fn::select" = [10, {"fn::split" = ["/", selfLink]}]}
  }
  _variables = {
    mgmtSubnetName = _subnetName(_host("subnet"))
    devSubnetName = _subnetName(_devHost("subnet"))
  }

  _projectRoles = lambda _id: str, _member: str, _roles: [str] -> [{str:}] {
    [_entry("${_id}-${roleSlug(r)}", "gcp:projects/iAMMember:IAMMember", "${_id}-${roleSlug(r)}", ProjectIAMMemberArgs {project = _projectId, role = r, member = _member}, []) for r in _roles]
  }
  _folderRoles = lambda _id: str, _folderId: str, _member: str, _roles: [str] -> [{str:}] {
    [_entry("${_id}-${roleSlug(r)}", "gcp:folder/iAMMember:IAMMember", "${_id}-${roleSlug(r)}", FolderIAMMemberArgs {folder = "folders/" + _folderId, role = r, member = _member}, []) for r in _roles]
  }
  _account = lambda _key: str, _id: str, _displayName: str -> {str:} {
    _entry(_key, "gcp:serviceaccount/account:Account", _id, AccountArgs {project = _projectId, accountId = _id, displayName = _displayName}, _afterApis)
  }
  _workloadIdentity = lambda id: str, account: str, ksa: {str:str} -> {str:} {
    _entry("${id}-workload-identity", "gcp:serviceaccount/iAMMember:IAMMember", "${id}-workload-identity", ServiceAccountIAMMemberArgs {
      serviceAccountId = ref(account + ".name")
      role = "roles/iam.workloadIdentityUser"
      member = "serviceAccount:" + ref("gke.workloadPool") + "[${ksa.namespace}/${ksa.name}]"
    }, [ref("gke")])
  }
  _ksaPrincipal = lambda ksa: {str:str} -> str {
    "principal://iam.googleapis.com/projects/" + ref("project.number") + "/locations/global/workloadIdentityPools/" + ref("gke.workloadPool") + "/subject/ns/${ksa.namespace}/sa/${ksa.name}"
  }

  # Stack references, project, APIs, Shared VPC attachment, host grants.
  _foundation = [_entry(s, "pulumi:pulumi:StackReference", s, StackReferenceArgs {name = "organization/${s}/prod"}, []) for s in ["organization", "network", "security"]] + [
    _entry("project", "gcp:organizations/project:Project", "mgmt", ProjectArgs {
      projectId = "${_prefix}-mgmt"
      name = "${_prefix}-mgmt"
      folderId = _folder("platformFolderId")
      billingAccount = _billing
      autoCreateNetwork = False
      deletionPolicy = "PREVENT"
      labels = _labels("mgmt")
    }, [])
    _entry("apis", "org:gcp-apis:EnableApis", "mgmt-apis", EnableApisArgs {project = _projectId, apis = _APIS}, [])
    _entry("attachment", "gcp:compute/sharedVPCServiceProject:SharedVPCServiceProject", "mgmt-on-net-mgmt", SharedVPCServiceProjectArgs {hostProject = _host("projectId"), serviceProject = _projectId}, _afterApis)
    _entry("gkeAgent", "gcp:projects/serviceIdentity:ServiceIdentity", "gke-agent", ServiceIdentityArgs {project = _projectId, service = "container.googleapis.com"}, _afterApis)
  ] + [_entry("subnet-network-user-${_sid}", "gcp:compute/subnetworkIAMMember:SubnetworkIAMMember", "subnet-network-user-${_sid}", SubnetworkIAMMemberArgs {
    project = _host("projectId")
    region = _host("region")
    subnetwork = ref("mgmtSubnetName")
    role = "roles/compute.networkUser"
    member = _smember
  }, _afterApis) for _sid, _smember in {"gke-agent" = _gkeAgentMember, "apis-agent" = _apisAgent}] + [
    _entry("host-service-agent-user", "gcp:projects/iAMMember:IAMMember", "host-service-agent-user", ProjectIAMMemberArgs {project = _host("projectId"), role = "roles/container.hostServiceAgentUser", member = _gkeAgentMember}, [])
    _entry("host-firewall-admin", "gcp:projects/iAMMember:IAMMember", "host-firewall-admin", ProjectIAMMemberArgs {project = _host("projectId"), role = "roles/compute.securityAdmin", member = _gkeAgentMember}, [])
    # Keys owned by security, used here.
    _entry("keyGrant", "gcp:kms/cryptoKeyIAMMember:CryptoKeyIAMMember", "gke-agent-uses-gke-secrets", CryptoKeyIAMMemberArgs {cryptoKeyId = stackOutput("security", ["gkeSecretsKeyId"]), role = "roles/cloudkms.cryptoKeyEncrypterDecrypter", member = _gkeAgentMember}, [])
    _entry("cloudsqlAgent", "gcp:projects/serviceIdentity:ServiceIdentity", "cloudsql-agent", ServiceIdentityArgs {project = _projectId, service = "sqladmin.googleapis.com"}, _afterApis)
    _entry("cloudsqlKeyGrant", "gcp:kms/cryptoKeyIAMMember:CryptoKeyIAMMember", "cloudsql-agent-uses-cloudsql", CryptoKeyIAMMemberArgs {cryptoKeyId = stackOutput("security", ["cloudsqlKeyId"]), role = "roles/cloudkms.cryptoKeyEncrypterDecrypter", member = ref("cloudsqlAgent.member")}, [])
  ]

  # Identities and their grants.
  _crossplaneMember = ref("crossplane.member")
  _crossplaneProdMember = ref("crossplaneProd.member")
  # Billing account roles are on the account; shl-mgmt is the providers' quota project.
  _providerGrants = lambda _id: str, _member: str -> [{str:}] {
    [_entry("${_id}-${roleSlug(r)}", "gcp:billing/accountIamMember:AccountIamMember", "${_id}-${roleSlug(r)}", BillingAccountIamMemberArgs {billingAccountId = _billing, role = r, member = _member}, []) for r in ["roles/billing.user", "roles/billing.costsManager"]] + _projectRoles(_id, _member, ["roles/serviceusage.serviceUsageConsumer"])
  }
  # crossplane@ on dev and staging (plus Shared VPC Admin for N6), crossplane-prod@ on prod.
  _envRoles = _PROJECT_LIFECYCLE_ROLES + _PLATFORM_ROLES
  _crossplaneFolders = _folderRoles("crossplane-dev", _folder("devFolderId"), _crossplaneMember, _envRoles + ["roles/compute.xpnAdmin"])
  _crossplaneFolders += _folderRoles("crossplane-staging", _folder("stagingFolderId"), _crossplaneMember, _envRoles + ["roles/compute.xpnAdmin"])
  _crossplaneFolders += _folderRoles("crossplane-network", _folder("networkFolderId"), _crossplaneMember, ["roles/compute.xpnAdmin"])
  _crossplaneFolders += _folderRoles("crossplane-prod", _folder("prodFolderId"), _crossplaneProdMember, _envRoles)
  _identities = [
    _account("nodeSa", "gke-nodes", "mgmt GKE nodes")
  ] + _projectRoles("gke-nodes", ref("nodeSa.member"), ["roles/container.defaultNodeServiceAccount"]) + [
    _account("crossplane", "crossplane", "Crossplane GCP providers: dev, staging")
    _account("crossplaneProd", "crossplane-prod", "Crossplane GCP providers: prod")
  ] + _crossplaneFolders + _providerGrants("crossplane", _crossplaneMember) + _providerGrants("crossplane-prod", _crossplaneProdMember) + [
    _entry("crossplane-impersonates-crossplane-prod", "gcp:serviceaccount/iAMMember:IAMMember", "crossplane-impersonates-crossplane-prod", ServiceAccountIAMMemberArgs {serviceAccountId = ref("crossplaneProd.name"), role = "roles/iam.serviceAccountTokenCreator", member = _crossplaneMember}, [])
    _entry("crossplane-net-dev-network-user", "gcp:compute/subnetworkIAMMember:SubnetworkIAMMember", "crossplane-net-dev-network-user", SubnetworkIAMMemberArgs {
      project = _devHost("projectId")
      region = _devHost("region")
      subnetwork = ref("devSubnetName")
      role = "roles/compute.networkUser"
      member = _crossplaneMember
    }, [])
    _account("eso", "external-secrets", "External Secrets Operator")
    _account("grafana", "grafana", "Grafana: Managed Prometheus, Cloud Logging, Cloud Trace")
  ] + _projectRoles("grafana", ref("grafana.member"), ["roles/monitoring.viewer", "roles/logging.viewer", "roles/cloudtrace.user"]) + [
    _account("openbao", "openbao", "OpenBao: Cloud KMS auto-unseal")
  ] + [_entry("openbao-${roleSlug(r)}", "gcp:kms/cryptoKeyIAMMember:CryptoKeyIAMMember", "openbao-${roleSlug(r)}", CryptoKeyIAMMemberArgs {cryptoKeyId = stackOutput("security", ["openbaoUnsealKeyId"]), role = r, member = ref("openbao.member")}, []) for r in ["roles/cloudkms.cryptoKeyEncrypterDecrypter", "roles/cloudkms.viewer"]] + [
    _account("ciBuilder", "ci-builder", "Tekton CI builder: pushes to Artifact Registry ci")
  ]

  # Cloud SQL (mgmt:postgres): one instance, one database per consumer.
  _databases = {eventStoreDb = "events", terranDb = "terran", todoDb = "todo", flagsmithDb = "flagsmith"}
  _postgres = [
    _entry("cloudSql", "app:db:PostgresInstance", "mgmt-postgres", PostgresInstanceArgs {
      project = _projectId
      region = _region
      tier = _m.postgresTier
      edition = "ENTERPRISE"
      availabilityType = "ZONAL"
      diskSizeGb = 20
      isProd = True
      databaseName = "keycloak"
      dbUser = "keycloak"
      accessors = [ref("eso.email")]
      encryptionKeyName = stackOutput("security", ["cloudsqlKeyId"])
      # index.ts refuses a host without privateServiceAccess at runtime.
      privateNetwork = _host("network")
    }, _afterApis + [ref("cloudsqlKeyGrant")])
  ] + [_entry(key, "app:db:PostgresDatabase", "mgmt-postgres-${db}", PostgresDatabaseArgs {
    project = _projectId
    region = _region
    isProd = True
    instance = ref("cloudSql.instance.name")
    databaseName = db
    dbUser = db
    accessors = [ref("eso.email")]
  }, _afterApis) for key, db in _databases] if _m.postgres else []

  # Admission policy, the cluster, Workload Identity.
  _cluster = [
    _entry("binaryAuthorization", "gcp:binaryauthorization/policy:Policy", "mgmt", BinaryAuthorizationPolicyArgs {
      project = _projectId
      globalPolicyEvaluationMode = "ENABLE"
      admissionWhitelistPatterns = [AdmissionWhitelistPattern {namePattern = "${_region}-docker.pkg.dev/${_prefix}-artifacts/**"}]
      defaultAdmissionRule = AdmissionRule {evaluationMode = "ALWAYS_DENY", enforcementMode = "DRYRUN_AUDIT_LOG_ONLY"}
    }, _afterApis)
    _entry("gke", "org:gcp-gke:GkeCluster", "mgmt", GkeClusterArgs {
      project = _projectId
      name = "mgmt"
      location = _zone
      network = _host("network")
      subnetwork = _host("subnet")
      podsRange = _host("podsRange")
      servicesRange = _host("servicesRange")
      nodeServiceAccount = ref("nodeSa.email")
      databaseEncryptionKey = stackOutput("security", ["gkeSecretsKeyId"])
      securityGroup = _group("gke-security-groups")
      binaryAuthorization = True
      monitoringPackages = ["POD", "DEPLOYMENT", "STATEFULSET", "CADVISOR", "KUBELET"]
      nodePools = {
        default = NodePoolSpec {
          machineType = _m.nodeMachineType
          minNodesPerZone = _m.minNodesPerZone
          maxNodesPerZone = _m.maxNodesPerZone
          diskType = "pd-standard"
          diskSizeGb = 50
        }
        ci = NodePoolSpec {
          machineType = _m.ciMachineType
          minNodesPerZone = 0
          maxNodesPerZone = _m.ciMaxNodesPerZone
          spot = True
          taints = [NodeTaint {key = "cloud.google.com/gke-spot", value = "true", effect = "NO_SCHEDULE"}]
          diskType = "pd-standard"
          diskSizeGb = 50
        }
      }
    }, [ref("attachment"), ref("keyGrant"), ref("subnet-network-user-gke-agent"), ref("subnet-network-user-apis-agent"), ref("host-service-agent-user"), ref("host-firewall-admin")])
    _workloadIdentity("crossplane", "crossplane", _crossplaneKsa)
    _workloadIdentity("eso", "eso", _esoKsa)
    _workloadIdentity("grafana", "grafana", {namespace = "monitoring", name = "grafana"})
    _workloadIdentity("gmp-frontend", "grafana", {namespace = "monitoring", name = "gmp-frontend"})
    _workloadIdentity("openbao", "openbao", {namespace = "openbao", name = "openbao"})
    _workloadIdentity("ci-builder", "ciBuilder", {namespace = "ci", name = "builder"})
  ]

  # Artifact Registry `ci`, the nx cache bucket, cluster access.
  _storage = [
    _entry("ciRepo", "gcp:artifactregistry/repository:Repository", "ci", RepositoryArgs {
      project = _projectId
      location = _region
      repositoryId = "ci"
      description = "Images built by the mgmt cluster CI (gitops platform/tekton/ci)"
      format = "DOCKER"
      dockerConfig = DockerConfig {immutableTags = True}
      labels = _labels("ci")
    }, _afterApis)
  ] + [_entry("ci-${g[0]}", "gcp:artifactregistry/repositoryIamMember:RepositoryIamMember", "ci-${g[0]}", RepositoryIamMemberArgs {
    project = _projectId
    location = _region
    repository = ref("ciRepo.repositoryId")
    role = g[1]
    member = g[2]
  }, []) for g in [["ci-builder-writer", "roles/artifactregistry.writer", ref("ciBuilder.member")], ["gke-nodes-reader", "roles/artifactregistry.reader", ref("nodeSa.member")]]] + [
    _entry("nxCacheBucket", "gcp:storage/bucket:Bucket", "nx-cache", BucketArgs {
      project = _projectId
      name = _projectId + "-nx-cache"
      location = _region.upper()
      uniformBucketLevelAccess = True
      publicAccessPrevention = "enforced"
      lifecycleRules = [LifecycleRule {action = LifecycleRuleAction {$type = "Delete"}, condition = LifecycleRuleCondition {age = 14}}]
      forceDestroy = True
      labels = _labels("nx-cache")
    }, _afterApis)
  ] + [_entry("nx-cache-${roleSlug(r)}", "gcp:storage/bucketIAMMember:BucketIAMMember", "nx-cache-${roleSlug(r)}", BucketIAMMemberArgs {bucket = ref("nxCacheBucket.name"), role = r, member = _ksaPrincipal({namespace = "nx-cache", name = "butler-cache"})}, [ref("gke")]) for r in ["roles/storage.objectViewer", "roles/storage.objectCreator"]] + [
    _entry("admins-container-admin", "gcp:projects/iAMMember:IAMMember", "admins-container-admin", ProjectIAMMemberArgs {project = _projectId, role = "roles/container.admin", member = "group:" + _adminGroup}, [])
    _entry("developers-cluster-viewer", "gcp:projects/iAMMember:IAMMember", "developers-cluster-viewer", ProjectIAMMemberArgs {project = _projectId, role = "roles/container.clusterViewer", member = "group:" + _developerGroup}, [])
  ]

  # The org domain's public zone, main-gateway's address, the records.
  _records = [
    {id = "apex-a", name = "", $type = "A", ttl = 3600, rrdatas = ["15.197.148.33", "3.33.130.190"]}
    {id = "www", name = "www.", $type = "CNAME", ttl = 3600, rrdatas = ["${_domain}."]}
    {id = "mx", name = "", $type = "MX", ttl = 3600, rrdatas = ["1 smtp.google.com."]}
    {id = "apex-txt", name = "", $type = "TXT", ttl = 3600, rrdatas = ['"v=spf1 include:_spf.google.com ~all"', '"google-site-verification=LVj_-1XTC4W5cTVeoFjS0MMa2cOs1JTdYZ6HdM7IxiE"']}
    {id = "dkim", name = "google._domainkey.", $type = "TXT", ttl = 3600, rrdatas = [_DKIM]}
    {id = "dmarc", name = "_dmarc.", $type = "TXT", ttl = 3600, rrdatas = ['"v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:dmarc_rua@onsecureserver.net;"']}
    {id = "wildcard", name = "*.", $type = "A", ttl = 300, rrdatas = [ref("gatewayIp.address")]}
  ]
  _dns = [
    _entry("dnsZone", "gcp:dns/managedZone:ManagedZone", "org-domain", ManagedZoneArgs {
      project = _projectId
      name = _domain.replace(".", "-")
      dnsName = "${_domain}."
      description = "${_domain}: Workspace mail, platform hosts (main-gateway)"
      visibility = "public"
      dnssecConfig = DnssecConfig {state = "on"}
      labels = _labels("dns")
    }, _afterApis)
    _entry("gatewayIp", "gcp:compute/address:Address", "main-gateway", AddressArgs {
      project = _projectId
      region = _region
      name = "main-gateway"
      addressType = "EXTERNAL"
      description = "main-gateway (gitops platform/gateway), *.${_domain}"
      labels = _labels("gateway")
    }, _afterApis)
  ] + [_entry("dns-${r.id}", "gcp:dns/recordSet:RecordSet", "dns-${r.id}", RecordSetArgs {
    project = _projectId
    managedZone = ref("dnsZone.name")
    name = "${r.name}${_domain}."
    $type = r.$type
    ttl = r.ttl
    rrdatas = r.rrdatas
  }, []) for r in _records] + [
    _entry("cert-manager-dns", "gcp:dns/dnsManagedZoneIamMember:DnsManagedZoneIamMember", "cert-manager-dns", DnsManagedZoneIamMemberArgs {project = _projectId, managedZone = ref("dnsZone.name"), role = "roles/dns.admin", member = _ksaPrincipal({namespace = "cert-manager", name = "cert-manager"})}, [ref("gke")])
  ]

  # Flux GitHub App secret: the container only.
  _secrets = [
    _entry("githubAppSecret", "gcp:secretmanager/secret:Secret", "flux-github-app", SecretArgs {
      project = _projectId
      secretId = "flux-github-app"
      replication = SecretReplication {
        userManaged = SecretUserManaged {replicas = [SecretReplica {location = _region}]}
      }
      labels = _labels("flux")
    }, _afterApis)
    _entry("flux-github-app-admins", "gcp:secretmanager/secretIamMember:SecretIamMember", "flux-github-app-admins", SecretIamMemberArgs {project = _projectId, secretId = ref("githubAppSecret.secretId"), role = "roles/secretmanager.secretAccessor", member = "group:" + _adminGroup}, [])
  ]

  _all = _foundation + _identities + _postgres + _cluster + _storage + _dns + _secrets
  assert len({e.key: 0 for e in _all}) == len(_all), "two resources share a map key"

  # Tier-0 facts gitops substitutes (flux-system/cluster-identity).
  _clusterIdentity = {
    CLUSTER_NAME = "mgmt"
    CLUSTER_RUNTIME = "gke"
    GCP_ADMIN_PROJECT = _projectId
    GCP_REGION = _region
    GCP_BILLING_ACCOUNT = _billing
    GCP_PROJECT_PREFIX = _prefix
    DEV_FOLDER = "folders/" + _folder("devFolderId")
    XP_KSA = _crossplaneKsa.name
    XP_GSA_EMAIL = ref("crossplane.email")
    ESO_GSA_EMAIL = ref("eso.email")
    K8S_ADMIN_GROUP = _adminGroup
    K8S_DEVELOPER_GROUP = _developerGroup
    GRAFANA_GSA_EMAIL = ref("grafana.email")
    GATEWAY_IP = ref("gatewayIp.address")
    OPENBAO_GSA_EMAIL = ref("openbao.email")
    CI_IMAGE_REGISTRY = "${_region}-docker.pkg.dev/" + _projectId + "/" + ref("ciRepo.repositoryId")
    CI_BUILDER_GSA_EMAIL = ref("ciBuilder.email")
    NX_CACHE_STORAGE = "gs://" + ref("nxCacheBucket.name")
  }

  _pgOutputs = {
    postgresConnectionName = ref("cloudSql.connectionName")
    postgresPrivateIp = ref("cloudSql.instance.privateIpAddress")
    postgresPasswordSecret = ref("cloudSql.passwordSecret.id")
    eventStoreDbPasswordSecret = ref("eventStoreDb.passwordSecret.id")
    terranDbPasswordSecret = ref("terranDb.passwordSecret.id")
    todoDbPasswordSecret = ref("todoDb.passwordSecret.id")
    flagsmithDbPasswordSecret = ref("flagsmithDb.passwordSecret.id")
  } if _m.postgres else {}

  Spec {
    project = _projectName
    stack = _stackName
    description = "shl-mgmt - mgmt GKE cluster, its identities, and the hand-off to Flux"
    config = c
    variables = _variables
    resources = {e.key: e.resource for e in _all}
    fluxBootstrap = FunctionCall {
      module = "./src/flux"
      function = "bootstrapFlux"
      args = FluxBootstrapArgs {
        project = _projectId
        githubAppSecretId = ref("githubAppSecret.secretId")
        dnsEndpoint = ref("gke.dnsEndpoint")
        operatorVersion = _m.fluxOperatorVersion
        fluxVersion = _m.fluxVersion
        repoUrl = _m.gitopsRepoUrl
        branch = _m.gitopsBranch
        path = _m.gitopsPath
        clusterIdentity = _clusterIdentity
        webHostname = _m.fluxHostname or "flux.${_domain}"
      }
      options = ResourceOptions {dependsOn = [ref('gke.nodePools["default"]')]}
    } if _m.fluxBootstrap else Undefined
    outputs = {
      mgmtProjectId = _projectId
      mgmtProjectNumber = ref("project.number")
      clusterName = ref("gke.cluster.name")
      dnsEndpoint = ref("gke.dnsEndpoint")
      workloadPool = ref("gke.workloadPool")
      nodeServiceAccountMember = ref("nodeSa.member")
      crossplaneServiceAccountEmail = ref("crossplane.email")
      crossplaneProdServiceAccountEmail = ref("crossplaneProd.email")
      esoServiceAccountEmail = ref("eso.email")
      dnsNameServers = ref("dnsZone.nameServers")
      gatewayAddress = ref("gatewayIp.address")
      fluxGithubAppSecret = ref("githubAppSecret.id")
      **_pgOutputs
      clusterIdentityValues = _clusterIdentity
      getCredentials = "gcloud container clusters get-credentials mgmt --location=${_zone} --project=" + _projectId + " --dns-endpoint"
    }
  }
}
