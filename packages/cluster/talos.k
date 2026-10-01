# Talos Cluster Configuration Schema
# talosctl has no cluster config file: topology is CLI flags and node settings
# are machine-config patches. This renders the complete talosctl argv, each
# patch inlined as one single-line JSON document, so one render drives one
# talosctl call:
#
#   args=(); while IFS= read -r a; do args+=("$a"); done < <(
#       kcl run . -D runner=talos --format json | jq -r '.args[]')
#   talosctl "${args[@]}"
import json

schema TalosCluster:
    """
    Talos cluster configuration, rendered as talosctl arguments

    Args:
        name: Cluster name; the kube context is admin@<name> (default: "talos")
        provisioner: How the cluster is generated (default: "docker")
            docker → `talosctl cluster create docker`, nodes are containers
            qemu   → `talosctl cluster create qemu`, nodes are VMs
            metal  → `talosctl gen config <name> <endpoint>`, machine configs
                     (controlplane.yaml, worker.yaml, talosconfig) for real
                     machines; append `-o <dir>` to choose where they land
        endpoint: Kubernetes API URL, e.g. https://10.0.0.10:6443 (metal only)
        control_planes: Number of control-plane nodes (default: 1; qemu only
            may raise it)
        workers: Number of worker nodes (default: 0). With none, the control
            planes are made schedulable, as kind and k3s do.
        ingress: Label control planes ingress-ready=true and, on docker, publish
            host ports 80/443 on the first one (default: false). Talos ships no
            ingress controller: pin one there with hostPort 80/443, as on kind.
        host_proc: docker only: bind-mount the host's /proc at /procHost on
            every node, for host-wide eBPF agents such as Tetragon (`--set
            tetragon.hostProcPath=/procHost`) (default: false). A docker node is
            a container with its own pid namespace, so its /proc misses the
            PIDs eBPF reports; qemu and metal nodes are real machines whose
            /proc already is the host's, so the flag is rejected there.
        oidc_bucket: GCS bucket serving this cluster's OIDC discovery documents
        oidc_id: Path prefix inside oidc_bucket, one per cluster
    """
    _name: str = option("name", default="talos")
    _provisioner: "docker" | "qemu" | "metal" = option("provisioner", default="docker")
    _endpoint: str = option("endpoint", default="")
    _control_planes: int = option("control_planes", default=1)
    _workers: int = option("workers", default=0)
    _db_workers: int = option("db_workers", default=0)
    _ingress: bool = option("ingress", default=False)
    _host_proc: bool = option("host_proc", default=False)
    _oidc_bucket: str = option("oidc_bucket", default="")
    _oidc_id: str = option("oidc_id", default="")

    _issuer: str = "https://storage.googleapis.com/${_oidc_bucket}/${_oidc_id}" if _oidc_bucket != "" else ""

    # Talos >= 1.14 splits the machine config into typed documents; each patch
    # below merges into the control-plane document of the same kind. The legacy
    # v1alpha1 keys (machine.nodeLabels, cluster.allowSchedulingOnControlPlanes,
    # cluster.apiServer) are rejected once those documents exist.
    _node_patch: {str:} = {
        apiVersion = "v1alpha1"
        kind = "KubeNodeConfig"
        if _ingress:
            labels = {"ingress-ready" = "true"}
        # drops the node-role.kubernetes.io/control-plane:NoSchedule taint
        if _workers == 0:
            taints = {"$patch" = "delete"}
    }
    _issuer_patch: {str:} = {
        apiVersion = "v1alpha1"
        kind = "KubeServiceAccountConfig"
        issuer = {issuerURL = _issuer}
    }
    _control_plane_patches: [{str:}] = ([_node_patch] if _ingress or _workers == 0 else []) + ([_issuer_patch] if _issuer != "" else [])

    # `gen config` and `cluster create` spell the control-plane patch flag differently.
    _patch_flag: str = "--config-patch-control-plane" if _provisioner == "metal" else "--config-patch-controlplanes"
    _patch_args: [str] = [a for p in _control_plane_patches for a in [_patch_flag, json.encode(p)]]

    name: str = _name
    provisioner: str = _provisioner
    args: [str] = (["gen", "config", _name, _endpoint] if _provisioner == "metal" else ["cluster", "create", _provisioner, "--name", _name] + (["--controlplanes", str(_control_planes)] if _provisioner == "qemu" else []) + ["--workers", str(_workers)] + (["--exposed-ports", "80:80/tcp,443:443/tcp"] if _ingress and _provisioner == "docker" else []) + (["--mount", "type=bind,source=/proc,target=/procHost"] if _host_proc else [])) + _patch_args

    check:
        _control_planes >= 1, "control_planes must be at least 1"
        _workers >= 0, "workers must not be negative"
        _provisioner != "docker" or _control_planes == 1, "talosctl's docker provisioner runs one control plane; use provisioner=qemu for more"
        # One patch reaches every worker, so a dedicated subset cannot be expressed.
        _db_workers == 0, "db_workers is not supported for talos: talosctl patches all workers alike"
        _provisioner != "metal" or _endpoint != "", "provisioner=metal needs endpoint (the Kubernetes API URL)"
        (_oidc_bucket == "") == (_oidc_id == ""), "oidc_bucket and oidc_id must be set together"
        _provisioner == "docker" or not _host_proc, "host_proc is docker-only: ${_provisioner} nodes are real machines, their /proc already is the host's"
