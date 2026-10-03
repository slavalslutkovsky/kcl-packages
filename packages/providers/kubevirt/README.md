# kubevirt

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed kubevirt`.

Source: datreeio/CRDs-catalog@ad3b08c5045129d7bb1eeffd8e61719b2c8dd1e2 (kubevirt.io/virtualmachine_v1.json:VirtualMachine,cdi.kubevirt.io/datavolume_v1beta1.json:DataVolume)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
kubevirt = { path = "<relative path>/packages/providers/kubevirt" }
```

Then import a model:

```python
import kubevirt.models.v1.kubevirt_io_v1_virtual_machine as model
```

## Kinds

### v1

| kind | import |
| --- | --- |
| VirtualMachine | `kubevirt.models.v1.kubevirt_io_v1_virtual_machine` |

### v1beta1

| kind | import |
| --- | --- |
| DataVolume | `kubevirt.models.v1beta1.cdi_kubevirt_io_v1beta1_data_volume` |
