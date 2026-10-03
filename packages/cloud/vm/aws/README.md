# vm-aws

AWS backend for the `VirtualMachine` XR (`cloud.example.org/v1alpha1`). Typed
against the `aws-ec2` schema package (`../../../providers/aws-ec2`), it maps
the portable machine onto an EC2 `Instance`, plus a `KeyPair` when
`spec.sshKey` is set. The Composition `vm-aws` runs it through `function-kcl`
from `oci://docker.io/yurikrupnik/vm-aws`, followed by `function-auto-ready`.

AWS has no account-independent image families, so `spec.imageId` (an AMI ID)
is required here; the render fails without it rather than guessing an AMI.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Instance` (`ec2.aws.m.upbound.io`) | always | Root block device sized from `diskGb` |
| `KeyPair` (`ec2.aws.m.upbound.io`) | `sshKey` set | `crossplane.io/external-name` pins the AWS key name to the XR name; the instance's `keyName` is that same string |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.region` on both MRs; required |
| `imageId` | `ami`; required |
| `machineType` / `size` | `instanceType`; `machineType` wins, else `small` `t3.medium`, `medium` `m5.large`, `large` `m5.xlarge`, `xlarge` `m5.2xlarge` (default `small`) |
| `diskGb` | `rootBlockDevice.volumeSize` (default `30`) |
| `network.subnetId` | `subnetId` |
| `network.securityGroupIds` | `vpcSecurityGroupIds` |
| `network.publicIp` | `associatePublicIpAddress: true` |
| `sshKey.publicKey` | `KeyPair.publicKey`; `sshKey.user` is unused (the AMI picks the login user) |
| `userData` | `userData` |
| `spot` | `instanceMarketOptions.marketType: spot` |
| `deletionPolicy` | `Orphan` sets `managementPolicies: [Observe, Create, Update, LateInitialize]` on both MRs |
| `tags` | `forProvider.tags` on the instance |

Ignored: `zone`, `image`, `storageClass`, `resourceGroup`.

Status written back from the observed instance: `provider: aws`, `ready`
(instance id observed), `name` (XR name), and when observed `privateIp`,
`publicIp`, `id` and the EC2 console `cloud-url`.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`region: us-east-1`, a placeholder `imageId`):

```bash
kcl run packages/cloud/vm/aws
```

Pass a real XR the way `function-kcl` does, as `params.oxr`:

```bash
kcl run packages/cloud/vm/aws \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/vm/xrd/examples/vm-aws.yaml)}"
```

`pnpm exec nx run vm-aws:render` runs `crossplane render` against
`../xrd/examples/vm-aws.yaml` (needs the Crossplane CLI and docker). On a
cluster: `just install-module vm` installs the XRD and every backend
Composition; `just e2e vm` runs the full kind e2e.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `vm.k` | `render`, `status`, `machine_for` |
| `vm_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `vm-aws` |

## Development

```bash
pnpm exec nx run vm-aws:test     # kcl test
pnpm exec nx run vm-aws:lint     # kcl lint
pnpm exec nx run vm-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
