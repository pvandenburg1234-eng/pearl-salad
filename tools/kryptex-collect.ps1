# kryptex-collect.ps1 - pull the wallet's Kryptex pool stats and push them
# into the Axiom dataset that already holds the Salad container logs.
#
# Sources (no login needed):
#   * https://pool.kryptex.com/prl/miner/stats/<wallet>  - the page's Nuxt
#     payload carries paid / unpaid / reward.week / reward.month (there is no
#     JSON endpoint for those)
#   * https://pool.kryptex.com/prl/api/v3/miner/workers/<wallet> - per worker
#     30 min / 3 h / 24 h average hashrate, share counts, agent, status
#   * https://pool.kryptex.com/prl/api/v1/pool/stats - pool + network hashrate,
#     block reward
#
# Every record gets source="kryptex" so the dashboard can tell them from the
# container log lines. Runs from .github/workflows/pool-stats.yml every 10
# minutes (pwsh on ubuntu) and works on Windows PowerShell 5.1 too.
#
# Env: AXIOM_INGEST_TOKEN (required), AXIOM_HOST (default the US East edge),
#      AXIOM_DATASET (default salad-prl), WALLET (default below)
$ErrorActionPreference = 'Stop'
$wallet  = if ($env:WALLET) { $env:WALLET } else { 'prl1p38te2npf3907snmsjy5x0xerwxfa5g7gx5q4ctj5wenfw29m4gzqyyj0gg' }
$dataset = if ($env:AXIOM_DATASET) { $env:AXIOM_DATASET } else { 'salad-prl' }
$axhost  = if ($env:AXIOM_HOST) { $env:AXIOM_HOST } else { 'us-east-1.aws.edge.axiom.co' }
$tok     = $env:AXIOM_INGEST_TOKEN
# Local fallback (Windows scheduled task on the user's PC): the ingest token
# as the only line of ~/.axiom-ingest-token.
if (-not $tok -and (Test-Path "$env:USERPROFILE\.axiom-ingest-token")) { $tok = (Get-Content "$env:USERPROFILE\.axiom-ingest-token" -Raw).Trim() }
if (-not $tok) { throw 'AXIOM_INGEST_TOKEN is not set and ~/.axiom-ingest-token does not exist' }
$now = (Get-Date).ToUniversalTime().ToString('o')
$ua = 'Mozilla/5.0 (pearl-salad pool-stats collector)'

# ---- balance from the page's Nuxt payload -------------------------------
$html = (Invoke-WebRequest -UseBasicParsing -Uri "https://pool.kryptex.com/prl/miner/stats/$wallet" -UserAgent $ua -TimeoutSec 60).Content
$m = [regex]::Match($html, '<script[^>]*id="__NUXT_DATA__"[^>]*>(.*?)</script>', 'Singleline')
if (-not $m.Success) { throw 'no __NUXT_DATA__ in the Kryptex page' }
$arr = $m.Groups[1].Value | ConvertFrom-Json
# devalue format: every object/array holds indices into $arr
function Resolve-Node($i, $d) {
  if ($d -gt 6) { return $null }
  $v = $arr[$i]
  if ($null -eq $v) { return $null }
  # Leaf values first. (In pwsh 7 a boxed number also answers true to
  # "-is [pscustomobject]", which turned every leaf into an empty hashtable.)
  if ($v -is [string] -or $v -is [bool] -or $v -is [double] -or $v -is [decimal] -or $v -is [int] -or $v -is [long]) { return $v }
  if ($v -is [System.Array]) {
    if ($v.Count -ge 2 -and $v[0] -is [string] -and $v[0] -match 'Reactive|Ref') { return Resolve-Node $v[1] ($d + 1) }
    return @($v | ForEach-Object { if ($_ -is [int] -or $_ -is [long]) { Resolve-Node $_ ($d + 1) } else { $_ } })
  }
  if ($v.GetType().Name -eq 'PSCustomObject') {
    $o = @{}
    foreach ($p in $v.PSObject.Properties) { $o[$p.Name] = if ($p.Value -is [int] -or $p.Value -is [long]) { Resolve-Node $p.Value ($d + 1) } else { $p.Value } }
    return $o
  }
  return $v
}
$bal = $null
for ($i = 0; $i -lt $arr.Count; $i++) {
  $v = $arr[$i]
  if ($null -ne $v -and $v.GetType().Name -eq 'PSCustomObject' -and $v.PSObject.Properties['paid'] -and $v.PSObject.Properties['unpaid']) { $bal = Resolve-Node $i 0; break }
}
if (-not $bal) { throw 'balance object not found in the Kryptex payload' }
# Hashtable vs PSCustomObject member access differs between Windows
# PowerShell 5.1 and pwsh 7; read fields through one helper.
function Get-Field($o, $k) {
  if ($null -eq $o) { return $null }
  if ($o -is [hashtable]) { return $o[$k] }
  $p = $o.PSObject.Properties[$k]; if ($p) { return $p.Value }; return $null
}
"balance payload: " + (ConvertTo-Json -InputObject $bal -Compress -Depth 4)
$paid = [double](Get-Field $bal 'paid'); $unpaid = [double](Get-Field $bal 'unpaid')
$rw = Get-Field $bal 'reward'; $rweek = [double](Get-Field $rw 'week'); $rmonth = [double](Get-Field $rw 'month')

# ---- workers + pool -------------------------------------------------------
$workers = (Invoke-RestMethod -Uri "https://pool.kryptex.com/prl/api/v3/miner/workers/$wallet" -UserAgent $ua -TimeoutSec 60).results
$pool = Invoke-RestMethod -Uri 'https://pool.kryptex.com/prl/api/v1/pool/stats' -UserAgent $ua -TimeoutSec 60

$online = @($workers | Where-Object { $_.status -eq 'online' })
$sum30 = 0.0; $sum24 = 0.0
foreach ($w in $workers) { $sum30 += [double]$w.avg_hashrate_30m; $sum24 += [double]$w.avg_hashrate_24h }

$events = New-Object System.Collections.ArrayList
[void]$events.Add(@{
  _time = $now; source = 'kryptex'; kind = 'balance'; wallet = $wallet
  paid_prl = $paid; unpaid_prl = $unpaid; total_prl = $paid + $unpaid
  reward_week_prl = $rweek; reward_month_prl = $rmonth
  workers_online = $online.Count; workers_total = $workers.Count
  pool_ths_30m = [math]::Round($sum30 / 1e12, 2); pool_ths_24h = [math]::Round($sum24 / 1e12, 2)
  net_hashrate_phs = [math]::Round([double]$pool.net_hashrate / 1e15, 3); pool_hashrate_phs = [math]::Round([double]$pool.hashrate / 1e15, 3)
  block_reward_prl = [double]$pool.block_reward; height = [int]$pool.height; pool_fee = [double]$pool.fee
})
foreach ($w in $workers) {
  [void]$events.Add(@{
    _time = $now; source = 'kryptex'; kind = 'worker'; wallet = $wallet
    worker = $w.worker; machine = $w.worker.Substring(0, [math]::Min(8, $w.worker.Length)); status = $w.status; agent = $w.agent; country = $w.country
    ths_30m = [math]::Round([double]$w.avg_hashrate_30m / 1e12, 2); ths_3h = [math]::Round([double]$w.avg_hashrate_3h / 1e12, 2); ths_24h = [math]::Round([double]$w.avg_hashrate_24h / 1e12, 2)
    valid = [int]$w.valid; stale = [int]$w.stale; invalid = [int]$w.invalid
    last_share = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$w.last_share).UtcDateTime.ToString('o')
  })
}
$body = ConvertTo-Json -InputObject @($events) -Depth 5 -Compress
$r = Invoke-RestMethod -Method Post -Uri "https://$axhost/v1/ingest/$dataset" -Headers @{ Authorization = "Bearer $tok" } -ContentType 'application/json' -Body $body -TimeoutSec 60
"$now  ingested=$($r.ingested) failed=$($r.failed)  paid=$paid unpaid=$unpaid online=$($online.Count)/$($workers.Count) pool30m=$([math]::Round($sum30/1e12,1)) TH/s"
if ($r.failed -gt 0) { $r.failures | ConvertTo-Json -Depth 4; exit 1 }
