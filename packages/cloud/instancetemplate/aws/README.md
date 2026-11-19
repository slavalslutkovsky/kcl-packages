# instancetemplate-aws

AWS backend for the `InstanceTemplate` XR (`cloud.example.org/v1alpha1`).
Typed against the `aws-ec2` schema package (`../../../providers/aws-ec2`), it
maps the portable template onto an EC2 `LaunchTemplate` and launches every
`spec.instances` entry FROM it as an EC2 `Instance`
(`launchTemplate: {id, version: $Default}`). The Composition
`instancetemplate-aws` runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/instancetemplate-aws`, followed by
`function-auto-ready`.

AWS has no account-independent image families, so `spec.imageId` (an AMI ID)
is required; the render fails without it rather than guessing an AMI.

Instances reference the template by its id, which only exists once the
`LaunchTemplate` is observed: the first reconcile composes the template (and
key pair), the next one the instances.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `LaunchTemplate` (`ec2.aws.m.upbound.io`) | always | `name` = XR name; `updateDefaultVersion: true`, so each spec change becomes the `$Default` the instances launch from |
| `KeyPair` (`ec2.aws.m.upbound.io`) | `sshKey` set | `crossplane.io/external-name` pins the AWS key name to the XR name; the template's `keyName` is that string |
| `Instance` (`ec2.aws.m.upbound.io`) | per `spec.instances` entry, once the template id is observed | resource name `instance-<name>`; `Name` tag `<template>-<name>` |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.region` on every MR; required |
| `imageId` | template `imageId`; required |
| `machineType` / `size` | template `instanceType`; `machineType` wins, else `small` `t3.medium`, `medium` `m5.large`, `large` `m5.xlarge`, `xlarge` `m5.2xlarge` (default `small`) |
| `diskGb` | each Instance's `rootBlockDevice.volumeSize` (default `30`) — a launch template can only size a volume by device name, which depends on the AMI |
| `network.subnetId` / `network.publicIp` | template `networkInterfaces[0]` (`subnetId`, `associatePublicIpAddress`); security groups move onto that interface |
| `network.securityGroupIds` | template `vpcSecurityGroupIds` when no interface is needed, else the interface's `securityGroups` |
| `sshKey.publicKey` | `KeyPair.publicKey`; `sshKey.user` is unused (the AMI picks the login user) |
| `userData` | template `userData`, base64-encoded |
| `spot` | template `instanceMarketOptions.marketType: spot` |
| `deletionPolicy` | `Orphan` sets `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | template `tags` and `tagSpecifications` (instance, volume); each Instance carries `tags \| instances[].tags \| {Name}` so the MR's tag set agrees with the launch-time tags |
| `instances[].name` | one `Instance`, `Name` tag `<template>-<name>` |
| `instances[].userData` | that Instance's `userData` (overrides the template's) |
| `instances[].tags` | merged over `tags` on that Instance |

Ignored: `zone`, `image`, `storageClass`, `resourceGroup`, `instances[].zone`.

Status: `provider: aws`, `templateName` (XR name), and once observed
`templateId` (the `lt-` id) and the launch template console `cloud-url`;
`instances[]` with `name`, `ready` (instance id observed), `id`, `privateIp`,
`publicIp`. `ready` is true once the template and every instance are observed.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR with an observed template id, so the instance is rendered too:

```bash
kcl run packages/cloud/instancetemplate/aws/main.k
```

Pass a real XR the way `function-kcl` does, as `params.oxr` (and observed
resources as `params.ocds`):

```bash
kcl run packages/cloud/instancetemplate/aws/main.k \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/instancetemplate/xrd/examples/instancetemplate-aws.yaml), \"ocds\": {}}"
```

`pnpm exec nx run instancetemplate-aws:render` runs `crossplane render` against
`../xrd/examples/instancetemplate-aws.yaml` (needs the Crossplane CLI and docker).
On a cluster: `just install-module instancetemplate` installs the XRD and every
backend Composition.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `tpl.k` | `render`, `status` and the mapping helpers |
| `tpl_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `instancetemplate-aws` |

## Development

```bash
pnpm exec nx run instancetemplate-aws:test     # kcl test
pnpm exec nx run instancetemplate-aws:lint     # kcl lint
pnpm exec nx run instancetemplate-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
