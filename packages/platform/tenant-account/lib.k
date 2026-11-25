"""
tenant-account: client-owned AWS accounts as Crossplane ProviderConfigs.

A tenant whose buckets must be billed to its own AWS account gets a namespaced
`ProviderConfig` (aws.m.upbound.io/v1beta1) in its namespace that assumes a
role in that account. A Bucket XR naming it in `spec.providerConfigName`
composes every managed resource there, so AWS bills the client directly and
the platform never becomes the payer.

One values file, two sides:

  render(values)              cluster side: a ProviderConfig per account, plus
                              the ValidatingAdmissionPolicy that makes
                              spec.providerConfigName mandatory (and one of the
                              namespace's own configs) on every Bucket in those
                              namespaces, so a bucket cannot fall back to the
                              platform's account by omission
  render_client(values, ns)   client side: per account, the CloudFormation
                              template the client deploys to create the role
                              (and, with accessRoles, the boundary that caps
                              the access roles the platform may create)
"""

import aws_family.models.unknown as aws
import k8s.api.admissionregistration.v1 as adm
import json
import regex

# The ValidatingAdmissionPolicy and its binding share this name.
policy_name = "bucket-client-account"

# Label on every rendered ProviderConfig: which AWS account it reaches.
account_label = "cloud.example.org/aws-account-id"

# Tag the bucket aws backend puts on every boundary-capped access role
# (packages/cloud/bucket/aws/bucket.k `boundary_tag`). Keep the two in step:
# the provisioner may only update, tag or delete roles bearing it.
boundary_tag = "cloud.example.org/permissions-boundary"

_iam_role_name = r"^[\w+=,.@-]{1,64}$"

schema Platform:
  """
    The platform side of every trust: the IAM role the Crossplane AWS provider
    runs as (the only principal a client role trusts), how the provider obtains
    it, and the default name of the role clients create.
    """
  roleArn: str
  credentials: aws.ProviderConfigSpecCredentials = aws.ProviderConfigSpecCredentials {source = "IRSA"}
  roleName: str = "platform-provisioner"

  check:
    regex.match(roleArn, r"^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$"), "platform.roleArn must be an IAM role ARN (arn:aws:iam::<12 digits>:role/<name>), got '${roleArn}'"
    regex.match(roleName, _iam_role_name), "platform.roleName '${roleName}' is not an IAM role name (1-64 of A-Za-z0-9+=,.@_-)"

schema Account:
  """
    One client account bound to one tenant namespace. `name` is the
    ProviderConfig's name, i.e. what a Bucket's spec.providerConfigName says.
    """
  namespace: str
  accountId: str
  externalId: str
  name: str = "aws"
  roleName?: str
  accessRoles: bool = False

  check:
    regex.match(namespace, r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$") and len(namespace) <= 63, "account namespace '${namespace}' is not a namespace name (RFC 1123 label)"
    regex.match(accountId, r"^[0-9]{12}$"), "${namespace}: accountId must be 12 digits, got '${accountId}'"
    regex.match(name, r"^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$"), "${namespace}: name '${name}' is not a ProviderConfig name (the Bucket XRD's providerConfigName pattern)"
    2 <= len(externalId) <= 1224 and regex.match(externalId, r"^[\w+=,.@:/-]+$"), "${namespace}: externalId must be 2-1224 of A-Za-z0-9+=,.@:/_- (the sts:ExternalId alphabet)"
    not roleName or regex.match(roleName, _iam_role_name), "${namespace}: roleName '${roleName}' is not an IAM role name"

_dups = lambda accounts: [Account] -> [str] {
  _keys = ["${a.namespace}/${a.name}" for a in accounts]
  [k for i, k in _keys if k in _keys[:i:]]
}

schema Values:
  platform: Platform
  accounts: [Account]

  check:
    len(accounts) > 0, "accounts: list at least one client account"
    len(_dups(accounts)) == 0, "accounts: each namespace/name pair is one ProviderConfig, duplicated: ${_dups(accounts)}"

_partition = lambda p: Platform -> str {
  p.roleArn.split(":")[1]
}

_role_name = lambda p: Platform, a: Account -> str {
  a.roleName or p.roleName
}

# ARN of the role the client creates, which the ProviderConfig assumes.
role_arn = lambda p: Platform, a: Account -> str {
  "arn:${_partition(p)}:iam::${a.accountId}:role/${_role_name(p, a)}"
}

# ARN of the access boundary (accessRoles only): what a Bucket XR in this
# account sets as spec.federation.awsPermissionsBoundary.
boundary_arn = lambda p: Platform, a: Account -> str {
  "arn:${_partition(p)}:iam::${a.accountId}:policy/${_role_name(p, a)}-access-boundary"
}

# ── cluster side ────────────────────────────────────────────────────────────
provider_config = lambda p: Platform, a: Account -> aws.ProviderConfig {
  aws.ProviderConfig {
    metadata = {
      name = a.name
      namespace = a.namespace
      labels = {"${account_label}" = a.accountId}
    }
    spec = {
      credentials = p.credentials
      assumeRoleChain = [{roleARN = role_arn(p, a), externalID = a.externalId}]
    }
  }
}

# Every Bucket created or updated in a tenant namespace must name one of that
# namespace's ProviderConfigs. The allowed names are a CEL map literal, so
# the policy needs no params object; the binding scopes it to exactly the
# namespaces listed (kubernetes.io/metadata.name is set on every namespace).
admission = lambda accounts: [Account] -> [any] {
  _nss = sorted([ns for ns in {a.namespace: None for a in accounts}])
  _allowed = {ns: sorted([a.name for a in accounts if a.namespace == ns]) for ns in _nss}
  [
    adm.ValidatingAdmissionPolicy {
      metadata.name = policy_name
      spec = {
        failurePolicy = "Fail"
        matchConstraints.resourceRules = [{apiGroups = ["cloud.example.org"], apiVersions = ["*"], operations = ["CREATE", "UPDATE"], resources = ["buckets"]}]
        variables = [{name = "allowed", expression = "${json.encode(_allowed, sort_keys=True)}[object.metadata.namespace]"}]
        validations = [{
          expression = "has(object.spec.providerConfigName) && object.spec.providerConfigName in variables.allowed"
          messageExpression = "'Bucket ' + object.metadata.name + ': namespace ' + object.metadata.namespace + ' bills its buckets to a client account, set spec.providerConfigName to ' + variables.allowed.join(' or ')"
          reason = "Invalid"
        }]
      }
    }
    adm.ValidatingAdmissionPolicyBinding {
      metadata.name = policy_name
      spec = {
        policyName = policy_name
        validationActions = ["Deny"]
        matchResources.namespaceSelector.matchExpressions = [{key = "kubernetes.io/metadata.name", operator = "In", values = _nss}]
      }
    }
  ]
}

render = lambda v: Values -> [any] {
  [provider_config(v.platform, a) for a in v.accounts] + admission(v.accounts)
}

# ── client side ─────────────────────────────────────────────────────────────
# What the provisioner needs to compose a Bucket and every companion MR of the
# aws backend: bucket create/delete/configuration (*Bucket* covers CreateBucket,
# DeleteBucket, ListBucket*, Get/PutBucket*; Get/Put*Configuration covers
# lifecycle, encryption, accelerate, ...), plus object deletes so forceDestroy
# can empty a bucket. Object reads and writes are not granted.
_bucket_actions = ["s3:*Bucket*", "s3:Get*Configuration", "s3:Put*Configuration"]
_force_destroy_actions = ["s3:DeleteObject", "s3:DeleteObjectVersion"]

# accessRoles: CreateRole, PutRolePolicy and DeleteRolePolicy take an
# iam:PermissionsBoundary condition and are allowed only for roles capped by
# the account's boundary (CreateRole must also carry the boundary tag)...
# ...the rest of a role's lifecycle only on roles tagged with that boundary
# (the bucket backend tags every capped role), so no pre-existing role of the
# client can be re-trusted or deleted...
_tagged_iam = ["iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:DeleteRole", "iam:TagRole"]
# ...and reads anywhere under the tenant's role-name prefix.
_read_iam = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:ListRoleTags"]

# Ceiling of an access role: S3 object data (the bucket backend's admin role
# and below) and use of the bucket's KMS key; never IAM, never bucket
# configuration writes. The role's inline policy narrows it to one bucket.
_boundary_actions = ["s3:Get*", "s3:List*", "s3:PutObject*", "s3:DeleteObject*", "s3:AbortMultipartUpload", "s3:RestoreObject", "s3:BypassGovernanceRetention", "kms:Decrypt", "kms:GenerateDataKey"]

# The provisioner role's inline policies.
provisioner_policies = lambda p: Platform, a: Account -> [any] {
  _part = _partition(p)
  _buckets = [{
    PolicyName = "buckets"
    PolicyDocument = {
      Version = "2012-10-17"
      Statement = [
        {Sid = "Buckets", Effect = "Allow", Action = _bucket_actions, Resource = "arn:${_part}:s3:::*"}
        {Sid = "ForceDestroy", Effect = "Allow", Action = _force_destroy_actions, Resource = "arn:${_part}:s3:::*/*"}
      ]
    }
  }]
  _roles = "arn:${_part}:iam::${a.accountId}:role/${a.namespace}-*"
  _b = boundary_arn(p, a)
  _access = [{
    PolicyName = "access-roles"
    PolicyDocument = {
      Version = "2012-10-17"
      Statement = [
        {Sid = "CreateCapped", Effect = "Allow", Action = ["iam:CreateRole"], Resource = _roles, Condition.StringEquals = {"iam:PermissionsBoundary" = _b, "aws:RequestTag/${boundary_tag}" = _b}}
        {Sid = "InlinePoliciesOfCapped", Effect = "Allow", Action = ["iam:PutRolePolicy", "iam:DeleteRolePolicy"], Resource = _roles, Condition.StringEquals = {"iam:PermissionsBoundary" = _b}}
        {Sid = "LifecycleOfTagged", Effect = "Allow", Action = _tagged_iam, Resource = _roles, Condition = {StringEquals = {"aws:ResourceTag/${boundary_tag}" = _b}, StringEqualsIfExists = {"aws:RequestTag/${boundary_tag}" = _b}}}
        {Sid = "UntagOfTagged", Effect = "Allow", Action = ["iam:UntagRole"], Resource = _roles, Condition = {StringEquals = {"aws:ResourceTag/${boundary_tag}" = _b}, "ForAllValues:StringNotEquals" = {"aws:TagKeys" = [boundary_tag]}}}
        {Sid = "Read", Effect = "Allow", Action = _read_iam, Resource = _roles}
      ]
    }
  }] if a.accessRoles else []
  _buckets + _access
}

# One account's CloudFormation template (deploy with CAPABILITY_NAMED_IAM).
client_template = lambda p: Platform, a: Account -> {str:} {
  _rn = _role_name(p, a)
  _boundary = {
    AccessBoundary = {
      Type = "AWS::IAM::ManagedPolicy"
      Properties = {
        ManagedPolicyName = "${_rn}-access-boundary"
        Description = "Ceiling of every access role the platform creates for ${a.namespace}: S3 object data and KMS key use only."
        PolicyDocument = {Version = "2012-10-17", Statement = [{Sid = "BucketData", Effect = "Allow", Action = _boundary_actions, Resource = "*"}]}
      }
    }
  } if a.accessRoles else {}
  {
    AWSTemplateFormatVersion = "2010-09-09"
    Description = "Lets the platform (${p.roleArn}) create the Buckets of tenant ${a.namespace} in this account, billed to this account. ProviderConfig ${a.namespace}/${a.name}."
    Resources = {
      ProvisionerRole = {
        Type = "AWS::IAM::Role"
        Properties = {
          RoleName = _rn
          Description = "Assumed by the platform's Crossplane provider for tenant ${a.namespace}"
          MaxSessionDuration = 3600
          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Sid = "Platform"
              Effect = "Allow"
              Principal.AWS = p.roleArn
              Action = "sts:AssumeRole"
              Condition.StringEquals = {"sts:ExternalId" = a.externalId}
            }]
          }
          Policies = provisioner_policies(p, a)
        }
      }
    } | _boundary
    Outputs = {
      RoleArn = {Description = "Assumed by ProviderConfig ${a.namespace}/${a.name}", Value = {"Fn::GetAtt" = ["ProvisionerRole", "Arn"]}}
      if a.accessRoles:
        AccessBoundaryArn = {Description = "spec.federation.awsPermissionsBoundary of every Bucket with access in this account", Value = {Ref = "AccessBoundary"}}
    }
  }
}

# Client templates, optionally only one namespace's.
render_client = lambda v: Values, namespace: str -> [any] {
  _picked = [a for a in v.accounts if not namespace or a.namespace == namespace]
  assert _picked, "no account for namespace '${namespace}' (have: ${sorted([a.namespace for a in v.accounts])})"
  [client_template(v.platform, a) for a in _picked]
}
