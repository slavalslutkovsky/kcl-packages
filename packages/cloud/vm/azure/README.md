# vm-azure

Azure backend for the `VirtualMachine` XR (`cloud.example.org/v1alpha1`).
Typed against the `azure-compute` and `azure-network` schema packages
(`../../../providers/azure-compute`, `../../../providers/azure-network`), it
maps the portable machine onto a `LinuxVirtualMachine` plus a composed
`NetworkInterface`, a `PublicIP` when `network.publicIp` is set, and a
`Secret` carrying `customData` when `userData` is set. The
Composition `vm-azure` runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/vm-azure`, followed by `function-auto-ready`.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `LinuxVirtualMachine` (`compute.azure.m.upbound.io`) | always | external-name = XR name; NIC bound via `networkInterfaceIdsSelector.matchControllerRef`; OS disk `ReadWrite` / `Standard_LRS` |
| `NetworkInterface` (`network.azure.m.upbound.io`) | always | external-name `<name>-nic`; ip configuration `primary`, dynamic private IP on `network.subnetId` |
| `PublicIP` (`network.azure.m.upbound.io`) | `network.publicIp: true` | external-name `<name>-pip`; `allocationMethod: Static`; bound to the NIC by controller reference |
| `Secret` (`v1`) | `userData` set | `<name>-custom-data`, key `customData`; declared ready (no Ready condition) |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `location` on every MR; required |
| `resourceGroup` | `resourceGroupName` on every MR; required |
| `sshKey` | `adminUsername` and `adminSshKey`; required (Azure Linux VMs disable password logins) |
| `network.subnetId` | NIC `ipConfiguration.subnetId`; required (full subnet resource ID) |
| `network.securityGroupIds` | rejected: the render fails (attach an NSG to the subnet instead) |
| `network.publicIp` | composes the `PublicIP` |
| `machineType` / `size` | `size`; `machineType` wins, else `small` `Standard_B2s`, `medium` `Standard_D2s_v5`, `large` `Standard_D4s_v5`, `xlarge` `Standard_D8s_v5` (default `small`) |
| `imageId` / `image` | `sourceImageId` when `imageId` is set, else `sourceImageReference` for `ubuntu-24-04` (default), `ubuntu-22-04` or `debian-12` |
| `diskGb` | `osDisk.diskSizeGb` (default `30`) |
| `userData` | `customDataSecretRef` → the composed `Secret`, whose value is the base64 `customData` field. customData is what cloud-init runs at boot; Azure's own `userData` field is only readable from IMDS and never executed. Changing it replaces the VM |
| `spot` | `priority: Spot`, `evictionPolicy: Deallocate` |
| `deletionPolicy` | `Orphan` sets `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | `forProvider.tags` on the VM |

Ignored: `zone`, `storageClass`.

Status written back from the observed VM: `provider: azure`, `ready` (id
observed), `name` (XR name), and when observed `privateIp`
(`privateIpAddress`), `publicIp` (`publicIpAddress`), `id` and the portal
`cloud-url`.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`westeurope`, `example-rg`, an example ssh key and subnet ID):

```bash
kcl run packages/cloud/vm/azure
```

Pass a real XR the way `function-kcl` does, as `params.oxr`:

```bash
kcl run packages/cloud/vm/azure \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/vm/xrd/examples/vm-azure.yaml)}"
```

`pnpm exec nx run vm-azure:render` runs `crossplane render` against
`../xrd/examples/vm-azure.yaml` (needs the Crossplane CLI and docker). On a
cluster: `just install-module vm` installs the XRD and every backend
Composition; `just e2e vm` runs the full kind e2e.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `vm.k` | `render`, `status`, `machine_for`, `image_ref` |
| `vm_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `vm-azure` |

## Development

```bash
pnpm exec nx run vm-azure:test     # kcl test
pnpm exec nx run vm-azure:lint     # kcl lint
pnpm exec nx run vm-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
