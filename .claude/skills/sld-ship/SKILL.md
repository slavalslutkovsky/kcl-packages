---
name: sld-ship
description: Take a DNS change through the local CI gate and onto the kind cluster — publish the dns packages to the kind registry, install XRD plus Compositions and providers, apply the zone, and report readiness and the name servers to delegate.
argument-hint: "[aws|gcp]"
arguments: backend
disable-model-invocation: true
allowed-tools:
  - Read
  - Bash(just check)
  - Bash(just registry)
  - Bash(just e2e-publish:*)
  - Bash(just install-module:*)
  - Bash(just install-functions)
  - Bash(just e2e-providers:*)
  - Bash(just workload:*)
  - Bash(just e2e-status)
  - Bash(kubectl get:*)
  - Bash(kubectl describe:*)
  - Bash(kubectl wait:*)
  - Bash(kubectl config current-context)
---

# Ship the DNS module to the cluster

Backend: `$backend` (default `aws`).

## Preflight

!`kubectl config current-context 2>/dev/null; docker ps --filter 'label=io.x-k8s.kind.role=control-plane' --format '{{.Names}}' 2>/dev/null; docker ps -q -f name=^kind-registry$ >/dev/null 2>&1 && echo "kind-registry: up" || echo "kind-registry: down"`

Stop and say so if the context is not `kind-kcl-e2e`: `.claude/hooks/guard-delivery.sh` will deny the apply steps, and correctly — `just install-module` rewrites Composition sources to the in-cluster registry and installs cluster-scoped providers. Create the cluster with `just e2e-up` (devkit selects the context) or switch with `kubectl config use-context kind-kcl-e2e`.

## Steps

1. **Gate first.** `just check` — the same `build test lint` run CI does, providers excluded. Stop on failure; do not publish a red tree.

2. **Registry up.** `just registry` (idempotent; pins `kind-registry` at `172.18.0.100` on the docker `kind` network and verifies `/v2/_catalog`).

3. **Publish the dns packages to the kind registry.** `just e2e-publish dns` — publishes every project matching `dns*` with `KCL_REGISTRY=localhost:5001`. Never publish to docker.io from here.

4. **Install the module.** `just install-module dns` applies `packages/cloud/dns/xrd/xrd.yaml` and both Compositions with their sources rewritten to `oci://kind-registry/`. If the Crossplane Functions are not installed yet, run `just install-functions` first.

5. **Providers.** `just e2e-providers dns` applies `packages/cloud/dns/xrd/providers.yaml` and waits for `condition=Healthy`. The dns module has no `providerconfigs.yaml`; without real cloud credentials the managed resources will stay unready — that is expected, and step 7 must say so rather than pretend.

6. **Apply the zone.** `kubectl apply -f packages/cloud/dns/xrd/examples/dns-$backend.yaml` (or the manifest the change introduced).

   Steps 4–6 for a clean cluster collapse into `just workload dns $backend`.

7. **Verify and report**, in this order:

   ```bash
   kubectl -n default get dnszone -o wide
   kubectl -n default get managed
   kubectl -n default describe dnszone <name> | sed -n '/Events/,$p'
   ```

   Report: the composed resource names (`record-<name>-<type>` — check they match what `/sld-new` rendered), `status.ready`, and `status.nameServers`. Say plainly which of these is true:
   - name servers present ⇒ the zone exists; the SLD still does not resolve until those name servers are set at the registrar;
   - no name servers / MRs not ready ⇒ name the blocking condition from the events (missing ProviderConfig and credentials is the normal one on a local cluster).

Never report success from `kubectl apply` alone — apply only means the XR was accepted.
