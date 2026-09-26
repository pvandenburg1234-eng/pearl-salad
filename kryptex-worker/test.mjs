// Dry-run test for worker.js outside Cloudflare (Node 20+, which has fetch).
// Fetches the live Kryptex data, parses it exactly as the Worker does, and
// checks the records have the fields the dashboard uses. Posts nothing.
import { collect } from './worker.js';

const wallet = process.env.WALLET || 'prl1p38te2npf3907snmsjy5x0xerwxfa5g7gx5q4ctj5wenfw29m4gzqyyj0gg';
const { events, summary } = await collect(wallet);
console.log(summary);

const bal = events.find(e => e.kind === 'balance');
const workers = events.filter(e => e.kind === 'worker');
const problems = [];
for (const k of ['paid_prl', 'unpaid_prl', 'total_prl', 'reward_week_prl', 'pool_ths_30m', 'net_hashrate_phs', 'block_reward_prl', 'height']) {
  if (typeof bal[k] !== 'number' || Number.isNaN(bal[k])) problems.push(`balance.${k} = ${bal[k]}`);
}
if (workers.length === 0) problems.push('no worker records');
for (const w of workers) {
  for (const k of ['ths_30m', 'ths_3h', 'ths_24h', 'valid']) {
    if (typeof w[k] !== 'number' || Number.isNaN(w[k])) problems.push(`worker ${w.machine}.${k} = ${w[k]}`);
  }
}
console.log(JSON.stringify(bal, null, 2));
console.log(`${workers.length} worker records, e.g.`, JSON.stringify(workers.find(w => w.status === 'online') || workers[0]));
if (problems.length) { console.error('PROBLEMS:\n  ' + problems.join('\n  ')); process.exit(1); }
console.log('OK: all fields present and numeric');
