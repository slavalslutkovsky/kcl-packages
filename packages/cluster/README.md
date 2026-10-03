# cluster

Local Kubernetes cluster topology as one KCL render. `-D runner=` picks the
target CLI; the output is a single document at the root (no `items:` wrapper)
that CLI consumes directly.

| runner | schema | output | consumed by |
| --- | --- | --- | --- |
| `kind` (default) | `kind.Cluster` | `kind.x-k8s.io/v1alpha4` `Cluster` | `kind create cluster --config <file>` |
| `k3s` | `k3s.K3sCluster` | `k3d.io/v1alpha5` `Simple` | `k3d cluster create --config <file.yaml>` |
| `talos` | `talos.TalosCluster` | `{name, provisioner, args}` | `talosctl "${args[@]}"` |

## Usage

Every input is a KCL option, set with `-D key=value`. Keys are bare names:
`-D name=dev`, not `-D --name=dev`. A key KCL does not recognise is silently
ignored, so a typo falls back to the default instead of failing.

```bash
# kind, 1 worker, host 80/443 on the control plane
kcl run packages/cluster -D name=dev -D workers=1 -D ingress=true > kind.yaml
kind create cluster --config kind.yaml

# kind for Tetragon: host /proc at /procHost on every node
kcl run packages/cluster -D name=dev -D host_proc=true > kind.yaml
kind create cluster --config kind.yaml
helm install tetragon cilium/tetragon -n kube-system --set tetragon.hostProcPath=/procHost

# k3d, traefik off so another ingress controller can own 80/443
kcl run packages/cluster -D runner=k3s -D name=dev -D ingress=true -D traefik=false > k3d.yaml
k3d cluster create --config k3d.yaml

# talos on docker
args=(); while IFS= read -r a; do args+=("$a"); done < <(
    kcl run packages/cluster -D runner=talos -D name=dev --format json | jq -r '.args[]')
talosctl "${args[@]}"

# talos on docker for Tetragon: same /procHost remap, plus the tracefs mount
# Tetragon requires on Talos >= 1.12
args=(); while IFS= read -r a; do args+=("$a"); done < <(
    kcl run packages/cluster -D runner=talos -D name=dev -D host_proc=true --format json | jq -r '.args[]')
talosctl "${args[@]}"
helm install tetragon cilium/tetragon -n kube-system --set tetragon.hostProcPath=/procHost \
    --set 'extraHostPathMounts[0].name=sys-kernel-tracing' --set 'extraHostPathMounts[0].mountPath=/sys/kernel/tracing'
```

From the published package: `kcl run oci://docker.io/yurikrupnik/cluster --tag <version> -D …`.
devkit renders it this way for `devkit cluster create`, translating the
`[cluster]` table of the nearest `devkit.toml` into `-D` options (see
[docs/devkit.md](../../docs/devkit.md)).

## Options

| option | kind | k3s | talos | default | meaning |
| --- | :-: | :-: | :-: | --- | --- |
| `runner` | ✓ | ✓ | ✓ | `kind` | `kind`, `k3s` or `talos`; anything else fails the render |
| `name` | ✓ | ✓ | ✓ | `kind` / `k3s` / `talos` | Cluster name; kube context is `kind-<name>`, `k3d-<name>`, `admin@<name>` |
| `workers` | ✓ | ✓ | ✓ | `0` | Plain worker nodes (k3s agents) |
| `db_workers` | ✓ | ✓ | ✗ | `0` | Workers labelled and tainted `dedicated=database:NoSchedule`; talos rejects non-zero |
| `kafka_workers` | ✓ | | | `0` | Workers labelled and tainted `dedicated=kafka:NoSchedule` |
| `control_planes` | | ✓ | ✓ | `1` | k3s servers (more than one runs embedded etcd); talos needs `provisioner=qemu` for more than one |
| `ingress` | ✓ | ✓ | ✓ | `false` | kind: label the control plane `ingress-ready=true` and publish host 80/443 on it; k3s: publish 80/443 on the k3d load balancer; talos: label control planes `ingress-ready=true`, and on docker publish 80/443 |
| `host_proc` | ✓ | | docker | `false` | Bind-mount the host's `/proc` at `/procHost` on every node, for host-wide eBPF agents (Tetragon: `--set tetragon.hostProcPath=/procHost`). Node containers have their own pid namespace, so their `/proc` misses the PIDs eBPF reports. On Docker Desktop the host is its Linux VM. talos qemu/metal reject it: those nodes are real machines whose `/proc` already is the host's |
| `traefik` | | ✓ | | `true` | Keep k3s' bundled traefik |
| `k3s_image` | | ✓ | | `""` | `rancher/k3s` image; empty keeps k3d's default |
| `provisioner` | | | ✓ | `docker` | `docker` / `qemu` → `talosctl cluster create`; `metal` → `talosctl gen config` |
| `endpoint` | | | ✓ | `""` | Kubernetes API URL; required for `provisioner=metal` |
| `oidc_bucket` | ✓ | ✓ | ✓ | `""` | GCS bucket serving the cluster's OIDC discovery documents |
| `oidc_id` | ✓ | ✓ | ✓ | `""` | Path prefix inside `oidc_bucket`, one per cluster |

`oidc_bucket` and `oidc_id` must be set together. Set, they pin the API
server's service-account issuer to
`https://storage.googleapis.com/<oidc_bucket>/<oidc_id>`, so projected tokens
can be exchanged for cloud credentials through Workload Identity Federation.

With `workers=0`, control planes stay schedulable on every runner.

## Layout

| file | content |
| --- | --- |
| `main.k` | `runner` dispatch |
| `kind.k` | `Cluster`, `Node`, `PortMapping`, `Mount` and the kubeadm patches |
| `k3s.k` | `K3sCluster` and the k3d config schemas |
| `talos.k` | `TalosCluster`: talosctl argv with machine-config patches inlined as JSON |
| `*_test.k` | `kcl test` cases per runner |

## Development

```bash
pnpm exec nx run cluster:test     # kcl test
pnpm exec nx run cluster:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
