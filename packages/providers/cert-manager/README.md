# cert-manager

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed cert-manager`.

Source: cert-manager/cert-manager@v1.21.1 (deploy/crds); service=cert-manager; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
cert-manager = { path = "<relative path>/packages/providers/cert-manager" }
```

Then import a model:

```python
import cert_manager.models.v1.cert_manager_io_v1_certificate as model
```

## Kinds

### v1

| kind | import |
| --- | --- |
| Certificate | `cert_manager.models.v1.cert_manager_io_v1_certificate` |
| CertificateRequest | `cert_manager.models.v1.cert_manager_io_v1_certificate_request` |
| ClusterIssuer | `cert_manager.models.v1.cert_manager_io_v1_cluster_issuer` |
| Issuer | `cert_manager.models.v1.cert_manager_io_v1_issuer` |
