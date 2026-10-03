# vm-gcp

GCP backend for the `VirtualMachine` XR (`cloud.example.org/v1alpha1`). Typed
against the `gcp-compute` schema package (`../../../providers/gcp-compute`), it
maps the portable machine onto one Compute `Instance`. The Composition
`vm-gcp` runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/vm-gcp`, followed by `function-auto-ready`.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Instance` (`compute.gcp.m.upbound.io`) | always | `crossplane.io/external-name` pins the instance name to the XR name |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | required; zone defaults to `<region>-a` |
| `zone` | `zone` |
| `machineType` / `size` | `machineType`; `machineType` wins, else `small` `e2-medium`, `medium` `e2-standard-2`, `large` `e2-standard-4`, `xlarge` `e2-standard-8` (default `small`) |
| `imageId` / `image` | `bootDisk.initializeParams.image`; `imageId` wins, else the public image family for `ubuntu-24-04` (default), `ubuntu-22-04` or `debian-12` |
| `diskGb` | `bootDisk.initializeParams.size` (default `30`) |
| `network.subnetId` | `networkInterface[0].subnetwork`; without it, `network: default` |
| `network.publicIp` | `accessConfig: [{}]` (ephemeral public address) |
| `network.securityGroupIds` | rejected: the render fails (use GCP firewall rules) |
| `sshKey` | metadata `ssh-keys: <user>:<publicKey>` |
| `userData` | metadata `startup-script` |
| `spot` | `scheduling`: `provisioningModel: SPOT`, `preemptible: true`, `automaticRestart: false`, `instanceTerminationAction: STOP` |
| `deletionPolicy` | `Orphan` sets `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `forProvider.labels` |

Ignored: `storageClass`, `resourceGroup`.

Status written back from the observed instance: `provider: gcp`, `ready`
(`instanceId` or `id` observed), `name` (XR name), and when observed
`privateIp` (first NIC `networkIp`), `publicIp` (first access config `natIp`),
`id` and the console `cloud-url`.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`region: us-central1`):

```bash
kcl run packages/cloud/vm/gcp
```

Pass a real XR the way `function-kcl` does, as `params.oxr`:

```bash
kcl run packages/cloud/vm/gcp \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/vm/xrd/examples/vm-gcp.yaml)}"
```

`pnpm exec nx run vm-gcp:render` runs `crossplane render` against
`../xrd/examples/vm-gcp.yaml` (needs the Crossplane CLI and docker). On a
cluster: `just install-module vm` installs the XRD and every backend
Composition; `just e2e vm` runs the full kind e2e.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `vm.k` | `render`, `status`, `machine_for`, `image_for` |
| `vm_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `vm-gcp` |

## Development

```bash
pnpm exec nx run vm-gcp:test     # kcl test
pnpm exec nx run vm-gcp:lint     # kcl lint
pnpm exec nx run vm-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
