// Kryptex pool stats -> Axiom, as a Cloudflare Worker on a cron trigger.
//
// JavaScript port of tools/kryptex-collect.ps1 (same records, same fields),
// so it runs every few minutes on Cloudflare instead of on the user's PC or
// on GitHub's throttled cron. Single file, no build step: paste it into the
// Cloudflare dashboard editor (see README.md next to it).
//
// Sources (no login needed):
//   * https://pool.kryptex.com/prl/miner/stats/<wallet> - the page's Nuxt
//     payload (__NUXT_DATA__, devalue format) carries paid / unpaid /
//     reward.week / reward.month; there is no JSON endpoint for those
//   * https://pool.kryptex.com/prl/api/v3/miner/workers/<wallet> - per worker
//     30 min / 3 h / 24 h average hashrate, share counts, agent, status
//   * https://pool.kryptex.com/prl/api/v1/pool/stats - pool + network
//     hashrate, block reward
//
// Every record gets source="kryptex" (and collector="cf-worker") so the
// dashboard can tell them from the container log lines.
//
// Settings (Worker -> Settings -> Variables and Secrets):
//   AXIOM_INGEST_TOKEN  secret, required for the cron run (ingest-only token)
//   AXIOM_DATASET       default salad-prl
//   AXIOM_HOST          default us-east-1.aws.edge.axiom.co
//   WALLET              default below
//
// Opening the Worker's URL in a browser runs the collection WITHOUT posting
// and shows the records it would send (a safe test; everything in it is
// already public on the Kryptex stats page). Only the cron trigger posts.

const DEFAULT_WALLET = 'prl1p38te2npf3907snmsjy5x0xerwxfa5g7gx5q4ctj5wenfw29m4gzqyyj0gg';
const UA = 'Mozilla/5.0 (pearl-salad pool-stats collector)';

export default {
  async scheduled(event, env, ctx) {
    ctx.waitUntil(run(env, true).then(r => console.log(r.summary)));
  },
  async fetch(request, env) {
    try {
      const r = await run(env, false);
      return new Response(JSON.stringify({ dry_run: true, summary: r.summary, events: r.events }, null, 2),
        { headers: { 'content-type': 'application/json; charset=utf-8' } });
    } catch (e) {
      return new Response(`error: ${e.message}\n`, { status: 500 });
    }
  },
};

async function getText(url) {
  const res = await fetch(url, { headers: { 'user-agent': UA, accept: 'text/html,application/json' } });
  if (!res.ok) throw new Error(`${url} -> HTTP ${res.status}`);
  return res.text();
}
async function getJson(url) { return JSON.parse(await getText(url)); }

// ---- balance from the page's Nuxt payload --------------------------------
// devalue format: one flat array; objects and arrays hold indices into it.
// Reactive/Ref wrappers are ["Reactive", idx] pairs.
export function balanceFromHtml(html) {
  const m = html.match(/<script[^>]*id="__NUXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) throw new Error('no __NUXT_DATA__ in the Kryptex page');
  const arr = JSON.parse(m[1]);
  const resolve = (i, d) => {
    if (d > 6) return null;
    const v = arr[i];
    if (v === null || v === undefined) return null;
    if (typeof v !== 'object') return v;
    if (Array.isArray(v)) {
      if (v.length >= 2 && typeof v[0] === 'string' && /Reactive|Ref/.test(v[0])) return resolve(v[1], d + 1);
      return v.map(x => (Number.isInteger(x) ? resolve(x, d + 1) : x));
    }
    const o = {};
    for (const [k, x] of Object.entries(v)) o[k] = Number.isInteger(x) ? resolve(x, d + 1) : x;
    return o;
  };
  for (let i = 0; i < arr.length; i++) {
    const v = arr[i];
    if (v && typeof v === 'object' && !Array.isArray(v) && 'paid' in v && 'unpaid' in v) return resolve(i, 0);
  }
  throw new Error('balance object not found in the Kryptex payload');
}

const r2 = x => Math.round(x * 100) / 100;
const r3 = x => Math.round(x * 1000) / 1000;

export async function collect(wallet) {
  const [html, workersRes, pool] = await Promise.all([
    getText(`https://pool.kryptex.com/prl/miner/stats/${wallet}`),
    getJson(`https://pool.kryptex.com/prl/api/v3/miner/workers/${wallet}`),
    getJson('https://pool.kryptex.com/prl/api/v1/pool/stats'),
  ]);
  const bal = balanceFromHtml(html);
  const workers = workersRes.results || [];
  const now = new Date().toISOString();
  const paid = Number(bal.paid), unpaid = Number(bal.unpaid);
  const reward = bal.reward || {};
  const online = workers.filter(w => w.status === 'online');
  let sum30 = 0, sum24 = 0;
  for (const w of workers) { sum30 += Number(w.avg_hashrate_30m) || 0; sum24 += Number(w.avg_hashrate_24h) || 0; }

  const events = [{
    _time: now, source: 'kryptex', kind: 'balance', collector: 'cf-worker', wallet,
    paid_prl: paid, unpaid_prl: unpaid, total_prl: paid + unpaid,
    reward_week_prl: Number(reward.week), reward_month_prl: Number(reward.month),
    workers_online: online.length, workers_total: workers.length,
    pool_ths_30m: r2(sum30 / 1e12), pool_ths_24h: r2(sum24 / 1e12),
    net_hashrate_phs: r3(Number(pool.net_hashrate) / 1e15), pool_hashrate_phs: r3(Number(pool.hashrate) / 1e15),
    block_reward_prl: Number(pool.block_reward), height: parseInt(pool.height, 10), pool_fee: Number(pool.fee),
  }];
  for (const w of workers) {
    events.push({
      _time: now, source: 'kryptex', kind: 'worker', collector: 'cf-worker', wallet,
      worker: w.worker, machine: String(w.worker).slice(0, 8), status: w.status, agent: w.agent, country: w.country,
      ths_30m: r2(Number(w.avg_hashrate_30m) / 1e12), ths_3h: r2(Number(w.avg_hashrate_3h) / 1e12), ths_24h: r2(Number(w.avg_hashrate_24h) / 1e12),
      valid: parseInt(w.valid, 10), stale: parseInt(w.stale, 10), invalid: parseInt(w.invalid, 10),
      last_share: new Date(Number(w.last_share)).toISOString(),
    });
  }
  const summary = `${now} paid=${paid} unpaid=${unpaid} online=${online.length}/${workers.length} pool30m=${(sum30 / 1e12).toFixed(1)} TH/s`;
  return { events, summary };
}

async function run(env, post) {
  const wallet = env.WALLET || DEFAULT_WALLET;
  const { events, summary } = await collect(wallet);
  if (!post) return { events, summary };
  if (!env.AXIOM_INGEST_TOKEN) throw new Error('AXIOM_INGEST_TOKEN secret is not set');
  const host = env.AXIOM_HOST || 'us-east-1.aws.edge.axiom.co';
  const dataset = env.AXIOM_DATASET || 'salad-prl';
  const res = await fetch(`https://${host}/v1/ingest/${dataset}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${env.AXIOM_INGEST_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify(events),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`Axiom ingest HTTP ${res.status}: ${body.slice(0, 300)}`);
  const r = JSON.parse(body);
  if (r.failed > 0) throw new Error(`Axiom ingest failed=${r.failed}: ${JSON.stringify(r.failures).slice(0, 300)}`);
  return { events, summary: `${summary} ingested=${r.ingested}` };
}
