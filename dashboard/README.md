# PRL fleet dashboard

A small web page for the fleet, served by a Cloudflare Worker (`prl-dashboard`)
that reads the Axiom dataset `salad-prl`. Axiom stays the data store (the
containers ship their logs there, the `kryptex-collector` Worker adds the pool
stats); this Worker only queries it and draws the page.

- `GET /` the page (refreshes every 30 s)
- `GET /api/fleet` the JSON it draws (`?fresh=1` bypasses the 30 s cache)

What it shows, all computed from the miners' own log lines unless noted:

- Fleet hashrate: sum over active workers of each worker's average of its
  last 5 hashrate readings (BzMiner and SRBMiner print one about every minute).
- Active workers (logged within 10 min) with the GPU mix, e.g. `RX 9070 XT (18)`.
- Unpaid / total PRL and PRL earned in the last 24 h (Kryptex).
- One column per active worker (last-5 average, colour = container group);
  tooltip adds the latest reading, GPU, group, age and Kryptex's 30 min figure.
- 24 h trend: fleet from the logs vs Kryptex's pool-side 30 min average.
- Worker table (NVIDIA rows also show W / °C / MHz) and the last 24 h of events.

## Files

- `src/worker.js` Axiom queries, caching (30 s live, 5 min for the 24 h data), routes
- `src/fleet.js` pure functions: Axiom rows -> page model
- `src/queries.json` the APL queries
- `src/index.html` the page (Chart.js from jsDelivr)
- `test/fleet.test.mjs` + `test/fixture.json` Node test on rows captured from Axiom
- `wrangler.toml` Worker config

## Deploy

`.github/workflows/dashboard.yml` tests every push to `dashboard/` and deploys
from `main` once these repository secrets exist:

- `CLOUDFLARE_API_TOKEN`: Cloudflare -> My Profile -> API Tokens -> Create
  token -> template **Edit Cloudflare Workers** (account: this one).
- `AXIOM_QUERY_TOKEN`: a read-only Axiom query token; the workflow stores it as
  the Worker's secret.

Access: Worker -> Settings -> Domains & Routes -> `workers.dev` -> enable
**Cloudflare Access**, limited to your email (one-time code login).
