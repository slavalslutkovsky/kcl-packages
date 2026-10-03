# Tests for Talos cluster configuration (talosctl argv)
import json
import .talos

# Every JSON patch that follows `flag` in args, keyed by the document kind it targets.
_patches_after = lambda args: [str], flag: str {
    {json.decode(args[i + 1]).kind: json.decode(args[i + 1]) for i, a in args if a == flag}
}

test_talos_default_docker = lambda {
    cluster = talos.TalosCluster {}
    assert cluster.provisioner == "docker"
    assert cluster.args[:5:] == ["cluster", "create", "docker", "--name", "talos"]
    assert "--controlplanes" not in cluster.args, "docker has no --controlplanes flag"
    assert "--exposed-ports" not in cluster.args
    patches = _patches_after(cluster.args, "--config-patch-controlplanes")
    assert patches == {
        KubeNodeConfig = {apiVersion = "v1alpha1", kind = "KubeNodeConfig", taints = {"$patch" = "delete"}}
    }, "no workers → the control plane drops its NoSchedule taint"
}

test_talos_workers_keep_control_plane_tainted = lambda {
    cluster = talos.TalosCluster {
        _workers: 2
    }
    assert cluster.args[5:7:] == ["--workers", "2"]
    assert "--config-patch-controlplanes" not in cluster.args, "nothing to patch with workers present"
}

test_talos_ingress_docker = lambda {
    cluster = talos.TalosCluster {
        _workers: 2
        _ingress: True
    }
    _i = [i for i, a in cluster.args if a == "--exposed-ports"][0]
    assert cluster.args[_i + 1] == "80:80/tcp,443:443/tcp"
    patches = _patches_after(cluster.args, "--config-patch-controlplanes")
    assert patches.KubeNodeConfig.labels["ingress-ready"] == "true"
    assert "taints" not in patches.KubeNodeConfig, "workers exist, so the control plane stays tainted"
    assert "KubeServiceAccountConfig" not in patches
}

test_talos_qemu_control_planes = lambda {
    cluster = talos.TalosCluster {
        _provisioner: "qemu"
        _control_planes: 3
        _workers: 2
        _ingress: True
    }
    assert cluster.args[:3:] == ["cluster", "create", "qemu"]
    assert cluster.args[5:9:] == ["--controlplanes", "3", "--workers", "2"]
    assert "--exposed-ports" not in cluster.args, "qemu VMs have their own IPs"
    assert _patches_after(cluster.args, "--config-patch-controlplanes").KubeNodeConfig.labels["ingress-ready"] == "true"
}

test_talos_metal_gen_config = lambda {
    cluster = talos.TalosCluster {
        _provisioner: "metal"
        _endpoint: "https://10.0.0.10:6443"
        _workers: 3
        _oidc_bucket: "bucket"
        _oidc_id: "id"
    }
    assert cluster.args[:4:] == ["gen", "config", "talos", "https://10.0.0.10:6443"]
    assert "--workers" not in cluster.args, "gen config renders one worker.yaml for any number of machines"
    assert not _patches_after(cluster.args, "--config-patch-controlplanes"), "gen config spells the flag differently"
    patches = _patches_after(cluster.args, "--config-patch-control-plane")
    assert patches.KubeServiceAccountConfig.issuer.issuerURL == "https://storage.googleapis.com/bucket/id"
    assert "KubeNodeConfig" not in patches, "no ingress and workers present: nothing to change on the node"
}

# talosctl applies --mount to every node container; ingress stays independent.
test_talos_host_proc_docker = lambda {
    cluster = talos.TalosCluster {
        _workers: 1
        _host_proc: True
    }
    _i = [i for i, a in cluster.args if a == "--mount"][0]
    assert cluster.args[_i + 1] == "type=bind,source=/proc,target=/procHost"
    assert "--exposed-ports" not in cluster.args, "host_proc does not imply ingress"
    assert "--mount" not in talos.TalosCluster {_ingress: True}.args, "ingress does not imply host_proc"
}

test_talos_default_docker()
test_talos_workers_keep_control_plane_tainted()
test_talos_ingress_docker()
test_talos_qemu_control_planes()
test_talos_metal_gen_config()
test_talos_host_proc_docker()
