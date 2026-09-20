#!/usr/bin/env bash
# tools/zellij/zj.sh — a Zellij workspace ("viewpoint") that mirrors the cluster
# the current kubeconfig context points at, plus an inventory of every other
# viewpoint on this machine: what each one costs in CPU and RSS, and whether it
# is worth moving to a remote host and attaching to it over ssh.
#
#   zj.sh probe  [ctx]                  JSON: what the context actually serves
#   zj.sh layout [ctx]                  the KDL that probe implies (stdout)
#   zj.sh up     [ctx] [name] [--detached]
#                                       create/attach the viewpoint for a context
#   zj.sh view   <view> [ctx]           one pane's refresh loop (ZJ_ONCE=1: once)
#   zj.sh ls     [--watch] [--all] [--json]
#                                       every viewpoint + its cost + a verdict;
#                                       --all also asks the inventory's hosts
#   zj.sh advise [session]              the verdict and the numbers behind it
#   zj.sh hosts  [--json]               remote hosts and their free capacity
#   zj.sh move   <session> <host> [--attach] [--kill-local]
#   zj.sh attach <session> [host]
#
# The layout is derived, never hand-maintained: `probe` asks the API server
# which groups exist and every tab below is conditional on one of them, so the
# same command against a bare kind cluster and against the management cluster
# gives two different workspaces. Every kubectl in a generated pane is pinned
# with --context, so switching context in another shell cannot re-point a
# running viewpoint.
#
# Tunables, all environment: ZJ_CPU_BUDGET (percent of one core, default 150),
# ZJ_RSS_BUDGET (MiB, 1536), ZJ_SAMPLE (cpu sampling window, 3s), ZJ_REFRESH
# (pane refresh, 10s), ZJ_HOSTS (inventory path), ZJ_PODS=kubectl (skip k9s),
# ZJ_STATE_DIR, ZJ_PS, ZJ_SSH_TIMEOUT.
#
# Requires: zellij >= 0.41 (`--new-session-with-layout`), kubectl, jq. k9s and
# flux are used when present. The justfile wraps this (`just zj`, `just zj-ls`,
# `just zj-advise`, `just zj-move`); docs/zellij.md is the long form.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
# Baked into generated layouts: the script the panes run and the directory
# they start in. `move` overrides both, because the host it pushes a viewpoint
# to has no checkout of this repo.
self=${ZJ_SELF:-$here/zj.sh}
base=${ZJ_CWD:-$root}

state_dir=${ZJ_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zj-viewpoint}
hosts_file=${ZJ_HOSTS:-}
if [ -z "$hosts_file" ]; then
    if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/zj-viewpoint/hosts.json" ]; then
        hosts_file="${XDG_CONFIG_HOME:-$HOME/.config}/zj-viewpoint/hosts.json"
    else
        hosts_file="$here/hosts.json"
    fi
fi

# Offload thresholds. cpu is percent of ONE core summed over the session's
# process tree; rss is MiB, summed the same way (shared pages counted once per
# process — an over-estimate, which is the safe direction for "is this big").
# The cpu default sits above zellij's own idle cost: 0.45.1 spins its server at
# roughly 0.8 of a core per session even with no client attached and nothing
# running in it, so a budget under ~100 would flag every viewpoint alive.
cpu_budget=${ZJ_CPU_BUDGET:-150}
rss_budget=${ZJ_RSS_BUDGET:-1536}
# Seconds between the two cputime samples "CPU% now" is a delta of. 0 skips the
# second sample and leaves that column at the lifetime average. ps reports
# cputime at one-second resolution, so a window under ~3s quantises badly.
sample=${ZJ_SAMPLE:-3}
refresh=${ZJ_REFRESH:-10}
# The system ps, not whatever shim is first on PATH: some sandboxes and
# busybox-style replacements report a truncated TIME and a bogus %CPU, and
# every number below is derived from those two columns.
ps_bin=${ZJ_PS:-}
for c in /bin/ps /usr/bin/ps ps; do [ -n "$ps_bin" ] && break; command -v "$c" >/dev/null 2>&1 && ps_bin=$c; done
ssh_opts=(-o BatchMode=yes -o ConnectTimeout="${ZJ_SSH_TIMEOUT:-4}")

die() { printf 'zj: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

# ─── cluster probe ────────────────────────────────────────────────────────────

kctx() { # [ctx] -> the context to work against
    if [ -n "${1:-}" ]; then printf '%s' "$1"; return; fi
    kubectl config current-context 2>/dev/null || die "no current kube context"
}

# One JSON object describing the cluster: which API groups the tabs key off,
# node/namespace counts, and whether the API server answered at all. A dead or
# unreachable context is not an error — it yields reachable=false and a layout
# with the cluster tabs left out.
probe_json() { # ctx
    local ctx=$1 groups nodes ns reachable=true
    groups=$(kubectl --context "$ctx" --request-timeout=5s api-versions 2>/dev/null | sed 's:/.*::' | sort -u) || true
    [ -z "$groups" ] && reachable=false
    if [ "$reachable" = true ]; then
        nodes=$(kubectl --context "$ctx" --request-timeout=5s get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ns=$(kubectl --context "$ctx" --request-timeout=5s get ns --no-headers 2>/dev/null | wc -l | tr -d ' ')
    fi
    has() { printf '%s\n' "$groups" | grep -qx "$1"; }
    jq -n \
        --arg ctx "$ctx" \
        --argjson reachable "$reachable" \
        --arg nodes "${nodes:-0}" \
        --arg ns "${ns:-0}" \
        --argjson kind "$(case "$ctx" in kind-*) echo true ;; *) echo false ;; esac)" \
        --argjson crossplane "$(has apiextensions.crossplane.io && echo true || echo false)" \
        --argjson flux "$(has helm.toolkit.fluxcd.io && echo true || echo false)" \
        --argjson argo "$(has argoproj.io && echo true || echo false)" \
        --argjson metrics "$(has metrics.k8s.io && echo true || echo false)" \
        --argjson chaos "$(has chaos-mesh.org && echo true || echo false)" \
        --argjson kubeblocks "$(has apps.kubeblocks.io && echo true || echo false)" \
        --argjson kclx "$(has kclx.example.org && echo true || echo false)" \
        '{context:$ctx, reachable:$reachable, kind:$kind,
          nodes:($nodes|tonumber), namespaces:($ns|tonumber),
          features:{crossplane:$crossplane, flux:$flux, argo:$argo, metrics:$metrics,
                    chaos:$chaos, kubeblocks:$kubeblocks, kclx:$kclx}}'
}

# Tab names the probe implies, in the order they are laid out. Kept separate
# from the KDL so `up` can report the shape without re-rendering it.
probe_views() { # probe-json -> one view name per line
    local p=$1
    if [ "$(jq -r .reachable <<<"$p")" = true ]; then
        printf 'cluster\npods\n'
        [ "$(jq -r .features.crossplane <<<"$p")" = true ] && printf 'xplane\n'
        [ "$(jq -r .features.flux <<<"$p")" = true ] && printf 'flux\n'
        [ "$(jq -r .features.argo <<<"$p")" = true ] && printf 'argo\n'
        [ "$(jq -r .features.kclx <<<"$p")" = true ] && printf 'kclx\n'
        [ "$(jq -r .features.chaos <<<"$p")" = true ] && printf 'chaos\n'
        [ "$(jq -r .features.kubeblocks <<<"$p")" = true ] && printf 'dbs\n'
        [ "$(jq -r .features.metrics <<<"$p")" = true ] && printf 'capacity\n'
    fi
    printf 'viewpoints\nrepo\n'
    return 0
}

# ─── layout ───────────────────────────────────────────────────────────────────

# A pane that runs one of this script's views. Args are separate KDL strings,
# so nothing here has to survive a round trip through a shell.
kdl_view_pane() { # view ctx [indent]
    local v=$1 ctx=$2 pad=${3:-            }
    printf '%spane command="%s" {\n%s    args "view" "%s" "%s"\n%s}\n' \
        "$pad" "$self" "$pad" "$v" "$ctx" "$pad"
}

layout() { # ctx [probe-json]
    local ctx=$1 p=${2:-} v
    [ -n "$p" ] || p=$(probe_json "$ctx")
    printf 'layout {\n'
    printf '    cwd "%s"\n' "$base"
    local first=true
    while read -r v; do
        [ -n "$v" ] || continue
        local focus='' ; [ "$first" = true ] && { focus=' focus=true'; first=false; }
        case "$v" in
            cluster)
                printf '    tab name="cluster"%s {\n        pane split_direction="horizontal" {\n' "$focus"
                kdl_view_pane nodes "$ctx"
                kdl_view_pane events "$ctx"
                printf '        }\n    }\n' ;;
            pods)
                printf '    tab name="pods"%s {\n' "$focus"
                kdl_view_pane pods "$ctx" '        '
                printf '    }\n' ;;
            repo)
                # No command: the default shell, where the work happens.
                printf '    tab name="repo"%s {\n        pane cwd="%s"\n    }\n' "$focus" "$base" ;;
            viewpoints)
                printf '    tab name="viewpoints"%s {\n' "$focus"
                printf '        pane command="%s" {\n            args "ls" "--watch"\n        }\n' "$self"
                printf '    }\n' ;;
            *)
                printf '    tab name="%s"%s {\n' "$v" "$focus"
                kdl_view_pane "$v" "$ctx" '        '
                printf '    }\n' ;;
        esac
    done <<<"$(probe_views "$p")"
    printf '}\n'
}

# ─── views ────────────────────────────────────────────────────────────────────
#
# Each view is a refresh loop rather than `watch`: macOS ships no watch(1), and
# a loop keeps the pane's process tree shallow enough for the accounting below
# to attribute it. ZJ_ONCE=1 renders one frame and exits — that is how the
# views are tested.

view_once() { # view ctx
    local v=$1 ctx=$2 k=(kubectl --context "$2" --request-timeout=10s)
    case "$v" in
        nodes)
            printf '── nodes · %s ─────────────────────────────\n' "$ctx"
            "${k[@]}" get nodes -o wide 2>&1 || true
            printf '\n── not-ready / pending pods ───────────────\n'
            "${k[@]}" get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>&1 | head -20 || true ;;
        events)
            printf '── events (newest last) · %s ──────────────\n' "$ctx"
            "${k[@]}" get events -A --sort-by=.lastTimestamp 2>&1 | tail -25 || true ;;
        pods)
            "${k[@]}" get pods -A -o wide 2>&1 || true ;;
        xplane)
            printf '── composites ─────────────────────────────\n'
            "${k[@]}" get composite -A 2>&1 | head -25 || true
            printf '\n── managed resources ──────────────────────\n'
            "${k[@]}" get managed -o custom-columns=KIND:.kind,NAME:.metadata.name,SYNCED:'.status.conditions[?(@.type=="Synced")].status',READY:'.status.conditions[?(@.type=="Ready")].status' 2>&1 | head -25 || true
            printf '\n── providers / functions ──────────────────\n'
            "${k[@]}" get providers.pkg.crossplane.io,functions.pkg.crossplane.io 2>&1 || true ;;
        flux)
            if have flux; then
                flux --context "$ctx" get all -A 2>&1 || true
            else
                "${k[@]}" get gitrepositories,ocirepositories,helmrepositories,kustomizations,helmreleases -A 2>&1 || true
            fi ;;
        argo)
            "${k[@]}" get applications,applicationsets -A 2>&1 || true ;;
        kclx)
            "${k[@]}" get kclmodules -A 2>&1 || true ;;
        chaos)
            "${k[@]}" get podchaos,networkchaos,stresschaos,schedules -A 2>&1 || true ;;
        dbs)
            "${k[@]}" get clusters.apps.kubeblocks.io -A 2>&1 || true ;;
        capacity)
            printf '── top nodes ──────────────────────────────\n'
            "${k[@]}" top nodes 2>&1 || true
            printf '\n── top pods by memory ─────────────────────\n'
            "${k[@]}" top pods -A --sort-by=memory 2>&1 | head -20 || true ;;
        *) die "unknown view '$v'" ;;
    esac
}

view() { # view ctx
    local v=$1 ctx=${2:-}
    ctx=$(kctx "$ctx")
    # k9s is a TUI, not a frame, so it gets the pane to itself — but it exits
    # when the layout is created with no client attached, and a pane that has
    # died is worse than a plain table. On the way out, fall through to the
    # loop below instead of exec'ing into k9s.
    if [ "$v" = pods ] && have k9s && [ -z "${ZJ_ONCE:-}" ] && [ "${ZJ_PODS:-k9s}" = k9s ]; then
        k9s --context "$ctx" -A || true
    fi
    if [ -n "${ZJ_ONCE:-}" ]; then view_once "$v" "$ctx"; return; fi
    while :; do
        printf '\033[H\033[2J'
        view_once "$v" "$ctx"
        sleep "$refresh"
    done
}

# ─── sessions and what they cost ──────────────────────────────────────────────

# name<TAB>state for every session zellij knows about. Exited (resurrectable)
# sessions have no server process and therefore no cost.
session_list() {
    zellij list-sessions --no-formatting 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '
        NF { print $1 "\t" (index($0, "EXITED") ? "exited" : "live") }' || true
}

# name<TAB>server-pid. The session name is the last path segment of the socket
# the server was started with, which is the only place zellij exposes it.
session_pids() {
    "$ps_bin" -Ao pid=,command= | awk '
        $2 ~ /(^|\/)zellij$/ {
            sock = ""
            for (i = 3; i <= NF; i++) if ($i == "--server" && i < NF) { sock = $(i + 1); break }
            if (sock == "") next
            n = split(sock, parts, "/")
            print parts[n] "\t" $1
        }'
}

ps_snapshot() { "$ps_bin" -Ao pid=,ppid=,rss=,time=,%cpu=,command=; }

# Aggregate every descendant of each server pid: process count, summed RSS,
# summed lifetime %CPU, and — when two snapshots are given — the CPU time each
# tree burned between them, as a percentage of one core.
usage_rows() { # roots="name:pid,name:pid" -> name<TAB>procs<TAB>rss_mib<TAB>cpu_now<TAB>cpu_avg<TAB>top
    local roots=$1 s1 s2
    [ -n "$roots" ] || return 0
    s1=$(mktemp); s2=$(mktemp)
    trap 'rm -f "$s1" "$s2"' RETURN
    ps_snapshot >"$s1"
    if [ "${sample%.*}" != 0 ]; then sleep "$sample"; fi
    ps_snapshot >"$s2"
    awk -v roots="$roots" -v window="$sample" '
        function secs(t,   p, n, s, i) {
            gsub(/-/, ":", t); n = split(t, p, ":"); s = 0
            for (i = 1; i <= n; i++) s = s * 60 + p[i]
            return s
        }
        function cmdof(   i, c) { c = ""; for (i = 6; i <= NF; i++) c = c (i > 6 ? " " : "") $i; return c }
        FNR == NR { t1[$1] = secs($4); next }
        {
            pid = $1; kids[$2] = kids[$2] " " pid
            rss[pid] = $3; t2[pid] = secs($4); avg[pid] = $5; cmd[pid] = cmdof()
        }
        END {
            n = split(roots, rs, ",")
            for (r = 1; r <= n; r++) {
                split(rs[r], kv, ":"); name = kv[1]; root = kv[2]
                procs = 0; sum_rss = 0; sum_avg = 0; delta = 0; top = ""; top_rss = -1
                queue = root
                while (queue != "") {
                    split(queue, q, " "); queue = ""
                    for (i in q) {
                        p = q[i]; if (p == "" || seen[name, p]++) continue
                        if (!(p in rss)) continue
                        procs++; sum_rss += rss[p]; sum_avg += avg[p]
                        if (p in t1) { d = t2[p] - t1[p]; if (d > 0) delta += d }
                        if (p != root && rss[p] > top_rss) { top_rss = rss[p]; top = cmd[p] }
                        if (p in kids) queue = queue " " kids[p]
                    }
                }
                now = (window + 0 > 0) ? delta / (window + 0) * 100 : sum_avg
                if (top == "") top = cmd[root]
                # zellij leaves the full socket path on the server argv; the
                # bare binary name is all a table column can use.
                sub(/ --server .*/, "", top)
                printf "%s\t%d\t%.0f\t%.1f\t%.1f\t%s\n", name, procs, sum_rss / 1024, now, sum_avg, top
            }
        }' "$s1" "$s2"
}

# ─── this machine, and the ones the inventory knows ───────────────────────────

host_capacity() { # -> cores<TAB>load1<TAB>mem_total_mib<TAB>mem_free_mib
    local cores load mem_total mem_free
    if [ "$(uname -s)" = Darwin ]; then
        cores=$(sysctl -n hw.ncpu)
        load=$(sysctl -n vm.loadavg | awk '{print $2}')
        mem_total=$(( $(sysctl -n hw.memsize) / 1048576 ))
        # Free = unused + purgeable file cache, in 16 KiB pages on arm64.
        mem_free=$(vm_stat | awk -v t="$mem_total" '
            /page size of/ { for (i = 1; i <= NF; i++) if ($i + 0 > 512) { ps = $i; break } }
            /Pages free/ { f = $3 } /Pages inactive/ { inact = $3 } /File-backed pages/ { fb = $3 }
            END { gsub(/\./, "", f); gsub(/\./, "", inact); gsub(/\./, "", fb)
                  printf "%d", (f + inact + fb) * (ps ? ps : 16384) / 1048576 }')
    else
        cores=$(nproc)
        load=$(awk '{print $1}' /proc/loadavg)
        mem_total=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
        mem_free=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
    fi
    printf '%s\t%s\t%s\t%s\n' "$cores" "$load" "$mem_total" "$mem_free"
}

hosts_inventory() {
    [ -f "$hosts_file" ] || { printf '{"hosts":[]}\n'; return; }
    jq -c . "$hosts_file"
}

# The same capacity numbers, over ssh, from a posix-sh snippet that works on
# both a Linux box and another mac. Unreachable hosts are reported, not fatal:
# an advisor that dies because one build box is asleep is useless.
host_probe() { # ssh-target -> cores<TAB>load1<TAB>mem_total<TAB>mem_free<TAB>zellij<TAB>sessions
    local target=$1 out
    out=$(ssh "${ssh_opts[@]}" "$target" 'sh -c '"'"'
        if [ "$(uname -s)" = Darwin ]; then
            cores=$(sysctl -n hw.ncpu); load=$(sysctl -n vm.loadavg | awk "{print \$2}")
            total=$(( $(sysctl -n hw.memsize) / 1048576 ))
            free=$(vm_stat | awk "/Pages free/ {gsub(/\./,\"\",\$3); f=\$3} /Pages inactive/ {gsub(/\./,\"\",\$3); i=\$3} END {printf \"%d\", (f+i)*16384/1048576}")
        else
            cores=$(nproc); load=$(awk "{print \$1}" /proc/loadavg)
            total=$(awk "/MemTotal/ {printf \"%d\", \$2/1024}" /proc/meminfo)
            free=$(awk "/MemAvailable/ {printf \"%d\", \$2/1024}" /proc/meminfo)
        fi
        zj=$(command -v zellij >/dev/null 2>&1 && zellij --version 2>/dev/null | awk "{print \$2}" || echo none)
        sessions=$(zellij list-sessions --no-formatting 2>/dev/null | grep -c . || echo 0)
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$cores" "$load" "$total" "$free" "$zj" "$sessions"
    '"'"'' 2>/dev/null) || { printf 'unreachable\n'; return 1; }
    printf '%s\n' "$out"
}

cmd_hosts() {
    local json=false; [ "${1:-}" = --json ] && json=true
    local inv rows='' name target note line
    inv=$(hosts_inventory)
    [ "$(jq '.hosts | length' <<<"$inv")" -gt 0 ] || {
        printf 'no remote hosts declared — add them to %s (see docs/zellij.md)\n' "$hosts_file" >&2
        [ "$json" = true ] && printf '[]\n'
        return 0
    }
    while IFS=$'\t' read -r name target note; do
        if line=$(host_probe "$target"); then
            rows+="$name	$target	$line	$note
"
        else
            rows+="$name	$target	-	-	-	-	-	-	$note
"
        fi
    done < <(jq -r '.hosts[] | [.name, .ssh, (.note // "")] | @tsv' <<<"$inv")
    if [ "$json" = true ]; then
        printf '%s' "$rows" | awk -F'\t' 'NF {printf "{\"name\":\"%s\",\"ssh\":\"%s\",\"cores\":\"%s\",\"load1\":\"%s\",\"mem_total_mib\":\"%s\",\"mem_free_mib\":\"%s\",\"zellij\":\"%s\",\"sessions\":\"%s\"}\n", $1,$2,$3,$4,$5,$6,$7,$8}' | jq -s .
    else
        { printf 'HOST\tSSH\tCORES\tLOAD1\tMEM MiB\tFREE MiB\tZELLIJ\tSESS\tNOTE\n'; printf '%s' "$rows"; } | column -t -s$'\t'
    fi
}

# Free capacity score: idle cores first, free memory as the tie-break. Hosts
# without zellij are not candidates — the whole point is to attach to one.
best_host() { # required_rss_mib -> name<TAB>ssh<TAB>why | empty
    local need=$1 inv name target line cores load free zj best='' best_score=0 why=''
    inv=$(hosts_inventory)
    while IFS=$'\t' read -r name target; do
        line=$(host_probe "$target") || continue
        IFS=$'\t' read -r cores load _ free zj _ <<<"$line"
        [ "$zj" = none ] && continue
        [ "${free%%.*}" -lt "$need" ] 2>/dev/null && continue
        local score
        score=$(awk -v c="$cores" -v l="$load" -v f="$free" 'BEGIN {printf "%.2f", (c - l) + f / 4096}')
        if awk -v a="$score" -v b="$best_score" 'BEGIN {exit !(a > b)}'; then
            best=$name; best_score=$score
            why=$(printf '%s idle cores, %s MiB free, zellij %s' \
                "$(awk -v c="$cores" -v l="$load" 'BEGIN {printf "%.1f", c - l}')" "$free" "$zj")
            best_target=$target
        fi
    done < <(jq -r '.hosts[] | [.name, .ssh] | @tsv' <<<"$inv")
    [ -n "$best" ] || return 1
    printf '%s\t%s\t%s\n' "$best" "$best_target" "$why"
}

# ─── the verdict ──────────────────────────────────────────────────────────────
#
# Two independent reasons to move a viewpoint off this machine:
#   1. the session itself is over budget (a k9s per namespace, a stern tail, a
#      cargo build in the repo tab), or
#   2. the machine is over budget and this session is the biggest contributor.
# Anything else stays local; remote is not free (latency, a second kubeconfig).

verdict() { # rss_mib cpu_now cpu_avg host_pressure biggest -> verdict<TAB>reason
    local rss=$1 now=$2 avg=$3 pressure=$4 biggest=$5
    local cpu; cpu=$(awk -v a="$now" -v b="$avg" 'BEGIN {print (a > b ? a : b)}')
    if awk -v c="$cpu" -v b="$cpu_budget" 'BEGIN {exit !(c > b)}'; then
        printf 'offload\tcpu %.0f%% > %s%% budget\n' "$cpu" "$cpu_budget"; return
    fi
    if [ "$rss" -gt "$rss_budget" ]; then
        printf 'offload\trss %s MiB > %s MiB budget\n' "$rss" "$rss_budget"; return
    fi
    if [ "$pressure" = true ] && [ "$biggest" = true ]; then
        printf 'offload\tmachine under pressure, largest viewpoint\n'; return
    fi
    printf 'local\twithin budget\n'
}

# Everything `ls` and `advise` need: one TSV row per session, already scored.
collect() { # -> name<TAB>state<TAB>ctx<TAB>where<TAB>procs<TAB>rss<TAB>now<TAB>avg<TAB>verdict<TAB>reason<TAB>top
    local pids roots='' name state pid rows=''
    pids=$(session_pids)
    while IFS=$'\t' read -r name state; do
        [ -n "$name" ] || continue
        if [ "$state" = live ]; then
            pid=$(awk -F'\t' -v n="$name" '$1 == n {print $2}' <<<"$pids" | head -1)
            [ -n "$pid" ] && roots+="${roots:+,}$name:$pid"
        fi
    done < <(session_list)

    local usage=''
    [ -n "$roots" ] && usage=$(usage_rows "$roots")

    # Machine pressure and the biggest session, both needed before any verdict.
    local cores load mem_total mem_free total_rss=0 max_rss=0 max_name=''
    IFS=$'\t' read -r cores load mem_total mem_free < <(host_capacity)
    while IFS=$'\t' read -r name _ rss _ _ _; do
        [ -n "$name" ] || continue
        total_rss=$((total_rss + rss))
        [ "$rss" -gt "$max_rss" ] && { max_rss=$rss; max_name=$name; }
    done <<<"$usage"
    local pressure=false
    awk -v l="$load" -v c="$cores" 'BEGIN {exit !(l > c * 0.8)}' && pressure=true
    [ "$mem_free" -lt $((mem_total / 8)) ] && pressure=true

    local procs rss now avg top ctx where v reason
    while IFS=$'\t' read -r name state; do
        [ -n "$name" ] || continue
        ctx=$(session_meta "$name" context); where=$(session_meta "$name" host)
        if [ "$state" = live ]; then
            IFS=$'\t' read -r _ procs rss now avg top < <(awk -F'\t' -v n="$name" '$1 == n' <<<"$usage") || true
            : "${procs:=0}" "${rss:=0}" "${now:=0}" "${avg:=0}"
            local biggest=false; [ "$name" = "$max_name" ] && biggest=true
            IFS=$'\t' read -r v reason < <(verdict "$rss" "$now" "$avg" "$pressure" "$biggest")
        else
            procs=0; rss=0; now=0; avg=0; top='-'; v='-'; reason='not running'
        fi
        # `where` is about provenance, not measurement: these rows are always
        # local processes, but a session that has been moved also exists on the
        # host it was pushed to until it is killed here.
        [ -n "$where" ] && [ "$where" != local ] && where="local→$where"
        rows+="$name	$state	${ctx:--}	${where:-local}	$procs	$rss	$now	$avg	$v	$reason	${top:--}
"
    done < <(session_list)
    printf '%s' "$rows"
}

# ─── per-session state (which context a viewpoint was built for) ──────────────

session_meta() { # name field
    local f="$state_dir/$1.json"
    [ -f "$f" ] || return 0
    jq -r --arg k "$2" '.[$k] // empty' "$f" 2>/dev/null || true
}

session_meta_write() { # name context host
    mkdir -p "$state_dir"
    jq -n --arg c "$2" --arg h "$3" --arg t "$(date -u +%FT%TZ)" \
        '{context:$c, host:$h, created:$t}' >"$state_dir/$1.json"
}

# ─── commands ─────────────────────────────────────────────────────────────────

session_name() { # ctx -> zj-<sanitised>
    printf 'zj-%s' "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '-' | sed 's/-\{2,\}/-/g; s/-$//')"
}

# Start a session, with its layout, without occupying this terminal. zellij
# has no "create background *with layout*" mode, so the client is run under a
# throwaway pty (script(1), spelled differently on BSD and Linux) and killed
# once the server is up; the session it created outlives it, exactly as it
# outlives a closed terminal.
start_detached() { # name layout-file
    local name=$1 file=$2 pid
    if [ "$(uname -s)" = Darwin ]; then
        TERM=${TERM:-xterm-256color} script -q /dev/null \
            zellij --session "$name" --new-session-with-layout "$file" >/dev/null 2>&1 &
    else
        TERM=${TERM:-xterm-256color} script -qec \
            "zellij --session '$name' --new-session-with-layout '$file'" /dev/null >/dev/null 2>&1 &
    fi
    pid=$!
    for _ in $(seq 1 40); do
        session_list | grep -q "^$name	live" && break
        sleep 0.5
    done
    # Give the layout's tabs time to materialise before the client goes away.
    sleep 2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    session_list | grep -q "^$name	live" || die "session $name did not come up"
}

cmd_up() { # [ctx] [name]
    local ctx name p layout_file detached=false
    local args=()
    for a in "$@"; do case "$a" in --detached) detached=true ;; *) args+=("$a") ;; esac; done
    ctx=$(kctx "${args[0]:-}")
    name=${args[1]:-$(session_name "$ctx")}
    p=$(probe_json "$ctx")

    if [ "$(jq -r .reachable <<<"$p")" != true ]; then
        printf 'zj: context %s is not answering — laying out the local tabs only\n' "$ctx" >&2
    fi

    local existing
    existing=$(session_list | awk -F'\t' -v n="$name" '$1 == n {print $2}')
    if [ "$existing" = live ]; then
        printf 'zj: %s already exists (%s) — attaching\n' "$name" "$ctx" >&2
        [ "$detached" = true ] && return 0
        exec zellij attach "$name"
    fi

    layout_file="$state_dir/layouts/$name.kdl"
    mkdir -p "$state_dir/layouts"
    layout "$ctx" "$p" >"$layout_file"
    session_meta_write "$name" "$ctx" local
    printf 'zj: %s → %s (%s)\n' "$name" "$(probe_views "$p" | tr '\n' ' ')" "$ctx" >&2
    # The layout has to be handed to zellij at session creation. Appending it
    # afterwards with `action new-tab --layout` silently drops all but the last
    # tabs of a multi-tab layout, and the default first tab cannot be closed
    # from the CLI while no client is attached.
    if [ "$detached" = true ]; then
        start_detached "$name" "$layout_file"
        printf '%s\n' "$name"
        return 0
    fi
    exec zellij --session "$name" --new-session-with-layout "$layout_file"
}

# The viewpoints living on the inventory's hosts, in the same TSV shape as
# collect(). Hosts that have had a viewpoint moved to them run this very script
# (move pushes it), so they can be asked for the full accounting; the rest only
# yield session names, and their numbers stay blank rather than being guessed.
collect_remote() {
    local name target rows='' json line
    [ -f "$hosts_file" ] || return 0
    while IFS=$'\t' read -r name target; do
        [ -n "$target" ] || continue
        if json=$(ssh "${ssh_opts[@]}" "$target" '$HOME/.cache/zj-viewpoint/zj.sh ls --json' 2>/dev/null) \
            && [ -n "$json" ] && [ "$json" != "[]" ]; then
            rows+=$(jq -r --arg h "$name" '.[] | [.session, .state, .context, $h, (.procs|tostring),
                (.rss_mib|tostring), (.cpu_now|tostring), (.cpu_avg|tostring), "-", .reason, .top] | @tsv' <<<"$json")
            rows+=$'\n'
        else
            while read -r line; do
                [ -n "$line" ] || continue
                rows+="$line	live	-	$name	-	-	-	-	-	no zj.sh on host	-
"
            done < <(ssh "${ssh_opts[@]}" "$target" 'zellij list-sessions --no-formatting 2>/dev/null' 2>/dev/null | awk 'NF {print $1}')
        fi
    done < <(jq -r '.hosts[] | [.name, .ssh] | @tsv' <(hosts_inventory))
    printf '%s' "$rows"
}

cmd_ls() {
    local watch=false json=false all=false a
    for a in "$@"; do case "$a" in --watch|-w) watch=true ;; --json) json=true ;; --all|-a) all=true ;; esac; done
    if [ "$json" = true ]; then
        { collect; [ "$all" = true ] && collect_remote; } | awk -F'\t' 'NF' | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") |
            {session:.[0], state:.[1], context:.[2], where:.[3], procs:(.[4]|tonumber? // 0),
             rss_mib:(.[5]|tonumber? // 0), cpu_now:(.[6]|tonumber? // 0), cpu_avg:(.[7]|tonumber? // 0),
             verdict:.[8], reason:.[9], top:.[10]})'
        return
    fi
    while :; do
        [ "$watch" = true ] && printf '\033[H\033[2J'
        local cores load mem_total mem_free rows
        IFS=$'\t' read -r cores load mem_total mem_free < <(host_capacity)
        printf '── viewpoints on %s · %s cores · load %s · %s/%s MiB free ──\n\n' \
            "$(hostname -s)" "$cores" "$load" "$mem_free" "$mem_total"
        rows=$(collect)
        # $(…) eats the trailing newline, so the remote block needs its own.
        [ "$all" = true ] && rows=$rows$'\n'$(collect_remote)
        if [ -z "$rows" ]; then
            printf 'no zellij sessions\n'
        else
            {
                printf 'SESSION\tSTATE\tCONTEXT\tWHERE\tPANES\tRSS MiB\tCPU%%\tAVG%%\tVERDICT\tWHY\n'
                printf '%s' "$rows" | awk -F'\t' 'NF {printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10}'
            } | column -t -s$'\t'
            if printf '%s' "$rows" | awk -F'\t' '$9 == "offload" {found=1} END {exit !found}'; then
                printf '\n%s\n' "over budget — 'zj.sh advise' picks a host, 'zj.sh move <session> <host>' relocates it"
            fi
        fi
        [ "$watch" = true ] || break
        sleep "$refresh"
    done
}

cmd_advise() { # [session]
    local want=${1:-} rows name state ctx where procs rss now avg v reason top
    rows=$(collect)
    [ -n "$rows" ] || { printf 'no zellij sessions\n'; return 0; }
    local any=false
    while IFS=$'\t' read -r name state ctx where procs rss now avg v reason top; do
        [ -n "$name" ] || continue
        [ -n "$want" ] && [ "$name" != "$want" ] && continue
        any=true
        printf '── %s (%s, context %s, on %s)\n' "$name" "$state" "$ctx" "$where"
        printf '   %s panes · %s MiB · %s%% cpu now · %s%% lifetime · heaviest: %s\n' \
            "$procs" "$rss" "$now" "$avg" "$top"
        if [ "$v" != offload ]; then
            printf '   keep local — %s\n' "$reason"
            continue
        fi
        printf '   offload — %s\n' "$reason"
        local best
        if best=$(best_host "$rss"); then
            local hname htarget why; IFS=$'\t' read -r hname htarget why <<<"$best"
            printf '   → %s (%s): %s\n' "$hname" "$htarget" "$why"
            case "$ctx" in
                kind-*|"")
                    printf '   ! %s is a local kind context: the remote host cannot reach that API server\n' "$ctx"
                    printf '     unless it is exposed. Move the shell/build panes, keep the cluster tabs here.\n' ;;
                *) printf '     %s move %s %s --attach\n' "${0##*/}" "$name" "$hname" ;;
            esac
        else
            printf '   → no candidate host (inventory: %s) — nothing reachable with zellij and %s MiB free\n' \
                "$hosts_file" "$rss"
        fi
    done <<<"$rows"
    [ "$any" = true ] || die "no such session '$want'"
}

host_target() { # name -> ssh target
    jq -r --arg n "$1" '.hosts[] | select(.name == $n or .ssh == $n) | .ssh' <(hosts_inventory) | head -1
}

# Relocate a viewpoint: push this script and a layout rendered against the
# remote copy's path, create the session there, and hand back the attach
# command. The local session is left alone unless --kill-local says otherwise,
# because "move" that destroys the thing you were looking at before you have
# confirmed the remote one is wrong.
cmd_move() { # session host [--attach] [--kill-local]
    local session=${1:-} host=${2:-} attach=false kill_local=false a
    [ -n "$session" ] && [ -n "$host" ] || die "usage: zj.sh move <session> <host> [--attach] [--kill-local]"
    shift 2
    for a in "$@"; do case "$a" in --attach) attach=true ;; --kill-local) kill_local=true ;; *) die "unknown flag $a" ;; esac; done

    local target; target=$(host_target "$host")
    [ -n "$target" ] || die "host '$host' is not in $hosts_file"

    local ctx; ctx=$(session_meta "$session" context)
    [ -n "$ctx" ] || ctx=$(kctx "")

    # One round trip for the remote HOME: the layout has to name an absolute
    # path for the script its panes run and for the directory they start in,
    # and neither this checkout's path nor a tilde survives into zellij.
    local home remote_dir
    home=$(ssh "${ssh_opts[@]}" "$target" 'printf %s "$HOME"') || die "cannot reach $target"
    remote_dir="$home/.cache/zj-viewpoint"
    ssh "${ssh_opts[@]}" "$target" "mkdir -p '$remote_dir'"
    ssh "${ssh_opts[@]}" "$target" "command -v zellij >/dev/null" || die "$target has no zellij on PATH"
    if ! ssh "${ssh_opts[@]}" "$target" "kubectl config get-contexts -o name 2>/dev/null | grep -qx '$ctx'"; then
        printf 'zj: %s has no kube context %s — its cluster tabs will render errors\n' "$target" "$ctx" >&2
    fi

    ssh "${ssh_opts[@]}" "$target" "cat > '$remote_dir/zj.sh' && chmod +x '$remote_dir/zj.sh'" <"$self"
    ZJ_SELF="$remote_dir/zj.sh" ZJ_CWD="$home" "$self" layout "$ctx" \
        | ssh "${ssh_opts[@]}" "$target" "cat > '$remote_dir/$session.kdl'"

    # No remote session is pre-created: zellij only honours a layout at
    # creation time, so the attach command below is what brings it up (and
    # plain `attach` takes over on every later connection). The session then
    # outlives the ssh connection the way any zellij session outlives its
    # terminal, which is the whole point of putting it there.
    local attach_cmd
    attach_cmd="zellij attach '$session' 2>/dev/null || zellij --session '$session' --new-session-with-layout '$remote_dir/$session.kdl'"

    session_meta_write "$session" "$ctx" "$host"
    if [ "$kill_local" = true ]; then
        zellij kill-session "$session" >/dev/null 2>&1 || true
        printf 'zj: local %s killed\n' "$session" >&2
    fi
    printf 'zj: %s provisioned on %s (%s)\n' "$session" "$host" "$target" >&2
    if [ "$attach" = true ]; then exec ssh -t "$target" "$attach_cmd"; fi
    printf "ssh -t %s \"%s\"\n" "$target" "$attach_cmd"
}

cmd_attach() { # session [host]
    local session=${1:-} host=${2:-}
    [ -n "$session" ] || die "usage: zj.sh attach <session> [host]"
    [ -n "$host" ] || host=$(session_meta "$session" host)
    if [ -z "$host" ] || [ "$host" = local ]; then exec zellij attach "$session"; fi
    local target; target=$(host_target "$host")
    [ -n "$target" ] || die "host '$host' is not in $hosts_file"
    # A viewpoint that was moved and later killed (reboot, `zellij ka`) is
    # rebuilt from the layout `move` left on that host rather than coming back
    # as a bare shell.
    exec ssh -t "$target" "zellij attach '$session' 2>/dev/null || \
        zellij --session '$session' --new-session-with-layout \"\$HOME/.cache/zj-viewpoint/$session.kdl\""
}

main() {
    local cmd=${1:-up}; shift || true
    case "$cmd" in
        probe)  probe_json "$(kctx "${1:-}")" ;;
        layout) layout "$(kctx "${1:-}")" ;;
        up)     cmd_up "$@" ;;
        view)   view "${1:?view name}" "${2:-}" ;;
        ls)     cmd_ls "$@" ;;
        advise) cmd_advise "$@" ;;
        hosts)  cmd_hosts "$@" ;;
        move)   cmd_move "$@" ;;
        attach) cmd_attach "$@" ;;
        -h|--help|help) usage ;;
        *) die "unknown command '$cmd' (try --help)" ;;
    esac
}

main "$@"
