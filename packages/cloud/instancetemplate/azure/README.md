# instancetemplate-azure

Azure backend for the `InstanceTemplate` XR (`cloud.example.org/v1alpha1`).
Typed against the `azure-compute` and `azure-network` schema packages.
The Composition `instancetemplate-azure` runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/instancetemplate-azure`, followed by
`function-auto-ready`.

Azure has no launch-template object for standalone VMs, so this backend's
template is **logical**: the XR is the template, nothing template-shaped is
composed in Azure, and every `spec.instances` entry is rendered from the
template fields into the same resources `vm-azure` composes for one machine.
Changing a template field updates every instance in place, as far as the
provider allows.

Several machines share one XR, so each `NetworkInterface` / `PublicIP` carries
a `cloud.example.org/instance: <template>-<name>` label and the VM / NIC
selectors match on it next to `matchControllerRef` — a controller-ref match
alone would bind a VM to every NIC of the XR.

## Composed resources (per `spec.instances` entry)

| resource | when | notes |
| --- | --- | --- |
| `LinuxVirtualMachine` (`compute.azure.m.upbound.io`) | always | resource name `vm-<name>`; external-name `<template>-<name>` |
| `NetworkInterface` (`network.azure.m.upbound.io`) | always | `nic-<name>`; external-name `<template>-<name>-nic` |
| `PublicIP` (`network.azure.m.upbound.io`) | `network.publicIp` | `public-ip-<name>`; external-name `<template>-<name>-pip`, `Static` |
| `Secret` (`v1`) | `userData` or `instances[].userData` | `custom-data-<name>`; `<template>-<name>-custom-data`, double-base64 `customData` |

No instances, no resources.

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `location`; required |
| `resourceGroup` | `resourceGroupName`; required |
| `machineType` / `size` | `size`; `machineType` wins, else `small` `Standard_B2s`, `medium` `Standard_D2s_v5`, `large` `Standard_D4s_v5`, `xlarge` `Standard_D8s_v5` (default `small`) |
| `imageId` / `image` | `sourceImageId`, else the marketplace `sourceImageReference` for `ubuntu-24-04` (default), `ubuntu-22-04` or `debian-12` |
| `diskGb` | `osDisk.diskSizeGb` (default `30`) |
| `network.subnetId` | NIC `ipConfiguration[0].subnetId`; required |
| `network.publicIp` | a `PublicIP` per instance |
| `network.securityGroupIds` | rejected: the render fails (attach an NSG to the subnet) |
| `sshKey` | `adminUsername` + `adminSshKey`; required |
| `userData` | `customDataSecretRef` → per-instance Secret |
| `spot` | `priority: Spot`, `evictionPolicy: Deallocate` |
| `deletionPolicy` | `Orphan` sets `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | VM `tags` |
| `instances[].userData` | that instance's customData (wins over `userData`) |
| `instances[].tags` | merged over `tags` on that VM |

Ignored: `zone`, `storageClass`, `instances[].zone`.

Status: `provider: azure`; no `templateName` / `templateId` / `cloud-url` (no
cloud-side template); `instances[]` with `name`, `ready` (VM id observed), `id`,
`privateIp`, `publicIp`. `ready` is true once every instance is observed.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR (one instance):

```bash
kcl run packages/cloud/instancetemplate/azure/main.k
```

Pass a real XR the way `function-kcl` does, as `params.oxr` (and observed
resources as `params.ocds`):

```bash
kcl run packages/cloud/instancetemplate/azure/main.k \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/instancetemplate/xrd/examples/instancetemplate-azure.yaml), \"ocds\": {}}"
```

`pnpm exec nx run instancetemplate-azure:render` runs `crossplane render` against
`../xrd/examples/instancetemplate-azure.yaml` (needs the Crossplane CLI and docker).
On a cluster: `just install-module instancetemplate` installs the XRD and every
backend Composition.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `tpl.k` | `render`, `status` and the mapping helpers |
| `tpl_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `instancetemplate-azure` |

## Development

```bash
pnpm exec nx run instancetemplate-azure:test     # kcl test
pnpm exec nx run instancetemplate-azure:lint     # kcl lint
pnpm exec nx run instancetemplate-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
