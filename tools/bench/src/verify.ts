/**
 * End-to-end check of the benchmark report in a real browser.
 *
 *   node tools/bench/src/verify.ts [--out tools/bench/out] [--no-gate]
 *
 * The report is a static file with no client-side code, so what is verified is
 * that the *rendered* document actually says what `results.json` measured: the
 * tables the reader will look at are complete, the numbers in them match the
 * data, the charts have a bar per measured cell, and no runtime silently
 * diverged from the reference. A full-page screenshot is left next to the
 * report as the visual artefact.
 */
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import puppeteer from 'puppeteer';
import type { Results } from './results.ts';

const { values } = parseArgs({
  options: {
    out: { type: 'string', default: 'tools/bench/out' },
    'no-gate': { type: 'boolean', default: false },
  },
});

const outDir = resolve(process.cwd(), values.out!);
const reportPath = join(outDir, 'report.html');
if (!existsSync(reportPath)) {
  console.error(`No report at ${reportPath}. Run \`just bench\` first.`);
  process.exit(1);
}

const failures: string[] = [];
function expect(condition: boolean, message: string): void {
  if (!condition) failures.push(message);
}

const browser = await puppeteer.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 1000, deviceScaleFactor: 2 });
  page.on('pageerror', (err) => failures.push(`page error: ${String(err)}`));
  await page.goto(`file://${reportPath}`, { waitUntil: 'load' });

  const raw = await page.$eval('script#data', (el) => el.textContent ?? '');
  const data = JSON.parse(raw) as Results;
  expect(data.cells.length > 0, 'report embeds no measured cells');

  // 1. Every measured cell is a row, and its p50/p95 render the measured value.
  const rows = await page.$$eval('table#latency tbody tr', (trs) =>
    trs.map((tr) => ({
      runtime: tr.getAttribute('data-runtime') ?? '',
      scenario: tr.getAttribute('data-scenario') ?? '',
      phase: tr.getAttribute('data-phase') ?? '',
      p50: tr.querySelector('td.p50')?.textContent?.trim() ?? '',
      p95: tr.querySelector('td.p95')?.textContent?.trim() ?? '',
    }))
  );
  expect(
    rows.length === data.cells.length,
    `latency table has ${rows.length} rows, expected ${data.cells.length}`
  );
  for (const cell of data.cells) {
    const row = rows.find(
      (r) => r.runtime === cell.runtime && r.scenario === cell.scenario && r.phase === cell.phase
    );
    if (!row) {
      failures.push(`no latency row for ${cell.runtime}/${cell.scenario}/${cell.phase}`);
      continue;
    }
    const label = `${cell.runtime}/${cell.scenario}/${cell.phase}`;
    expect(row.p50 === cell.latency.p50.toFixed(2), `${label}: p50 renders ${row.p50}, data says ${cell.latency.p50.toFixed(2)}`);
    expect(row.p95 === cell.latency.p95.toFixed(2), `${label}: p95 renders ${row.p95}, data says ${cell.latency.p95.toFixed(2)}`);
  }

  // 2. One resource-footprint row per runtime, with a cold start on it.
  const footprint = await page.$$eval('table#resources tbody tr', (trs) =>
    trs.map((tr) => ({
      runtime: tr.getAttribute('data-runtime') ?? '',
      cells: [...tr.querySelectorAll('td')].map((td) => td.textContent?.trim() ?? ''),
    }))
  );
  expect(
    footprint.length === data.runtimes.length,
    `resources table has ${footprint.length} rows, expected ${data.runtimes.length}`
  );
  for (const rt of data.runtimes) {
    const row = footprint.find((r) => r.runtime === rt.id);
    if (!row) {
      failures.push(`no resources row for ${rt.id}`);
      continue;
    }
    expect(row.cells[4] === rt.coldStartMs.toFixed(0), `${rt.id}: cold start renders ${row.cells[4]}, data says ${rt.coldStartMs.toFixed(0)}`);
  }

  // 3. Composed-resource grid: every measured cell carries a verdict, and no
  //    non-reference runtime diverges from the reference desired state.
  const composed = await page.$$eval('table#composed tbody tr', (trs) =>
    trs.map((tr) => ({
      runtime: tr.getAttribute('data-runtime') ?? '',
      scenario: tr.getAttribute('data-scenario') ?? '',
      phase: tr.getAttribute('data-phase') ?? '',
      na: tr.getAttribute('data-na') === '1',
      verdict: tr.querySelector('td.eq')?.textContent?.trim() ?? '',
      count: tr.querySelector('td.num')?.textContent?.trim() ?? '',
    }))
  );
  for (const cell of data.cells) {
    const row = composed.find(
      (r) => r.runtime === cell.runtime && r.scenario === cell.scenario && r.phase === cell.phase
    );
    const label = `${cell.runtime}/${cell.scenario}/${cell.phase}`;
    if (!row || row.na) {
      failures.push(`composed table has no measured row for ${label}`);
      continue;
    }
    expect(row.count === String(cell.resourceCount), `${label}: composed count renders ${row.count}, data says ${cell.resourceCount}`);
    const expected =
      cell.runtime === data.meta.reference
        ? 'reference'
        : !cell.equivalence
          ? 'not compared'
          : cell.equivalence.identical
            ? 'identical'
            : cell.equivalence.benign
              ? 'equivalent'
              : `${cell.equivalence.lines} lines differ`;
    expect(row.verdict.startsWith(expected), `${label}: verdict renders "${row.verdict}", expected "${expected}"`);
    if (!values['no-gate'] && cell.equivalence) {
      expect(
        cell.equivalence.identical || cell.equivalence.benign,
        `${label}: does not reproduce ${data.meta.reference}'s desired state`
      );
    }
  }
  const naRows = composed.filter((r) => r.na);
  for (const row of naRows) {
    expect(
      !data.cells.some(
        (c) => c.runtime === row.runtime && c.scenario === row.scenario && c.phase === row.phase
      ),
      `${row.runtime}/${row.scenario}/${row.phase} renders n/a but was measured`
    );
  }

  // 4. Charts: a bar per first-reconcile cell, in both percentile charts.
  const initial = data.cells.filter((c) => c.phase === 'initial').length;
  for (const id of ['chart-p50', 'chart-p95']) {
    const bars = await page.$$eval(`#${id} rect`, (els) => els.length);
    expect(bars === initial, `#${id} has ${bars} bars, expected ${initial}`);
  }

  const screenshot = join(outDir, 'report.png');
  await page.screenshot({ path: screenshot, fullPage: true });

  if (failures.length) {
    console.error(`verify: ${failures.length} failure(s)`);
    for (const failure of failures) console.error(`  - ${failure}`);
    process.exitCode = 1;
  } else {
    console.log(
      `verify: ok (${rows.length} rows, ${footprint.length} runtimes, ${initial} bars per chart) ` +
        `screenshot ${join(values.out!, 'report.png')}`
    );
  }
} finally {
  await browser.close();
}
