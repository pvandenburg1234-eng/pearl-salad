// Pure functions for the PRL dashboard: Axiom rows -> page model. No I/O,
// so test/fleet.test.mjs can run them on Node against a captured fixture.

const ACTIVE_MIN = 10;          // a worker is active if it logged within this many minutes
const AVG_READINGS = 5;         // columns = average of the latest N hashrate readings

// Lowest-priority price per hour by GPU class (Salad API "batch" tier, 26 Sep 2026).
const PRICE_PER_HOUR = {
  'RX 9070 XT': 0.07, 'RX 9060 XT': 0.049, 'RX 7900 XTX / XT': 0.066, 'RX 7800 XT': 0.042,
  'RTX 5070 Ti Laptop': 0.06, 'RTX 5080 Laptop': 0.08, 'RTX 5090 Laptop': 0.16,
};
const GFX_NAMES = { gfx1201: 'RX 9070 XT', gfx1200: 'RX 9060 XT', gfx1100: 'RX 7900 XTX / XT', gfx1101: 'RX 7800 XT' };

// Axiom tabular format: tables[0].fields[] + columns[][] -> array of row objects
export function toRows(resp) {
  const t = resp.tables && resp.tables[0];
  if (!t) return [];
  const names = t.fields.map(f => f.name);
  const n = t.columns.length ? t.columns[0].length : 0;
  const rows = [];
  for (let i = 0; i < n; i++) {
    const o = {};
    names.forEach((k, j) => { o[k] = t.columns[j][i]; });
    rows.push(o);
  }
  return rows;
}

function ms(v) {
  // _time comes back as an ISO string, max(_time) as epoch nanoseconds
  if (typeof v === 'number') return v > 1e15 ? Math.round(v / 1e6) : v;
  return Date.parse(v);
}

export function gpuName(raw) {
  if (!raw) return '';
  const r = String(raw).replace(/\.\.\.$/, '').trim();
  if (GFX_NAMES[r]) return GFX_NAMES[r];
  return r.replace(/^nvidia\s+(geforce\s+)?/i, '').replace(/\s+gpu$/i, '').replace(/\bGpu\b/, '').trim();
}

export function buildFleet(d, now) {
  const workers = new Map();
  const get = (m, g) => {
    if (!workers.has(m)) workers.set(m, { id: m, machine: m.slice(0, 8), group: g, readings: [], gpu: '', watts: null, temp: null, mhz: null, lastSeen: 0, lines: 0, version: '', shipping: '' });
    return workers.get(m);
  };
  for (const a of d.activity || []) {
    const w = get(a.m, a.g);
    w.lastSeen = ms(a.last);
    w.lines = a.lines;
    w.version = [].concat(a.ver || []).filter(Boolean).join(',');
    w.shipping = [].concat(a.via || []).filter(Boolean).join(',');
  }
  const readingRows = (d.readings || []).slice().sort((x, y) => ms(y._time) - ms(x._time));
  for (const r of readingRows) {
    const w = get(r.m, r.g);
    if (r.ths !== null && r.ths !== undefined) w.readings.push({ t: ms(r._time), ths: r.ths });
    if (!w.gpu && r.gpu) w.gpu = gpuName(r.gpu);
    if (w.watts === null && r.watts !== null && r.watts !== undefined) { w.watts = r.watts; w.temp = r.temp; w.mhz = r.mhz; }
    w.lastSeen = Math.max(w.lastSeen, ms(r._time));
  }
  const pool = new Map((d.pool_workers || []).map(p => [p.machine, p]));
  const shareStats = shareRates(d.shares || [], d.share_diff || []);

  const active = [];
  for (const w of workers.values()) {
    const lastN = w.readings.slice(0, AVG_READINGS);
    w.avg = lastN.length ? round1(lastN.reduce((s, r) => s + r.ths, 0) / lastN.length) : null;
    w.latest = w.readings.length ? w.readings[0].ths : null;
    w.nAvg = lastN.length;
    w.ageS = w.lastSeen ? Math.round((now - w.lastSeen) / 1000) : null;
    w.active = w.lastSeen > 0 && now - w.lastSeen < ACTIVE_MIN * 60000;
    const p = pool.get(w.machine);
    w.pool = p ? { ths30m: p.ths_30m, ths3h: p.ths_3h, ths24h: p.ths_24h, status: p.status, valid: p.valid, stale: p.stale } : null;
    w.pricePerHour = PRICE_PER_HOUR[w.gpu] ?? null;
    const s = shareStats.get(w.id);
    w.shares = s ? {
      ...s,
      // expected seconds per share = difficulty / hashrate (P = 1e15, TH/s = 1e12)
      expectedSec: s.diffP && w.avg ? round1(s.diffP * 1000 / w.avg) : null,
    } : null;
    delete w.readings;
    if (w.active) active.push(w);
  }
  active.sort((a, b) => (b.avg ?? -1) - (a.avg ?? -1));

  const gpuMix = {};
  for (const w of active) { const k = w.gpu || '(not reported yet)'; gpuMix[k] = (gpuMix[k] || 0) + 1; }
  const fleetThs = round1(active.reduce((s, w) => s + (w.avg || 0), 0));
  const costPerHour = round3(active.reduce((s, w) => s + (w.pricePerHour || 0), 0));

  const bal = [].concat(d.balance || [])[0] || null;
  const trend = (d.pool_trend || []).filter(r => r.total_prl !== null && r.total_prl !== undefined);
  const earned24h = trend.length > 1 && bal ? round3(bal.total_prl - trend[0].total_prl) : null;

  return {
    generated: new Date(now).toISOString(),
    fleet: {
      ths: fleetThs,
      activeWorkers: active.length,
      gpuMix: Object.entries(gpuMix).sort((a, b) => b[1] - a[1]).map(([gpu, n]) => ({ gpu, n })),
      costPerHour,
      avgReadings: AVG_READINGS,
      sharesPerHour: round1(active.reduce((s, w) => s + ((w.shares && w.shares.perHour) || 0), 0)),
    },
    kryptex: bal ? {
      at: bal._time, paid: bal.paid_prl, unpaid: bal.unpaid_prl, total: bal.total_prl, week: bal.reward_week_prl,
      earned24h, workersOnline: bal.workers_online, poolThs30m: bal.pool_ths_30m, netPhs: bal.net_hashrate_phs, blockReward: bal.block_reward_prl,
    } : null,
    workers: active,
    trend: {
      fleet: (d.fleet_trend || []).map(r => ({ t: r.t, ths: r.ths, workers: r.workers })),
      pool: trend.map(r => ({ t: r.t, ths: r.pool_ths_30m, online: r.workers_online })),
    },
    events: (d.events || []).map(e => ({ t: e._time, machine: String(e.m || '').slice(0, 8), group: e.g, msg: String(e.msg || '').replace(/^=== | ===$/g, '') })),
  };
}

// Accepted-share rate per worker over the last hour, from the miners' logs:
//   BzMiner / krig print a running total (cnt); a drop means the miner
//   restarted, so only the part after the last drop counts.
//   SRBMiner prints one "share accepted" line per share (acc = 1).
// secPerShare = time per accepted share; null when there is too little data.
const MIN_SPAN_S = 300;
export function shareRates(rows, diffRows) {
  const byM = new Map();
  for (const r of rows) {
    if (!byM.has(r.m)) byM.set(r.m, []);
    byM.get(r.m).push({ t: ms(r._time), cnt: r.cnt, acc: r.acc });
  }
  const diff = new Map(diffRows.map(r => [r.m, r.diff]));
  const out = new Map();
  for (const [m, pts] of byM) {
    pts.sort((a, b) => a.t - b.t);
    let shares = 0, span = 0;
    const counters = pts.filter(p => p.cnt !== null && p.cnt !== undefined);
    if (counters.length >= 2) {
      let start = 0;
      for (let i = 1; i < counters.length; i++) if (counters[i].cnt < counters[i - 1].cnt) start = i;
      const seg = counters.slice(start);
      if (seg.length >= 2) { shares = seg[seg.length - 1].cnt - seg[0].cnt; span = (seg[seg.length - 1].t - seg[0].t) / 1000; }
    } else {
      const acc = pts.filter(p => p.acc === 1);
      if (acc.length >= 2) { shares = acc.length - 1; span = (acc[acc.length - 1].t - acc[0].t) / 1000; }
    }
    if (span < MIN_SPAN_S) { out.set(m, { secPerShare: null, perHour: null, shares, spanMin: round1(span / 60), diffP: diff.get(m) ?? null }); continue; }
    out.set(m, {
      secPerShare: shares > 0 ? round1(span / shares) : null,
      perHour: round1(shares / span * 3600),
      shares,
      spanMin: round1(span / 60),
      diffP: diff.get(m) ?? null,
    });
  }
  return out;
}

function round1(x) { return Math.round(x * 10) / 10; }
function round3(x) { return Math.round(x * 1000) / 1000; }
