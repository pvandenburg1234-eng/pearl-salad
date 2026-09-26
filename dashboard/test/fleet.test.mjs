// Node test for the dashboard (run by .github/workflows/dashboard.yml):
// buildFleet() on rows captured from Axiom (test/fixture.json), plus a parse
// check of the page's inline script. No network.
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { buildFleet, gpuName, toRows } from '../src/fleet.js';

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
