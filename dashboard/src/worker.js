// PRL fleet dashboard: a Cloudflare Worker that reads the Axiom dataset the
// fleet already writes to (container logs + Kryptex records) and serves
//   GET /           the dashboard page (index.html, refreshes every 30 s)
//   GET /api/fleet  JSON the page draws from
// Axiom stays the data store; this Worker stores nothing. The query token
// (read-only, AXIOM_QUERY_TOKEN secret) never leaves the Worker.
//
// Caching: the "live" queries run at most every 30 s and the 24 h "slow"
// ones every 5 min, however many tabs are open (Cache API, per data center).
//
// Settings: AXIOM_QUERY_TOKEN (secret), AXIOM_DATASET (default salad-prl).
// Access control is Cloudflare Access on the workers.dev hostname.

import QUERIES from './queries.json';
import PAGE from './index.html';
import { toRows, buildFleet } from './fleet.js';

const LIVE_TTL = 30;
const SLOW_TTL = 300;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/api/fleet') {
      try {
        const data = await getFleet(env, ctx, url);
        return json(data, 200);
      } catch (e) {
        return json({ error: String((e && e.message) || e) }, 502);
      }
    }
    if (url.pathname === '/' || url.pathname === '/index.html') {
      return new Response(PAGE, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });
    }
    return new Response('not found\n', { status: 404 });
  },
};

function json(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' } });
}

// ---- Axiom -------------------------------------------------------------------
async function runQuery(env, q, now) {
  const ds = env.AXIOM_DATASET || 'salad-prl';
  const body = {
    apl: q.apl.replaceAll('{DS}', ds),
    startTime: new Date(now - (q.minutes + 1) * 60000).toISOString(),
    endTime: new Date(now + 60000).toISOString(),
  };
  const res = await fetch('https://api.axiom.co/v1/datasets/_apl?format=tabular', {
    method: 'POST',
    headers: { authorization: `Bearer ${env.AXIOM_QUERY_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Axiom HTTP ${res.status}: ${text.slice(0, 200)}`);
  return toRows(JSON.parse(text));
}

async function runTier(env, tier, now) {
  const names = Object.keys(QUERIES[tier]);
  const results = await Promise.all(names.map(k => runQuery(env, QUERIES[tier][k], now)));
  const out = {};
  names.forEach((k, i) => { out[k] = results[i]; });
  return out;
}

// Cache API keyed by a synthetic URL per tier.
async function cached(ctx, key, ttl, produce) {
  const cache = caches.default;
  const req = new Request(`https://prl-dashboard.cache/${key}`);
  const hit = await cache.match(req);
  if (hit) return hit.json();
  const value = await produce();
  const res = new Response(JSON.stringify(value), { headers: { 'content-type': 'application/json', 'cache-control': `max-age=${ttl}` } });
  ctx.waitUntil(cache.put(req, res));
  return value;
}

async function getFleet(env, ctx, url) {
  if (!env.AXIOM_QUERY_TOKEN) throw new Error('AXIOM_QUERY_TOKEN secret is not set');
  const now = Date.now();
  const fresh = url.searchParams.get('fresh') === '1';
  const live = fresh ? await runTier(env, 'live', now) : await cached(ctx, 'live', LIVE_TTL, () => runTier(env, 'live', now));
  const slow = await cached(ctx, 'slow', SLOW_TTL, () => runTier(env, 'slow', now));
  return buildFleet({ ...live, ...slow }, now);
}
