# Zellij viewpoints

A *viewpoint* is one Zellij session whose tab set is derived from a cluster,
not hand-written: `tools/zellij/zj.sh` asks the API server the current
kubeconfig context points at what it actually serves, and lays out one tab per
answer. The same script is also the inventory: what every other session on the
machine costs in CPU and memory, which of them are over budget, and which
remote host has the capacity to take one.

```
just zj                 # the viewpoint for the current context
just zj kind-kcl-e2e    # …or for a named one
just zj-ls              # every viewpoint here, with its cost and a verdict
just zj-advise          # the numbers, the candidate host, the move command
just zj-move zj-kind-kind buildbox --attach
```

Everything below is `tools/zellij/zj.sh <subcommand>`; the recipes are thin
wrappers.

## The layout is derived

`zj.sh probe` is the whole input:

```json
{
  "context": "kind-kind", "reachable": true, "kind": true,
  "nodes": 1, "namespaces": 6,
  "features": { "crossplane": false, "flux": false, "argo": true,
                "metrics": false, "chaos": false, "kubeblocks": false,
                "kclx": true }
}
```

Each feature is one `kubectl api-versions` group, and each one that is present
adds a tab:

| tab          | appears when                                    | shows |
| ------------ | ----------------------------------------------- | ----- |
| `cluster`    | always (reachable)                              | nodes wide + every not-Running pod, split with the event stream |
| `pods`       | always (reachable)                              | k9s if installed, otherwise a `kubectl get pods -A` loop |
| `xplane`     | `apiextensions.crossplane.io`                   | composites, composed managed resources with Synced/Ready, providers and functions |
| `flux`       | `helm.toolkit.fluxcd.io`                        | `flux get all -A`, or the sources/Kustomizations/HelmReleases if the CLI is missing |
| `argo`       | `argoproj.io`                                   | Applications and ApplicationSets |
| `kclx`       | `kclx.example.org`                              | the KclModules this repo's operator reconciles |
| `chaos`      | `chaos-mesh.org`                                | PodChaos/NetworkChaos/StressChaos/Schedules |
| `dbs`        | `apps.kubeblocks.io`                            | KubeBlocks Clusters |
| `capacity`   | `metrics.k8s.io`                                | `top nodes`, `top pods -A --sort-by=memory` |
| `viewpoints` | always                                          | `zj.sh ls --watch` — the inventory below |
| `repo`       | always                                          | a shell in the checkout |

An unreachable context is not an error: the cluster tabs are dropped and you
get `viewpoints` + `repo`.

Every pane runs `zj.sh view <name> <context>` — a refresh loop, because macOS
has no `watch(1)` — and every kubectl inside is pinned with `--context`. A
viewpoint therefore cannot be re-pointed by a `kubectl config use-context` in
another window; to follow a different cluster, open its own viewpoint. Sessions
are named `zj-<context>`.

`zj.sh layout [ctx]` prints the KDL without touching zellij. It is a plain
layout file: `zellij -n <file>` is what `up` ultimately runs.

Pane refresh is 10s (`ZJ_REFRESH`). `ZJ_PODS=kubectl` skips k9s.

## The inventory

`zj.sh ls` walks every zellij session's process tree — the server plus every
descendant of every pane — and sums it:

```
── viewpoints on Yuris-Mac-Studio · 16 cores · load 10.5 · 117170/131072 MiB free ──

SESSION       STATE  CONTEXT    WHERE           PANES  RSS MiB  CPU%   AVG%  VERDICT  WHY
zj-kind-kind  live   kind-kind  local→buildbox  14     85       189.0  77.5  offload  cpu 189% > 150% budget
bare          live   -          local           2      80       189.7  77.5  offload  cpu 190% > 150% budget
zj-prod       live   gke_prod   buildbox        9      420      38.2   31.0  -        within budget
```

* `CPU%` is the process tree's CPU time delta over a sampling window
  (`ZJ_SAMPLE`, 3s) as a percentage of **one** core — 189% is 1.9 cores.
* `AVG%` is what `ps` reports: a decaying recent average on BSD, a lifetime
  average on Linux. The verdict uses whichever of the two is larger.
* `RSS MiB` sums RSS per process, so shared pages are counted more than once.
  It over-estimates, which is the safe direction for "is this big".
* `WHERE` is provenance: `local`, `local→host` for a session that has also been
  provisioned elsewhere, or a host name for a row that came from that host.
* `--all` additionally asks every host in the inventory. Hosts that have had a
  viewpoint moved to them run this script (`move` pushes it) and report the full
  accounting; the rest only yield session names, and their columns stay blank
  rather than being guessed.
* `--json` emits the same rows as objects.

The numbers come from `/bin/ps`, not from whatever `ps` is first on `PATH`:
busybox-style replacements and some sandboxes report a truncated `TIME` and a
bogus `%CPU`, and every figure here derives from those two columns. `ZJ_PS`
overrides the choice.

### Why every idle viewpoint looks expensive

zellij 0.45.1 spins. A session with no client attached and nothing but a shell
in it burned 1:23 of CPU in 45 seconds of wall clock on the machine above —
about 1.9 cores. The panes this tool generates cost roughly nothing next to
that (`0:00.05` of CPU each after minutes of running). That is why
`ZJ_CPU_BUDGET` defaults to 150%: below ~100 every live session would be
flagged, and the interesting signal is work happening *on top of* zellij's own
idle cost. Two viewpoints open is ~4 cores of a 16-core machine, which is the
honest argument for moving some of them elsewhere.

## The verdict

A viewpoint is flagged `offload` when any of:

1. `max(CPU%, AVG%)` exceeds `ZJ_CPU_BUDGET` (default 150),
2. RSS exceeds `ZJ_RSS_BUDGET` (default 1536 MiB),
3. the machine is under pressure — load above 80% of the core count, or free
   memory below an eighth of total — and this is the largest viewpoint.

Otherwise it stays local: remote is not free, and a viewpoint that fits should
not move.

`zj.sh advise [session]` explains the verdict and picks the host:

```
── zj-kind-kind (live, context kind-kind, on local)
   14 panes · 85 MiB · 189.0% cpu now · 77.5% lifetime · heaviest: …/zj.sh ls --watch
   offload — cpu 189% > 150% budget
   → buildbox (dev@buildbox): 6.8 idle cores, 24576 MiB free, zellij 0.45.1
   ! kind-kind is a local kind context: the remote host cannot reach that API server
     unless it is exposed. Move the shell/build panes, keep the cluster tabs here.
```

Candidates are scored `(cores − load1) + free_MiB/4096`; a host without zellij
on `PATH`, or with less free memory than the viewpoint's RSS, is not a
candidate. The kind warning is not cosmetic: a kind API server listens on the
laptop's loopback, so a viewpoint built on `kind-*` is worth moving only for its
shell and build panes.

## Hosts

`tools/zellij/hosts.json`:

```json
{ "hosts": [ { "name": "buildbox", "ssh": "dev@buildbox", "note": "32c/128G" } ] }
```

`ssh` is anything `ssh(1)` resolves — usually a `Host` from `~/.ssh/config`.
Probing uses `BatchMode=yes` and a 4s connect timeout (`ZJ_SSH_TIMEOUT`), so
key auth is required and an asleep host is reported unreachable instead of
hanging the table. Keep personal machines out of the repo copy by pointing
`ZJ_HOSTS` at another file, or by creating
`~/.config/zj-viewpoint/hosts.json`, which shadows it.

`zj.sh hosts` probes them all: cores, load, memory, zellij version, session
count.

## Moving a viewpoint

```
just zj-move zj-kind-kind buildbox           # provision, print the attach command
just zj-move zj-kind-kind buildbox --attach  # …and take it now
just zj-move zj-kind-kind buildbox --kill-local
```

`move` resolves the host's `$HOME`, copies `zj.sh` to
`~/.cache/zj-viewpoint/`, renders the layout again with the remote paths baked
in (pane command and starting directory), pushes it beside the script, warns if
that host has no such kube context, and records the destination in the local
state file. It then prints:

```
ssh -t dev@buildbox "zellij attach 'zj-kind-kind' 2>/dev/null || \
    zellij --session 'zj-kind-kind' --new-session-with-layout '…/zj-kind-kind.kdl'"
```

No remote session is pre-created, because zellij only honours a layout at
session creation: that command *is* the creation, and every later connection
takes the `attach` branch. The session then outlives the ssh connection exactly
as a local one outlives its terminal. `zj.sh attach <session> [host]` is the
short form and rebuilds the session from the pushed layout if it has since been
killed.

The local session is left running unless you pass `--kill-local`: a "move" that
destroys what you were looking at before you have seen the remote copy is a
worse trade than a few seconds of double booking.

## Implementation notes

* **Layouts are applied at creation.** `zellij action new-tab --layout` against
  a background session silently drops all but the last tabs of a multi-tab
  layout, and the default first tab cannot be closed from the CLI while no
  client is attached. `up` therefore runs
  `zellij --session <name> --new-session-with-layout <file>`.
* **`up --detached`** (used by tests and CI) still needs a client, so it starts
  one under a throwaway pty via `script(1)` and kills it once the server is up.
* **k9s** gets the `pods` pane to itself, but it exits when the session is
  created with no client attached, so the pane falls back to the kubectl loop
  instead of dying.
* Per-session metadata (context, destination host, creation time) lives in
  `${XDG_STATE_HOME:-~/.local/state}/zj-viewpoint/`, alongside the generated
  layouts.
