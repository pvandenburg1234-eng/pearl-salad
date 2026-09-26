// Node test for the dashboard (run by .github/workflows/dashboard.yml):
// buildFleet() on rows captured from Axiom (test/fixture.json), plus a parse
// check of the page's inline script. No network.
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { buildFleet, gpuName, toRows, shareRates } from '../src/fleet.js';

const here = new URL('.', import.meta.url);
const fixture = JSON.parse(readFileSync(new URL('fixture.json', here), 'utf8'));
const now = Date.parse(fixture.captured);
const d = buildFleet(fixture, now);

// fleet
assert.ok(d.fleet.activeWorkers > 0, 'no active workers');
assert.equal(d.workers.length, d.fleet.activeWorkers);
const sum = Math.round(d.workers.reduce((s, w) => s + (w.avg || 0), 0) * 10) / 10;
assert.ok(Math.abs(sum - d.fleet.ths) < 0.5, `fleet TH/s ${d.fleet.ths} != sum of worker averages ${sum}`);
assert.equal(d.fleet.gpuMix.reduce((s, m) => s + m.n, 0), d.fleet.activeWorkers, 'GPU mix does not add up');
for (const w of d.workers) {
  assert.ok(w.nAvg <= 5, `${w.machine} averaged ${w.nAvg} readings`);
  assert.ok(w.ageS !== null && w.ageS < 600, `${w.machine} is not active (age ${w.ageS})`);
  assert.equal(w.machine.length, 8);
}
for (let i = 1; i < d.workers.length; i++) assert.ok((d.workers[i - 1].avg ?? -1) >= (d.workers[i].avg ?? -1), 'workers not sorted by avg');

// kryptex, trends, events
assert.ok(d.kryptex && typeof d.kryptex.total === 'number', 'no Kryptex balance');
assert.ok(d.trend.fleet.length > 10 && d.trend.pool.length > 10, 'trend series too short');
assert.ok(d.events.length > 0 && !d.events[0].msg.startsWith('==='), 'events not cleaned');

// shares: most active workers have a measured time per share, near the expected one
const withShares = d.workers.filter(w => w.shares && w.shares.secPerShare);
assert.ok(withShares.length >= d.workers.length / 2, `only ${withShares.length}/${d.workers.length} workers have share rates`);
for (const w of withShares) {
  assert.ok(w.shares.secPerShare > 5 && w.shares.secPerShare < 3600, `${w.machine} ${w.shares.secPerShare} s/share out of range`);
  if (w.shares.expectedSec) assert.ok(w.shares.expectedSec > 5 && w.shares.expectedSec < 3600, `${w.machine} expected ${w.shares.expectedSec}`);
}
assert.ok(d.fleet.sharesPerHour > 0, 'no fleet share rate');
// counter reset (miner restart) only counts after the reset; SRB-style one line per share
const t0 = Date.parse('2026-09-26T20:00:00Z'), min = 60000;
const iso = t => new Date(t).toISOString();
const r1 = shareRates([
  { _time: iso(t0), m: 'a', cnt: 100, acc: 0 }, { _time: iso(t0 + 5 * min), m: 'a', cnt: 104, acc: 0 },
  { _time: iso(t0 + 6 * min), m: 'a', cnt: 0, acc: 0 }, { _time: iso(t0 + 16 * min), m: 'a', cnt: 10, acc: 0 },
  ...[0, 2, 4, 6, 8, 10].map(k => ({ _time: iso(t0 + k * min), m: 'b', cnt: null, acc: 1 })),
], [{ m: 'a', diff: 9.01 }]).get('a');
assert.equal(r1.shares, 10); assert.equal(r1.secPerShare, 60); assert.equal(r1.diffP, 9.01);
const r2 = shareRates([...[0, 2, 4, 6, 8, 10].map(k => ({ _time: iso(t0 + k * min), m: 'b', cnt: null, acc: 1 }))], []).get('b');
assert.equal(r2.shares, 5); assert.equal(r2.secPerShare, 120);

// helpers
assert.equal(gpuName('gfx1201'), 'RX 9070 XT');
assert.equal(gpuName('RTX 5070 Ti Laptop...'), 'RTX 5070 Ti Laptop');
assert.equal(gpuName('NVIDIA GeForce RTX 5070 Ti Laptop GPU'), 'RTX 5070 Ti Laptop');
assert.deepEqual(toRows({ tables: [{ fields: [{ name: 'a' }, { name: 'b' }], columns: [[1, 2], ['x', 'y']] }] }), [{ a: 1, b: 'x' }, { a: 2, b: 'y' }]);

// the page's inline script must at least parse
const html = readFileSync(new URL('../src/index.html', here), 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
assert.equal(scripts.length, 1, 'expected one inline script');
new Function(scripts[0]);

console.log(`OK: ${d.fleet.activeWorkers} active workers, ${d.fleet.ths} TH/s, GPU mix ${d.fleet.gpuMix.map(m => `${m.gpu} (${m.n})`).join(', ')}, ` +
  `$${d.fleet.costPerHour}/h, earned 24h ${d.kryptex.earned24h} PRL, ${d.trend.fleet.length} trend points, ${d.events.length} events`);
console.log('slowest:', d.workers.slice(-3).map(w => `${w.machine} ${w.avg}`).join(', '));
console.log(`shares: fleet ${d.fleet.sharesPerHour}/h; per worker s/share (expected):`, d.workers.map(w => `${w.machine} ${w.shares ? w.shares.secPerShare : '-'} (${w.shares ? w.shares.expectedSec : '-'})`).join(', '));
