# azure-compute

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-compute`.

Source: ghcr.io/crossplane-contrib/provider-azure-compute:v2.6.0 (scope=namespaced; service=compute)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-compute = { path = "<relative path>/packages/providers/azure-compute" }
```

Then import a model:

```python
import azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_availability_set as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| AvailabilitySet | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_availability_set` |
| CapacityReservation | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_capacity_reservation` |
| CapacityReservationGroup | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_capacity_reservation_group` |
| DedicatedHost | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_dedicated_host` |
| DiskAccess | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_disk_access` |
| DiskEncryptionSet | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_disk_encryption_set` |
| GalleryApplication | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_gallery_application` |
| GalleryApplicationVersion | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_gallery_application_version` |
| Image | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_image` |
| LinuxVirtualMachine | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_linux_virtual_machine` |
| LinuxVirtualMachineScaleSet | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_linux_virtual_machine_scale_set` |
| ManagedDisk | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_managed_disk` |
| ManagedDiskSASToken | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_managed_disk_s_a_s_token` |
| OrchestratedVirtualMachineScaleSet | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_orchestrated_virtual_machine_scale_set` |
| ProximityPlacementGroup | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_proximity_placement_group` |
| SharedImage | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_shared_image` |
| SharedImageGallery | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_shared_image_gallery` |
| Snapshot | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_snapshot` |
| SSHPublicKey | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_ssh_public_key` |
| VirtualMachineDataDiskAttachment | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_virtual_machine_data_disk_attachment` |
| VirtualMachineExtension | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_virtual_machine_extension` |
| VirtualMachineRunCommand | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_virtual_machine_run_command` |
| VirtualMachineScaleSetStandbyPool | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_virtual_machine_scale_set_standby_pool` |
| WindowsVirtualMachine | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_windows_virtual_machine` |
| WindowsVirtualMachineScaleSet | `azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_windows_virtual_machine_scale_set` |
