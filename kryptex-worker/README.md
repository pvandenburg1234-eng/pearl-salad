# kryptex-worker

Kryptex pool stats (wallet balance, per-worker pool-side hashrate, pool and
network hashrate) pushed into the Axiom dataset `salad-prl` every 5 minutes
by a Cloudflare Worker. Same records as `tools/kryptex-collect.ps1` (plus
`collector: "cf-worker"`), so the dashboard's Kryptex panels need no change.
Replaces the Windows scheduled task "PRL Kryptex collector" and the throttled
GitHub cron in `.github/workflows/pool-stats.yml`.

Free plan is plenty: 288 runs a day, 3 Kryptex requests and 1 Axiom post each.

## Deploy (dashboard only, no tools to install)

1. **Create the Worker.** dash.cloudflare.com -> **Workers & Pages** ->
   **Create** -> **Create Worker** (start from "Hello World"), name it
   `kryptex-collector`, **Deploy**.
2. **Paste the code.** On the Worker -> **Edit code**, replace everything in
   `worker.js` with the contents of `kryptex-worker/worker.js` from this repo,
   **Deploy**.
3. **Dry run.** Open the Worker's URL (`https://kryptex-collector.<you>.workers.dev`).
   It shows `"dry_run": true`, a summary line and the records it would send,
   and posts nothing. If Kryptex blocks Cloudflare's network, you get an
   error here instead.
4. **Secret.** Worker -> **Settings** -> **Variables and Secrets** -> **Add**,
   type **Secret**, name `AXIOM_INGEST_TOKEN`, value = the Axiom ingest token
   (`C:\Users\pvand\.axiom-ingest-token`). Optional plain variables:
   `AXIOM_DATASET` (default `salad-prl`), `AXIOM_HOST` (default
   `us-east-1.aws.edge.axiom.co`), `WALLET`.
5. **Schedule.** Worker -> **Settings** -> **Triggers** -> **Cron Triggers** ->
   **Add**: `*/5 * * * *` (every 5 minutes; `* * * * *` for every minute).
6. **Check.** Worker -> **Logs** (or Observability) shows each run's summary
   line ending in `ingested=N`. In Axiom: `['salad-prl'] | where collector == 'cf-worker'`.

Once it has run cleanly for a while, disable the old collectors:
`Disable-ScheduledTask -TaskName 'PRL Kryptex collector'` on the PC, and the
`schedule:` block in `.github/workflows/pool-stats.yml`.

## Test outside Cloudflare

`node kryptex-worker/test.mjs` (Node 20+) runs the same collection as a dry
run and checks every field the dashboard uses. The `kryptex-worker-test`
GitHub workflow runs it on every push that touches this folder.
