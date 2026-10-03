# vm-kubevirt

Self-hosted backend for the `VirtualMachine` XR (`cloud.example.org/v1alpha1`):
no cloud account, no VPC. Typed against the `kubevirt` schema package
(`../../../providers/kubevirt`), it renders a namespaced `kubevirt.io/v1`
`VirtualMachine` directly. Crossplane v2 composes arbitrary namespaced
resources, so there is no provider MR, no `providerConfigRef` and no
`managementPolicies`. The Composition `vm-kubevirt` runs it through
`function-kcl` from `oci://docker.io/yurikrupnik/vm-kubevirt`, followed by
`function-auto-ready`.

No Crossplane provider serves this backend. The cluster needs the KubeVirt and
CDI operators; the install commands are in the header of
[../xrd/providers.yaml](../xrd/providers.yaml). CDI is required: the root disk
is a `dataVolumeTemplates` import.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `VirtualMachine` (`kubevirt.io`) | always | Named after the XR, placed in the XR's namespace; `runStrategy: Always`; root disk from a `dataVolumeTemplates` entry `<name>-root` (CDI import, survives restarts); a `cloudinit` NoCloud disk is always attached; masqueraded pod networking |
| `Secret` (core `v1`) | `sshKey` set | `<name>-ssh`, `stringData.key` = public key; wired via `accessCredentials` with `propagationMethod.noCloud` |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `size` | `domain.cpu.cores` / `domain.memory.guest`: `small` 2 / 4Gi, `medium` 2 / 8Gi, `large` 4 / 16Gi, `xlarge` 8 / 32Gi (default `small`) |
| `machineType` | `spec.instancetype` (`VirtualMachineClusterInstancetype`); suppresses the size ladder, since KubeVirt rejects both |
| `imageId` / `image` | DataVolume `source.registry.url: docker://<image>`; `imageId` verbatim, else `quay.io/containerdisks/ubuntu:24.04` (default), `ubuntu:22.04` or `debian:12` |
| `diskGb` | DataVolume storage request `<n>Gi` (default `30`) |
| `storageClass` | DataVolume `storageClassName`; unset uses the cluster default |
| `sshKey.publicKey` | the `Secret` above |
| `userData` | `cloudInitNoCloud.userData` verbatim; `#cloud-config\n` when unset |
| `tags` | `metadata.labels` on the VirtualMachine |

Ignored: `region`, `zone`, `spot`, `resourceGroup`, the whole `network`
block, `sshKey.user` (noCloud authorizes the image's default user) and
`deletionPolicy` (the VM's lifetime follows the XR). A `userData` that declares
its own `users:` or `ssh_authorized_keys:` shadows the injected key.

Status written back: `provider: kubevirt`, `ready` (`printableStatus:
Running`), and, deterministic from the XR, `name`, `id`
(`<namespace>/<name>`) and `cloud-url`
(`kubernetes://<namespace>/virtualmachine.kubevirt.io/<name>`). `privateIp`
and `publicIp` are never set: the address lives on the
VirtualMachineInstance, which is not composed.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`default/example`, `region: in-cluster`):

```bash
kcl run packages/cloud/vm/kubevirt
```

Pass a real XR the way `function-kcl` does, as `params.oxr`:

```bash
kcl run packages/cloud/vm/kubevirt \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/vm/xrd/examples/vm-kubevirt.yaml)}"
```

`pnpm exec nx run vm-kubevirt:render` runs `crossplane render` against
`../xrd/examples/vm-kubevirt.yaml` (needs the Crossplane CLI and docker). On a
cluster: `just install-module vm` installs the XRD and every backend
Composition; `just e2e vm` runs the full kind e2e.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `vm.k` | `render`, `status`, `machine_for`, `image_for`, naming helpers |
| `vm_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `vm-kubevirt` |

## Development

```bash
pnpm exec nx run vm-kubevirt:test     # kcl test
pnpm exec nx run vm-kubevirt:lint     # kcl lint
pnpm exec nx run vm-kubevirt:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
