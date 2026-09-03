/**
 * Self-contained HTML report: inline CSS, server-rendered SVG charts, no
 * external assets and no client-side libraries, so the file can be opened from
 * disk (which is exactly what `verify.ts` does with puppeteer).
 *
 * The DOM ids and `data-*` attributes here are a contract with `verify.ts`:
 * `#meta`, `table#latency`, `table#resources`, `table#composed`, `#chart-p50`,
 * `#chart-p95` and `script#data`.
 */
import { PHASES } from './scenarios.ts';
import type { Phase, RuntimeId } from './scenarios.ts';
import type { Cell, Results } from './results.ts';

const RUNTIME_COLOUR: Record<string, string> = {
  kcl: '#2f6feb',
  kclx: '#d1793c',
  python: '#3f9d5a',
};

function esc(value: unknown): string {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

const ms = (value: number) => value.toFixed(2);

function cellOf(results: Results, runtime: RuntimeId, scenario: string, phase: Phase): Cell | undefined {
  return results.cells.find(
    (c) => c.runtime === runtime && c.scenario === scenario && c.phase === phase
  );
}

function latencyRows(results: Results): string {
  return results.cells
    .map((cell) => {
      const attrs = `data-runtime="${cell.runtime}" data-scenario="${esc(cell.scenario)}" data-phase="${cell.phase}"`;
      return `<tr ${attrs}>
        <td class="rt"><span class="dot" style="background:${RUNTIME_COLOUR[cell.runtime]}"></span>${cell.runtime}</td>
        <td>${esc(cell.scenario)}</td>
        <td>${cell.phase}</td>
        <td class="num">${cell.latency.n}</td>
        <td class="num p50">${ms(cell.latency.p50)}</td>
        <td class="num p95">${ms(cell.latency.p95)}</td>
        <td class="num">${ms(cell.latency.p99)}</td>
        <td class="num">${ms(cell.latency.mean)}</td>
        <td class="num">${ms(cell.latency.min)}</td>
        <td class="num">${ms(cell.latency.max)}</td>
        <td class="num">${cell.firstCallMs.toFixed(0)}</td>
        <td class="num">${cell.latency.rps.toFixed(1)}</td>
      </tr>`;
    })
    .join('\n');
}

function resourceRows(results: Results): string {
  return results.runtimes
    .map((rt) => {
      const mib = (bytes: number) => (bytes / 1024 ** 2).toFixed(1);
      return `<tr data-runtime="${rt.id}">
        <td class="rt"><span class="dot" style="background:${RUNTIME_COLOUR[rt.id]}"></span>${rt.id}</td>
        <td class="mono">${esc(rt.image)}</td>
        <td>${esc(rt.platform)}${rt.emulated ? ' <span class="warn">emulated</span>' : ''}</td>
        <td class="num">${rt.imageBytes === null ? 'n/a' : (rt.imageBytes / 1024 ** 2).toFixed(0)}</td>
        <td class="num">${rt.coldStartMs.toFixed(0)}</td>
        <td class="num">${mib(rt.stats.memAvgBytes)}</td>
        <td class="num">${mib(rt.stats.memPeakBytes)}</td>
        <td class="num">${rt.stats.cpuAvgPercent.toFixed(0)}</td>
        <td class="num">${rt.stats.cpuPeakPercent.toFixed(0)}</td>
        <td class="num">${rt.stats.pidsPeak}</td>
        <td class="num">${rt.stats.samples}</td>
      </tr>`;
    })
    .join('\n');
}

/** Full runtime x scenario x phase grid, so a missing combination is visible. */
function composedRows(results: Results): string {
  const rows: string[] = [];
  for (const rt of results.runtimes) {
    for (const scenario of results.meta.scenarios) {
      for (const phase of PHASES) {
        const cell = cellOf(results, rt.id, scenario.id, phase);
        const attrs = `data-runtime="${rt.id}" data-scenario="${esc(scenario.id)}" data-phase="${phase}"`;
        if (!cell) {
          const why =
            rt.id === 'python' && !scenario.pythonScript
              ? 'no python port of this Composition'
              : 'not measured in this run';
          rows.push(`<tr ${attrs} data-na="1">
            <td class="rt"><span class="dot" style="background:${RUNTIME_COLOUR[rt.id]}"></span>${rt.id}</td>
            <td>${esc(scenario.id)}</td><td>${phase}</td>
            <td class="na" colspan="6">n/a — ${esc(why)}</td>
          </tr>`);
          continue;
        }
        const eq = cell.equivalence;
        const verdict =
          rt.id === results.meta.reference
            ? '<span class="ref">reference</span>'
            : !eq
              ? '<span class="ref">not compared</span>'
              : eq.identical
                ? '<span class="ok">identical</span>'
                : eq.benign
                  ? `<span class="meh">equivalent</span> <span class="small">(${eq.lines} lines)</span>`
                  : `<span class="bad">${eq.lines} lines differ</span>`;
        const diff =
          eq && !eq.identical
            ? `<details><summary>diff${eq.note ? ` — ${esc(eq.note)}` : ''}</summary><pre>${esc(eq.diff)}</pre></details>`
            : '';
        const worst = cell.results.map((r) => r.severity ?? 'SEVERITY_UNSPECIFIED');
        rows.push(`<tr ${attrs}>
          <td class="rt"><span class="dot" style="background:${RUNTIME_COLOUR[rt.id]}"></span>${rt.id}</td>
          <td>${esc(scenario.id)}</td>
          <td>${phase}</td>
          <td class="num">${cell.resourceCount}</td>
          <td class="mono small">${esc(cell.resourceNames.join(', '))}</td>
          <td class="mono small">${esc(cell.ready.join(', '))}</td>
          <td class="mono small">${cell.statusKeys.length ? esc(cell.statusKeys.join(', ')) : '—'}</td>
          <td class="mono small">${worst.length ? esc(worst.join(', ')) : '—'}</td>
          <td class="eq">${verdict}${diff}</td>
        </tr>`);
      }
    }
  }
  return rows.join('\n');
}

/**
 * Horizontal bar chart of one latency percentile for the first-reconcile phase.
 * Rendered as SVG at build time: the report has to work as a static file.
 */
function chart(id: string, title: string, results: Results, pick: (cell: Cell) => number): string {
  const cells = results.cells.filter((c) => c.phase === 'initial');
  const max = Math.max(0.0001, ...cells.map(pick));
  const rowHeight = 26;
  const labelWidth = 260;
  const barWidth = 520;
  const height = cells.length * rowHeight + 34;
  const bars = cells
    .map((cell, i) => {
      const value = pick(cell);
      const width = Math.max(1, (value / max) * barWidth);
      const y = 24 + i * rowHeight;
      return `<rect x="${labelWidth}" y="${y}" width="${width.toFixed(1)}" height="16" rx="3"
          fill="${RUNTIME_COLOUR[cell.runtime]}" data-runtime="${cell.runtime}" data-scenario="${esc(cell.scenario)}"></rect>
        <text x="${labelWidth - 8}" y="${y + 12}" text-anchor="end" class="cl">${cell.runtime} · ${esc(cell.scenario)}</text>
        <text x="${labelWidth + width + 6}" y="${y + 12}" class="cv">${ms(value)} ms</text>`;
    })
    .join('\n');
  return `<svg id="${id}" viewBox="0 0 ${labelWidth + barWidth + 90} ${height}" width="100%" role="img" aria-label="${esc(title)}">
      <text x="0" y="12" class="ct">${esc(title)}</text>
      ${bars}
    </svg>`;
}

export function renderHtml(results: Results): string {
  const { meta } = results;
  // The embedded copy drops per-cell canonical desired state (it is large and
  // already in results.json); everything the verifier asserts on stays.
  const embedded = {
    ...results,
    cells: results.cells.map(({ canonical: _canonical, ...rest }) => rest),
  };
  const identical = results.cells.filter((c) => c.equivalence?.identical).length;
  const equivalent = results.cells.filter((c) => c.equivalence?.benign).length;
  const divergent = results.cells.filter(
    (c) => c.equivalence && !c.equivalence.identical && !c.equivalence.benign
  ).length;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Crossplane composition-function benchmark — KCL vs Python</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; margin: 0 auto; max-width: 1180px; padding: 24px; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  h2 { font-size: 16px; margin: 32px 0 8px; }
  p.lede, p.note { color: #666; margin: 4px 0 0; }
  table { border-collapse: collapse; width: 100%; margin-top: 8px; }
  th, td { border-bottom: 1px solid #e3e3e3; padding: 5px 8px; text-align: left; vertical-align: top; }
  th { background: #f6f6f6; font-weight: 600; white-space: nowrap; }
  td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
  .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  .small { font-size: 12px; }
  .rt { white-space: nowrap; font-weight: 600; }
  .dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 6px; }
  .ok { color: #1a7f37; font-weight: 600; }
  .meh { color: #8a6d00; font-weight: 600; }
  .bad { color: #b3261e; font-weight: 600; }
  .ref { color: #666; }
  .warn { color: #b3261e; font-size: 12px; }
  .na { color: #999; font-style: italic; }
  pre { background: #f6f6f6; padding: 8px; overflow: auto; max-height: 340px; font-size: 12px; }
  dl#meta { display: grid; grid-template-columns: max-content 1fr; gap: 2px 14px; margin: 12px 0 0; }
  dl#meta dt { color: #666; }
  dl#meta dd { margin: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  text.ct { font-size: 13px; font-weight: 600; fill: currentColor; }
  text.cl { font-size: 11px; fill: currentColor; }
  text.cv { font-size: 11px; fill: #666; }
  svg { margin-top: 8px; }
  @media (prefers-color-scheme: dark) {
    th { background: #1d1d1d; } th, td { border-color: #333; }
    pre { background: #1d1d1d; } p.lede, p.note, dl#meta dt, text.cv { color: #aaa; }
  }
</style>
</head>
<body>
<h1>Crossplane composition-function benchmark</h1>
<p class="lede">Upstream <code>function-kcl</code>, this repo's Rust <code>kclx</code>, and
<code>function-python</code> rendering the same Compositions over gRPC
<code>RunFunction</code>. Latency excludes the CLI: the harness dials the function directly.
<strong>${esc(meta.reference)}</strong> is the behavioural reference.</p>

<h2>Run</h2>
<dl id="meta">
  <dt>started</dt><dd>${esc(meta.startedAt)}</dd>
  <dt>commit</dt><dd>${esc(meta.gitSha)}</dd>
  <dt>host</dt><dd>${esc(meta.cpu)} · ${meta.cores} cores · ${meta.memGb} GB · ${esc(meta.hostPlatform)}</dd>
  <dt>node / docker</dt><dd>${esc(meta.node)} / ${esc(meta.docker)}</dd>
  <dt>iterations</dt><dd>${meta.iterations} measured, ${meta.warmup} warmup, per runtime × scenario × phase</dd>
  <dt>scenarios</dt><dd>${meta.scenarios.map((s) => `${esc(s.id)} (${esc(s.kclPackage)})`).join('<br>')}</dd>
  <dt>equivalence</dt><dd>${identical} identical, ${equivalent} equivalent, ${divergent} divergent vs ${esc(meta.reference)}</dd>
</dl>

<h2>Latency</h2>
<p class="note">Serial unary calls, milliseconds. <code>first</code> is the very first call of the
cell — module load plus, for the KCL runtimes, dependency resolution — and is not in the loop.</p>
${chart('chart-p50', 'p50 latency, first reconcile (lower is better)', results, (c) => c.latency.p50)}
${chart('chart-p95', 'p95 latency, first reconcile (lower is better)', results, (c) => c.latency.p95)}
<table id="latency">
<thead><tr>
  <th>runtime</th><th>scenario</th><th>phase</th><th class="num">n</th>
  <th class="num">p50</th><th class="num">p95</th><th class="num">p99</th>
  <th class="num">mean</th><th class="num">min</th><th class="num">max</th>
  <th class="num">first</th><th class="num">req/s</th>
</tr></thead>
<tbody>
${latencyRows(results)}
</tbody>
</table>

<h2>Resource footprint</h2>
<p class="note">Image size from <code>docker image inspect</code>; cold start is
<code>docker run</code> until the function answers gRPC. Memory and CPU are
<code>docker stats</code> streamed during the measured loops — docker emits roughly one row per
second, so a runtime whose loops finish inside a single tick falls back to one blocking snapshot
taken warm and idle (see the <code>samples</code> column).</p>
<table id="resources">
<thead><tr>
  <th>runtime</th><th>image</th><th>platform</th><th class="num">image MB</th>
  <th class="num">cold start ms</th><th class="num">mem avg MiB</th><th class="num">mem peak MiB</th>
  <th class="num">cpu avg %</th><th class="num">cpu peak %</th><th class="num">pids</th>
  <th class="num">samples</th>
</tr></thead>
<tbody>
${resourceRows(results)}
</tbody>
</table>

<h2>Composed resources</h2>
<p class="note">What each runtime actually asked Crossplane to create. <code>phase=initial</code> is a
first reconcile with no observed composed state; <code>phase=observed</code> feeds the composed
resources back with provider status attached, which is the path the Composition's status plumbing
runs on. <em>identical</em> means the key-sorted desired state matches
<code>${esc(meta.reference)}</code> byte for byte; <em>equivalent</em> means the only difference is
metadata bookkeeping the API server treats as absent (kclx drops the
<code>metadata.annotations</code> map that function-kcl leaves empty after consuming its naming
annotation). Anything else is a real divergence and fails the run.</p>
<table id="composed">
<thead><tr>
  <th>runtime</th><th>scenario</th><th>phase</th><th class="num">count</th>
  <th>resource names</th><th>ready</th><th>XR status keys</th><th>results</th><th>vs ${esc(meta.reference)}</th>
</tr></thead>
<tbody>
${composedRows(results)}
</tbody>
</table>

<h2>Raw data</h2>
<p class="note">Embedded below as JSON (<code>script#data</code>); the full copy including every
runtime's canonicalised desired state is in <code>results.json</code> next to this file.</p>
<script type="application/json" id="data">${JSON.stringify(embedded).replaceAll('<', '\\u003c')}</script>
</body>
</html>
`;
}
