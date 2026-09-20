/**
 * Count decisions at this repository's classification call sites.
 *
 * DATED MEASUREMENT -- NOT A FEATURE.
 * Added 2026-09-20 for the Jev investigation's open question B1: every
 * decision volume in that analysis is configured capacity rather than observed
 * traffic, and a 10x error either way rewrites its conclusions.
 *
 * REMOVE ON OR AFTER 2026-10-04. Removal is one revert: delete this file and
 * the `countDecision(...)` calls marked `JEV B1`. Nothing else reads it.
 *
 * A counter observes; it never decides. Counts are kept in memory and written
 * in batches, so the polling loops that call it pay a Map lookup rather than a
 * file write per decision, and every path is wrapped so no failure here can
 * change a verdict or throw into the caller. Records are appended to a local
 * file and are never sent anywhere.
 */
import * as fs from 'node:fs';

const MEASUREMENT = 'jev-b1';
/** Write out at least this often, so a killed process loses little. */
const FLUSH_EVERY = 100;
/**
 * Also write out on a timer. An exit handler alone is not enough: a first run
 * under `bun test` reached both call sites and wrote nothing, because the test
 * runner's exit path never ran the handler. The timer is unref'd, so it never
 * holds a process open on its own.
 */
const FLUSH_INTERVAL_MS = 5_000;

/** `site outcome kind hour` -> count. One entry per bucket, not per decision. */
const counts = new Map<string, number>();
let sinceFlush = 0;
let registered = false;

/** UTC hour bucket, so cadence is visible without storing exact times. */
function hourBucket(): string {
  return `${new Date().toISOString().slice(0, 13)}Z`;
}

/**
 * Record one decision.
 *
 * @param site    the call site, stable across the measurement
 * @param outcome which label was chosen
 * @param kind    where it landed: `label` (a real choice), `human` (fell
 *                through to a person), `unknown` (fell through to an unknown
 *                bucket) or `default` (fell through to a default)
 */
export function countDecision(
  site: string,
  outcome: string,
  kind: 'label' | 'human' | 'unknown' | 'default',
): void {
  try {
    const key = `${site} ${outcome} ${kind} ${hourBucket()}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
    if (!registered) {
      registered = true;
      process.once('exit', flushDecisionCounts);
      process.once('beforeExit', flushDecisionCounts);
      setInterval(flushDecisionCounts, FLUSH_INTERVAL_MS).unref?.();
    }
    if (++sinceFlush >= FLUSH_EVERY) flushDecisionCounts();
  } catch {
    /* a counter never throws into a caller */
  }
}

/** Append what is held in memory. Safe to call at any time, including twice. */
export function flushDecisionCounts(): void {
  try {
    if (counts.size === 0) return;
    const dir = `${process.env.GSTACK_HOME ?? `${process.env.HOME}/.gstack`}/analytics`;
    fs.mkdirSync(dir, { recursive: true });
    let out = '';
    for (const [key, n] of counts) {
      const [site, outcome, kind, hour] = key.split(' ');
      out += `${JSON.stringify({ m: MEASUREMENT, site, hour, outcome, kind, n })}\n`;
    }
    counts.clear();
    sinceFlush = 0;
    fs.appendFileSync(`${dir}/jev-b1-counts.jsonl`, out);
  } catch {
    /* best-effort */
  }
}
