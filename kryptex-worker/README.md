# kryptex-worker

Kryptex pool stats (wallet balance, per-worker pool-side hashrate, pool and
network hashrate) pushed into the Axiom dataset `salad-prl` by a Cloudflare
Worker on a cron trigger. **Deployed 2026-09-26** as `kryptex-collector`
(`https://kryptex-collector.pvandenburg1234.workers.dev`, dry run) running
**every minute**; first records in Axiom at 11:41 UTC. Same records as `tools/kryptex-collect.ps1` (plus
`collector: "cf-worker"`), so the dashboard's Kryptex panels need no change.
Replaces the Windows scheduled task "PRL Kryptex collector" and the throttled
GitHub cron in `.github/workflows/pool-stats.yml`.

Free plan is plenty: at one run a minute that is 1,440 runs a day (limit
100,000), 3 Kryptex requests and 1 Axiom post each, about 43 records per
run. The pool-side hashrates are Kryptex's 30 min / 3 h / 24 h averages, so
running more often mainly speeds up balance and online-worker changes.

## Deploy (dashboard only, no tools to install)

1. **Create the Worker.** dash.cloudflare.com -> **Workers & Pages** ->
   **Create** -> **Create Worker** (start from "Hello World"), name it
   `kryptex-collector`, **Deploy**.
2. **Paste the code.** On the Worker -> **Edit code**, replace everything in
   `worker.js` with the contents of `kryptex-worker/worker.js` from this repo,
   **Deploy**. Pasting is fine. If the code has to be *typed* in (an
   automated browser without clipboard access), first set the editor's
   `editor.autoClosingBrackets` and `editor.autoClosingQuotes` to `never` and
   `editor.autoIndent` to `none` (gear -> Settings): otherwise the editor
   inserts extra closing braces. The one remaining editor warning,
   `ts(2345)` on the `events.push`, is a type hint and harmless.
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
   **Add**: every 1 minute (`* * * * *`), then **Save**.
6. **Check.** Worker -> **Logs** (or Observability) shows each run's summary
   line ending in `ingested=N`. In Axiom: `['salad-prl'] | where collector == 'cf-worker'`.

Once it has run cleanly for a while, disable the old collectors:
`Disable-ScheduledTask -TaskName 'PRL Kryptex collector'` on the PC, and the
`schedule:` block in `.github/workflows/pool-stats.yml`.

## Test outside Cloudflare

`node kryptex-worker/test.mjs` (Node 20+) runs the same collection as a dry
run and checks every field the dashboard uses. The `kryptex-worker-test`
GitHub workflow runs it on every push that touches this folder.
