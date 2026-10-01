# postgres-vm

Self-managed backend for the `PostgresInstance` XR (`cloud.example.org/v1alpha1`):
PostgreSQL installed on a plain machine in AWS, GCP or Azure. It composes no
managed resources of its own — one child `VirtualMachine` XR, whose backend
(`vm-aws`, `vm-gcp`, `vm-azure`) is selected from `spec.vm.provider`, booted
with a script that installs and configures PostgreSQL. The Composition
`postgres-vm` (label `provider: vm`) runs it through `function-kcl`
(`target: Default`) from `oci://docker.io/yurikrupnik/postgres-vm`, followed by
`function-auto-ready`.

## Composed resources

| resource | composition-resource-name | notes |
| --- | --- | --- |
| `VirtualMachine` (`cloud.example.org/v1alpha1`) | `vm` | named `<name>-vm`; `compositionSelector.matchLabels.provider = spec.vm.provider`; `userData` = the boot script |

## Password

A self-managed server has no operator or cloud API to generate a password, so
`spec.passwordSecret` is **required**. The module emits a
`meta.krm.kcl.dev/v1alpha1 RequiredResources` item naming that Secret in the
XR's namespace; Crossplane fetches it and re-runs the step. The first iteration
renders only the request. A missing Secret or key is a fatal render.

Only `md5` + md5(password + username) — the pre-hashed form PostgreSQL stores
as-is — is written into the boot script, so the plaintext never reaches cloud
instance metadata. `pg_hba.conf` admits `spec.vm.allowedCidr` with the `md5`
method. PostgreSQL 18 deprecates md5 password storage (it still works, with a
warning); rotate onto SCRAM by hand if that matters for the deployment.

## Boot script

A `#!/bin/bash` script, not `#cloud-config`: GCP delivers `userData` as a
`startup-script` (scripts only, run on **every** boot), cloud-init on AWS and
Azure runs a `#!` payload as-is. Every step is idempotent:

1. install `postgresql-<engineVersion>` from the PGDG apt repository unless the package is present,
2. write `conf.d/90-platform.conf` (`listen_addresses = '*'`, `port = 5432`, `spec.parameters`),
3. append the `pg_hba.conf` line once,
4. `CREATE ROLE` / `CREATE DATABASE` only when missing (`\gexec`), `ALTER ROLE … PASSWORD` every run.

## Spec fields read

| field | maps to |
| --- | --- |
| `region` | VM `region` |
| `vm.provider` | VM backend (`aws` \| `gcp` \| `azure`); required |
| `vm.image` / `vm.imageId` | VM `image` / `imageId` (`imageId` required on aws) |
| `vm.subnetId` | VM `network.subnetId` (required on azure) |
| `vm.sshKey` | VM `sshKey` (required on azure) |
| `vm.allowedCidr` | `pg_hba.conf` client range (default `10.0.0.0/8`) |
| `memoryGb` | VM `size`: ≤4 `small`, ≤8 `medium`, ≤16 `large`, ≤32 `xlarge` |
| `instanceClass` | VM `machineType` (wins over `memoryGb`; required above 32 GiB) |
| `storageGb` | VM `diskGb` = `storageGb + 10` (the data directory is on the root disk) |
| `engineVersion` | PGDG package `postgresql-<v>` |
| `database` / `username` | created by the boot script; must be plain identifiers |
| `passwordSecret` | required — see above |
| `parameters` | `conf.d/90-platform.conf` |
| `publicAccess` | VM `network.publicIp`; status `host` is the public address |
| `network.securityGroupIds` | VM `network.securityGroupIds` (aws) |
| `resourceGroup` | VM `resourceGroup` (required on azure) |
| `deletionPolicy`, `tags` | forwarded to the VM |

Rejected (the render fails): `highAvailability`, `replicas > 0`, `backup`,
an enabled `workloadIdentity`, `encryptionKmsKeyId`. Ignored:
`snapshotRetentionDays`, `maintenanceWindow`, `network.id`,
`network.subnetGroupName`, Azure private DNS fields.

Status: `provider: vm`, `host` (private IP, or public IP with
`publicAccess`), `port` 5432, `endpoint` = `readEndpoint`, `url`, `database`,
`username`, `version` (= `engineVersion`), `authSecret` / `authSecretKey` (the
caller's Secret), `id`, `cloud-url`. `ready` means the machine is up with an
address; the boot script finishes a few minutes later and is not observed.

## Usage

```bash
kcl run packages/cloud/postgres/vm      # built-in example, Secret pre-fetched
```

Requires the `VirtualMachine` XRD and its cloud Compositions
(`just install-module vm`).

## Development

```bash
pnpm exec nx run postgres-vm:test
pnpm exec nx run postgres-vm:lint
pnpm exec nx run postgres-vm:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
