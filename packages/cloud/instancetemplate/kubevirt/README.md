# instancetemplate-kubevirt

Self-hosted backend for the `InstanceTemplate` XR (`cloud.example.org/v1alpha1`).
Typed against the `kubevirt` schema package (`../../../providers/kubevirt`).
KubeVirt's native template objects are the instancetype API: the template's
shape lives in a namespaced `VirtualMachineInstancetype` and its device
defaults in a `VirtualMachinePreference`, both named after the XR, and every
`spec.instances` entry is a `VirtualMachine` that references them. The
Composition `instancetemplate-kubevirt` runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/instancetemplate-kubevirt`, followed by
`function-auto-ready`.

Needs the KubeVirt and CDI operators (install commands in
[../../vm/xrd/providers.yaml](../../vm/xrd/providers.yaml)); no Crossplane
provider is involved. KubeVirt's admission webhook rejects a VM whose
instancetype or preference does not exist yet, so machines are composed from
the reconcile after both are observed.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `VirtualMachineInstancetype` (`instancetype.kubevirt.io/v1beta1`) | no `machineType` | `cpu.guest` / `memory.guest` from `size` |
| `VirtualMachinePreference` (`instancetype.kubevirt.io/v1beta1`) | always | `preferredDiskBus: virtio`, `preferredInterfaceModel: virtio` |
| `Secret` (`v1`) | `sshKey` set | `<template>-ssh`, shared by every machine's `accessCredentials` |
| `VirtualMachine` (`kubevirt.io/v1`) | per `spec.instances` entry, once the template objects are observed | `<template>-<name>`; `runStrategy: Always`; root disk imported by CDI into `<template>-<name>-root` |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `size` | instancetype `small` 2 vCPU/4Gi, `medium` 2/8Gi, `large` 4/16Gi, `xlarge` 8/32Gi (default `small`) |
| `machineType` | every VM references the `VirtualMachineClusterInstancetype` of that name; no namespaced instancetype is composed |
| `imageId` / `image` | each root DataVolume's `source.registry.url`; `imageId` verbatim, else `quay.io/containerdisks` ubuntu 24.04 (default) / 22.04 / debian 12 |
| `diskGb` | each root PVC size (default `30`) |
| `storageClass` | each root PVC `storageClassName` |
| `sshKey.publicKey` | the shared Secret, noCloud propagation |
| `userData` | each VM's `cloudInitNoCloud.userData` (`#cloud-config` stub when unset) |
| `tags` | VM labels |
| `instances[].userData` | that VM's cloud-init userData |
| `instances[].tags` | merged over `tags` on that VM |

Ignored: `region` (free-form site label), `zone`, `spot`, `network`,
`resourceGroup`, `deletionPolicy`, `instances[].zone`.

Status: `provider: kubevirt`, `templateName` (XR name), `templateId`
(`<namespace>/<name>`), `cloud-url` (the instancetype, or the preference when
`machineType` delegates the shape); `instances[]` with `name`, `ready`
(`printableStatus: Running`) and `id` (`<namespace>/<machine>`). No IPs: the
guest address lives on the VirtualMachineInstance, which is not composed.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR with the template objects observed, so the machine is rendered too:

```bash
kcl run packages/cloud/instancetemplate/kubevirt/main.k
```

Pass a real XR the way `function-kcl` does, as `params.oxr` (and observed
resources as `params.ocds`):

```bash
kcl run packages/cloud/instancetemplate/kubevirt/main.k \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/instancetemplate/xrd/examples/instancetemplate-kubevirt.yaml), \"ocds\": {}}"
```

`pnpm exec nx run instancetemplate-kubevirt:render` runs `crossplane render` against
`../xrd/examples/instancetemplate-kubevirt.yaml` (needs the Crossplane CLI and docker).
On a cluster: `just install-module instancetemplate` installs the XRD and every
backend Composition.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `tpl.k` | `render`, `status` and the mapping helpers |
| `tpl_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `instancetemplate-kubevirt` |

## Development

```bash
pnpm exec nx run instancetemplate-kubevirt:test     # kcl test
pnpm exec nx run instancetemplate-kubevirt:lint     # kcl lint
pnpm exec nx run instancetemplate-kubevirt:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
