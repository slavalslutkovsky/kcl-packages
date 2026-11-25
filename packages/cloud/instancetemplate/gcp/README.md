# instancetemplate-gcp

GCP backend for the `InstanceTemplate` XR (`cloud.example.org/v1alpha1`).
Typed against the `gcp-compute` schema package (`../../../providers/gcp-compute`),
it maps the portable template onto a global Compute `InstanceTemplate` and
creates every `spec.instances` entry FROM it as an `InstanceFromTemplate`,
bound to the template by `sourceInstanceTemplateSelector.matchControllerRef`.
The Composition `instancetemplate-gcp` runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/instancetemplate-gcp`, followed by
`function-auto-ready`.

GCP instance templates are immutable: the provider refuses an in-place update
of the composed `InstanceTemplate`. Roll a template by creating a new
`InstanceTemplate` XR; machines already created from the old one keep running.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `InstanceTemplate` (`compute.gcp.m.upbound.io`) | always | `name` = XR name |
| `InstanceFromTemplate` (`compute.gcp.m.upbound.io`) | per `spec.instances` entry | resource name `instance-<name>`; machine name `<template>-<name>` |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | required; instance zone defaults to `<region>-a` |
| `zone` | default instance `zone` |
| `machineType` / `size` | template `machineType`; `machineType` wins, else `small` `e2-medium`, `medium` `e2-standard-2`, `large` `e2-standard-4`, `xlarge` `e2-standard-8` (default `small`) |
| `imageId` / `image` | template boot `disk[0].sourceImage`; `imageId` wins, else the public image family for `ubuntu-24-04` (default), `ubuntu-22-04` or `debian-12` |
| `diskGb` | template boot `disk[0].diskSizeGb` (default `30`) |
| `network.subnetId` | template `networkInterface[0].subnetwork`; without it, `network: default` |
| `network.publicIp` | template `accessConfig: [{}]` (ephemeral public address) |
| `network.securityGroupIds` | rejected: the render fails (use GCP firewall rules) |
| `sshKey` | template metadata `ssh-keys: <user>:<publicKey>` |
| `userData` | template metadata `startup-script` |
| `spot` | template `scheduling`: `provisioningModel: SPOT`, `preemptible: true`, `automaticRestart: false`, `instanceTerminationAction: STOP` |
| `deletionPolicy` | `Orphan` sets `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | template `labels` |
| `instances[].zone` | that instance's `zone` (wins over `zone`) |
| `instances[].userData` | that instance's full `metadata` (`startup-script` plus `ssh-keys` — an instance-level map replaces the template's wholesale) |
| `instances[].tags` | that instance's `labels`, merged over `tags` |

Ignored: `storageClass`, `resourceGroup`.

Status: `provider: gcp`, `templateName` (XR name), and once observed
`templateId` (selfLink) and the console `cloud-url`; `instances[]` with `name`,
`ready` (instance id observed), `id`, `privateIp` (first NIC `networkIp`),
`publicIp` (first access config `natIp`). `ready` is true once the template
and every instance are observed.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR (`region: us-central1`, one instance):

```bash
kcl run packages/cloud/instancetemplate/gcp/main.k
```

Pass a real XR the way `function-kcl` does, as `params.oxr` (and observed
resources as `params.ocds`):

```bash
kcl run packages/cloud/instancetemplate/gcp/main.k \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/instancetemplate/xrd/examples/instancetemplate-gcp.yaml), \"ocds\": {}}"
```

`pnpm exec nx run instancetemplate-gcp:render` runs `crossplane render` against
`../xrd/examples/instancetemplate-gcp.yaml` (needs the Crossplane CLI and docker).
On a cluster: `just install-module instancetemplate` installs the XRD and every
backend Composition.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `tpl.k` | `render`, `status` and the mapping helpers |
| `tpl_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `instancetemplate-gcp` |

## Development

```bash
pnpm exec nx run instancetemplate-gcp:test     # kcl test
pnpm exec nx run instancetemplate-gcp:lint     # kcl lint
pnpm exec nx run instancetemplate-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
