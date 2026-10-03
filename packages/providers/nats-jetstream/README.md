# nats-jetstream

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed nats-jetstream`.

Source: tmp/nack-crds.yml

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
nats-jetstream = { path = "<relative path>/packages/providers/nats-jetstream" }
```

Then import a model:

```python
import nats_jetstream.models.v1beta1.jetstream_nats_io_v1beta1_consumer as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Consumer | `nats_jetstream.models.v1beta1.jetstream_nats_io_v1beta1_consumer` |
| Stream | `nats_jetstream.models.v1beta1.jetstream_nats_io_v1beta1_stream` |
| StreamTemplate | `nats_jetstream.models.v1beta1.jetstream_nats_io_v1beta1_stream_template` |

### v1beta2

| kind | import |
| --- | --- |
| Account | `nats_jetstream.models.v1beta2.jetstream_nats_io_v1beta2_account` |
| Consumer | `nats_jetstream.models.v1beta2.jetstream_nats_io_v1beta2_consumer` |
| KeyValue | `nats_jetstream.models.v1beta2.jetstream_nats_io_v1beta2_key_value` |
| ObjectStore | `nats_jetstream.models.v1beta2.jetstream_nats_io_v1beta2_object_store` |
| Stream | `nats_jetstream.models.v1beta2.jetstream_nats_io_v1beta2_stream` |
