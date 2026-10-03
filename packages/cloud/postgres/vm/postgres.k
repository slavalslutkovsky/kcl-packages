# postgres (vm) — Crossplane Composition logic (function-kcl module).
# The self-managed backend: PostgreSQL installed on a plain machine in AWS, GCP
# or Azure. Nothing here knows what an EC2 Instance or a Compute Instance looks
# like — it composes ONE child VirtualMachine XR (cloud.example.org), selects
# its backend from spec.vm.provider, and hands it a boot script that installs
# and configures PostgreSQL. The VirtualMachine capability owns the cloud
# mapping, exactly as the AppStack leaves each child its own.
#
# The one input a self-managed server cannot invent is the password: there is
# no operator or cloud API to generate and publish one. spec.passwordSecret is
# therefore required, and the Secret is fetched through Crossplane's
# required-resources mechanism (see request/password_hash). Only its md5 hash —
# the form PostgreSQL itself stores — is written into the boot script, so the
# plaintext never reaches cloud instance metadata.
import base64
import crypto
import regex

_child_api = "cloud.example.org/v1alpha1"

port = 5432

# Key the password Secret is filed under in requiredResources. Arbitrary, but
# both sides of the round trip must agree.
password_requirement = "password-secret"

# memoryGb -> the smallest abstract VirtualMachine size that holds it. The
# small shape is 4 GiB on every cloud (t3.medium / e2-medium / Standard_B2s).
size_for = lambda memory -> str {
    "small" if memory <= 4 else "medium" if memory <= 8 else "large" if memory <= 16 else "xlarge"
}

# The script is a shell script, not #cloud-config: GCP delivers the
# VirtualMachine's userData as a startup-script, which only runs scripts, and
# cloud-init on AWS and Azure runs a #! payload as-is. GCP runs it on EVERY
# boot, so every step is idempotent.
#
# Identifiers are validated before they get here (see render), and the
# heredocs are quoted, so nothing in the spec is ever expanded by the shell.
_ident = "^[A-Za-z_][A-Za-z0-9_]*$"
_param_key = "^[a-z_][a-z0-9_.]*$"

boot_script = lambda spec, pw_hash: str -> str {
    _v = spec?.engineVersion or "16"
    _db = spec?.database or "app"
    _user = spec?.username or "app"
    _cidr = spec?.vm?.allowedCidr or "10.0.0.0/8"
    _conf = "/etc/postgresql/${_v}/main"
    _hba = "host all all ${_cidr} md5"
    _params = spec?.parameters or {}
    # Single quotes are doubled — the postgresql.conf string escape.
    _quoted = {k = v.replace("'", "''") for k, v in _params}
    _param_lines = "".join(["${k} = '${_quoted[k]}'\n" for k in sorted(_quoted)])
    """\
#!/bin/bash
# Rendered by the postgres-vm Composition. Idempotent: GCP re-runs it on every boot.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s postgresql-${_v} >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl postgresql-common
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
  apt-get install -y postgresql-${_v}
fi
cat > ${_conf}/conf.d/90-platform.conf <<'PGCONF'
listen_addresses = '*'
port = ${port}
${_param_lines}PGCONF
grep -qxF '${_hba}' ${_conf}/pg_hba.conf || echo '${_hba}' >> ${_conf}/pg_hba.conf
systemctl enable postgresql
systemctl restart postgresql
runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'CREATE ROLE "${_user}" LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${_user}')\\gexec
ALTER ROLE "${_user}" LOGIN PASSWORD '${pw_hash}';
SELECT 'CREATE DATABASE "${_db}" OWNER "${_user}"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${_db}')\\gexec
SQL
"""
}

# The item that makes Crossplane fetch the password Secret. Emitted on EVERY
# call: Crossplane re-runs the step until the requirements stop changing, so
# dropping it once answered would flip them back and forth.
request = lambda oxr -> any {
    _sec = oxr.spec?.passwordSecret
    assert _sec?.name, "postgres-vm: spec.passwordSecret is required — a self-managed server has no operator to generate a password. Point it at a Secret in this namespace holding the password for spec.username."
    {
        apiVersion = "meta.krm.kcl.dev/v1alpha1"
        kind = "RequiredResources"
        requirements = {
            "${password_requirement}" = {apiVersion = "v1", kind = "Secret", name = _sec.name, namespace = oxr.metadata?.namespace or "default"}
        }
    }
}

# The password in PostgreSQL's pre-hashed md5 form: "md5" + md5(password +
# username). ALTER ROLE stores a pre-hashed value as-is, whatever
# password_encryption says, and pg_hba's md5 method authenticates against it.
#
# "" while Crossplane has not answered yet (the key is absent) — that is the
# first iteration, not an error. A missing Secret or key is fatal: composing a
# server whose owner cannot log in would only defer the failure.
password_hash = lambda params, oxr -> str {
    _sec = oxr.spec.passwordSecret
    _key = _sec?.key or "password"
    _ns = oxr.metadata?.namespace or "default"
    _rr = params?.requiredResources or {}
    _hits = _rr[password_requirement] if password_requirement in _rr else Undefined
    _pending = _hits == Undefined or _hits == None
    _found = (not _pending) and len(_hits) == 1
    _data = (_hits[0]?.Resource?.data or {}) if _found else {}
    assert _pending or _found, "postgres-vm: Secret '${_sec.name}' (spec.passwordSecret) does not exist in namespace '${_ns}'"
    assert _pending or _key in _data, "postgres-vm: Secret '${_sec.name}' has no key '${_key}' (spec.passwordSecret.key)"
    "" if _pending else "md5" + crypto.md5(base64.decode(_data[_key]) + (oxr.spec?.username or "app"))
}

render = lambda oxr, pw_hash: str -> [any] {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _vm = _spec?.vm or {}
    _memory = _spec?.memoryGb or 2
    _storage = _spec?.storageGb or 20
    _params = _spec?.parameters or {}
    _wi = _spec?.workloadIdentity

    # Rejected shapes: a single machine cannot honour them, and silently
    # dropping them would leave the claim saying something the server is not.
    assert _vm?.provider, "postgres-vm: spec.vm.provider (aws | gcp | azure) is required — it picks the cloud the VirtualMachine resolves to"
    assert not (_spec?.highAvailability or False), "postgres-vm: spec.highAvailability is not expressible — one machine has no standby. Use the cnpg backend or a managed one."
    assert (_spec?.replicas or 0) == 0, "postgres-vm: spec.replicas is not expressible — one machine has no streaming standbys. Use the cnpg backend."
    assert not _spec?.backup, "postgres-vm: spec.backup is CNPG-only — the vm backend runs no barman agent"
    assert not _wi or _wi?.enabled == False, "postgres-vm: spec.workloadIdentity is not expressible — a self-managed server has no cloud IAM integration"
    assert not _spec?.encryptionKmsKeyId, "postgres-vm: spec.encryptionKmsKeyId is not expressible — the VirtualMachine root disk takes no customer-managed key"
    assert _spec?.instanceClass or _memory <= 32, "postgres-vm: memoryGb ${_memory} exceeds the largest abstract size (xlarge, 32 GiB) — set spec.instanceClass to a native machine type"
    assert regex.match(_spec?.database or "app", _ident), "postgres-vm: spec.database must be a plain identifier (${_ident}) — it is written into the boot script"
    assert regex.match(_spec?.username or "app", _ident), "postgres-vm: spec.username must be a plain identifier (${_ident}) — it is written into the boot script"
    assert regex.match(_vm?.allowedCidr or "10.0.0.0/8", "^[0-9A-Fa-f:.]+/[0-9]+$"), "postgres-vm: spec.vm.allowedCidr must be a CIDR"
    assert all k in _params {
        regex.match(k, _param_key) and "\n" not in _params[k]
    }, "postgres-vm: spec.parameters keys must be PostgreSQL setting names (${_param_key}) and values single-line"

    [{
        apiVersion = _child_api
        kind = "VirtualMachine"
        metadata = {
            name = "${_name}-vm"
            annotations = {"krm.kcl.dev/composition-resource-name" = "vm"}
        }
        spec = {
            region = _spec.region
            size = size_for(_memory)
            if _spec?.instanceClass:
                machineType = _spec.instanceClass
            image = _vm?.image or "ubuntu-24-04"
            if _vm?.imageId:
                imageId = _vm.imageId
            # The data directory lives on the root disk: storageGb for the
            # cluster plus headroom for the OS and packages.
            diskGb = _storage + 10
            network = {
                if _vm?.subnetId:
                    subnetId = _vm.subnetId
                if _spec?.network?.securityGroupIds:
                    securityGroupIds = _spec.network.securityGroupIds
                publicIp = _spec?.publicAccess or False
            }
            if _vm?.sshKey:
                sshKey = _vm.sshKey
            userData = boot_script(_spec, pw_hash)
            if _spec?.resourceGroup:
                resourceGroup = _spec.resourceGroup
            deletionPolicy = _spec?.deletionPolicy or "Delete"
            if _spec?.tags:
                tags = _spec.tags
            crossplane.compositionSelector.matchLabels.provider = _vm.provider
        }
    }]
}

# Build the desired composite carrying observed status back to the XR.
# The machine being up is the readiness signal: the boot script finishes a few
# minutes later, and nothing here can observe it.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _vm = (ocds["vm"]?.Resource?.status) if ("vm" in ocds) else Undefined
    _db = _spec?.database or "app"
    _public = _spec?.publicAccess or False

    # A public endpoint only when one was asked for; clients inside the
    # network always have the private address.
    _host = (_vm?.publicIp if _public else Undefined) or _vm?.privateIp or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "PostgresInstance"
        metadata.name = _name
        status = {
            provider = "vm"
            ready = (_vm?.ready or False) and _host != ""
            database = _db
            username = _spec?.username or "app"
            version = _spec?.engineVersion or "16"
            port = port
            authSecret = _spec?.passwordSecret?.name
            authSecretKey = _spec?.passwordSecret?.key or "password"
            if _host:
                host = _host
                endpoint = "${_host}:${port}"
                readEndpoint = "${_host}:${port}"
                url = "postgresql://${_host}:${port}/${_db}"
            if _vm?.id:
                id = _vm.id
            if _vm?["cloud-url"]:
                "cloud-url" = _vm["cloud-url"]
        }
    }
}
