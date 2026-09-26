# salad-pull.ps1 - copy Salad container logs into Axiom through the SaladCloud
# log query API, for when Salad's external-logging forwarder does not deliver.
#
# Reads POST /organizations/<org>/log-entries for every org that has a key
# file ~/.salad-api-key-<org> (one Salad user key per org; keys are per user),
# and writes each line into the Axiom dataset with the same shape the
# forwarder used (@timestamp, log.message, resource.labels.*), plus
# via="salad-api". _time is set to the line's own time so backfilled lines
# land where they belong on the dashboard.
#
# What the API allows (measured 2026-09-26): page_size 1..100; times at
# millisecond precision only; sort_order is ignored (always ascending from
# start_time); only label equality is fast (~4 s per page) - "log contains"
# takes ~10 s and often times out (408), so everything is pulled and nothing
# is filtered server-side. Lines are queryable a few seconds after they are
# written; -LagSec keeps a margin for late arrivals.
#
# Modes:
#   live (default)   continue from the cursor in -StateFile; first run starts
#                    10 min back. Catches up at most -MaxMinutes per run.
#   range            -From <utc> [-To <utc>] [-Jobs N]: pull a fixed window
#                    (backfill), split into N parallel slices per org. Does not
#                    touch the cursor unless -SaveCursor (sets it to -To).
#
# Instances that ship their own log (pearl-salad v1.4.0 / NVIDIA v1.6.0 with
# AXIOM_TOKEN set) are skipped automatically: each run first asks Axiom which
# instance ids have via=container lines since 15 min before the window, and
# leaves those out, so nothing lands twice. Everything else is copied: old
# versions during a rolling update, groups with LOG_SHIP=0 or no token, an
# instance whose own posts fail. If that Axiom query fails, nothing is skipped
# for the run (duplicates rather than gaps). ~/.salad-pull-skip-groups (one
# container group name per line) still skips whole groups by hand.
#
# Tokens: Axiom ingest token from AXIOM_INGEST_TOKEN or ~/.axiom-ingest-token;
# Axiom query token (for the check above) from AXIOM_QUERY_TOKEN or
# ~/.axiom-token.
param(
  [string]$From,
  [string]$To,
  [string[]]$Orgs,
  [string]$Query = 'resource.labels.project_name = "default"',
  [int]$LagSec = 120,
  [int]$MaxMinutes = 30,
  [int]$Jobs = 1,
  [switch]$SaveCursor,
  [switch]$NoState,
  [string]$StateFile = "$env:USERPROFILE\.salad-pull-state.json",
  [string]$SkipFile = "$env:USERPROFILE\.salad-pull-skip-groups",
  [switch]$DryRun   # fetch and filter, post nothing (ingested = would be ingested)
)
$ErrorActionPreference = 'Stop'
$dataset = if ($env:AXIOM_DATASET) { $env:AXIOM_DATASET } else { 'salad-prl' }
$axhost  = if ($env:AXIOM_HOST) { $env:AXIOM_HOST } else { 'us-east-1.aws.edge.axiom.co' }
$axtok   = $env:AXIOM_INGEST_TOKEN
if (-not $axtok -and (Test-Path "$env:USERPROFILE\.axiom-ingest-token")) { $axtok = (Get-Content "$env:USERPROFILE\.axiom-ingest-token" -Raw).Trim() }
if (-not $axtok) { throw 'AXIOM_INGEST_TOKEN is not set and ~/.axiom-ingest-token does not exist' }
if (-not $Orgs) { $Orgs = @(Get-ChildItem "$env:USERPROFILE\.salad-api-key-*" -Force | ForEach-Object { $_.Name -replace '^\.salad-api-key-', '' }) }
if (-not $Orgs) { throw 'no ~/.salad-api-key-<org> files' }
$skip = @{}
if (Test-Path $SkipFile) { Get-Content $SkipFile | ForEach-Object { $g = $_.Trim(); if ($g -and -not $g.StartsWith('#')) { $skip[$g] = 1 } } }

function Fmt([datetime]$t) { $t.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
function ParseUtc([string]$s) { [datetimeoffset]::Parse($s, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
# The API takes millisecond times; items carry microseconds.
function FloorMs([datetime]$t) { New-Object DateTime ($t.Ticks - ($t.Ticks % 10000)), ([DateTimeKind]::Utc) }
function ItemKey($it) { "$($it.time)|$($it.resource.labels.instance_id)|$($it.text_log)" }

# Instance ids with via=container lines in Axiom between $since and now.
# Returns $null when the check can't be made.
function Get-ShippingInstances([datetime]$since) {
  $qtok = $env:AXIOM_QUERY_TOKEN
  if (-not $qtok -and (Test-Path "$env:USERPROFILE\.axiom-token")) { $qtok = (Get-Content "$env:USERPROFILE\.axiom-token" -Raw).Trim() }
  if (-not $qtok) { return $null }
  $apl = "['$dataset'] | where via == 'container' | summarize n = count() by i = tostring(['resource.labels.instance_id'])"
  $body = @{ apl = $apl; startTime = (Fmt $since); endTime = (Fmt (Get-Date).ToUniversalTime().AddMinutes(1)) } | ConvertTo-Json
  try {
    $r = Invoke-RestMethod -Method Post -Uri 'https://api.axiom.co/v1/datasets/_apl?format=legacy' -Headers @{ Authorization = "Bearer $qtok" } -ContentType 'application/json' -Body $body -TimeoutSec 60
  } catch { return $null }
  $set = @{}
  foreach ($b in @($r.buckets.totals)) { if ($b.group.i) { $set[[string]$b.group.i] = 1 } }
  return $set
}

$end = if ($To) { ParseUtc $To } else { (Get-Date).ToUniversalTime().AddSeconds(-$LagSec) }
$end = FloorMs $end

# ---- range mode with -Jobs: split and run this script in parallel ---------
# -SaveCursor: live runs continue from the end of this range.
if ($From -and $SaveCursor -and -not $NoState) {
  $st = @{}; if (Test-Path $StateFile) { (Get-Content $StateFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $st[$_.Name] = $_.Value } }
  foreach ($o in $Orgs) { $st[$o] = @{ cursor = (Fmt $end); keys = @() } }
  $st | ConvertTo-Json -Depth 4 | Set-Content $StateFile -Encoding utf8
  "cursor set to $(Fmt $end) for $($Orgs -join ', ')"
}
if ($From -and $Jobs -gt 1) {
  $start = FloorMs (ParseUtc $From)
  $slice = [TimeSpan]::FromTicks([long](($end - $start).Ticks / $Jobs))
  $script = $MyInvocation.MyCommand.Path
  $js = foreach ($o in $Orgs) {
    for ($i = 0; $i -lt $Jobs; $i++) {
      $a = FloorMs ($start + [TimeSpan]::FromTicks($slice.Ticks * $i))
      $b = if ($i -eq $Jobs - 1) { $end } else { FloorMs ($start + [TimeSpan]::FromTicks($slice.Ticks * ($i + 1))) }
      Start-Job -Name "$o#$i" -ScriptBlock { param($s, $o, $f, $t, $q) & $s -Orgs $o -From $f -To $t -Query $q -NoState 2>&1 | ForEach-Object { "[$o $f] $_" } } -ArgumentList $script, $o, (Fmt $a), (Fmt $b), $Query
    }
  }
  "started $($js.Count) jobs: $(Fmt $start) .. $(Fmt $end)"
  while ($js | Where-Object State -eq 'Running') { Start-Sleep -Seconds 30; $js | Receive-Job }
  $js | Receive-Job; $js | Remove-Job
  return
}

# ---- state ------------------------------------------------------------------
$state = @{}
if (-not $From -and -not $NoState -and (Test-Path $StateFile)) {
  (Get-Content $StateFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value }
}

function Invoke-Salad($org, $key, $s, $e) {
  $body = @{ query = $Query; start_time = (Fmt $s); end_time = (Fmt $e); page_size = 100; sort_order = 'asc' } | ConvertTo-Json
  for ($try = 1; ; $try++) {
    try {
      return Invoke-RestMethod -Method Post -Uri "https://api.salad.com/api/public/organizations/$org/log-entries" -Headers @{ 'Salad-Api-Key' = $key } -ContentType 'application/json' -Body $body -TimeoutSec 90
    } catch {
      $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      if ($try -ge 6 -or ($code -ne 0 -and $code -ne 408 -and $code -ne 429 -and $code -lt 500)) { throw "salad $org $(Fmt $s): HTTP $code $($_.ErrorDetails.Message) $($_.Exception.Message)" }
      Start-Sleep -Seconds ([Math]::Min(60, 5 * $try * $try))
    }
  }
}

function Send-Axiom($events) {
  if ($events.Count -eq 0) { return 0 }
  if ($DryRun) { return $events.Count }
  $json = ConvertTo-Json -InputObject @($events) -Depth 6 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  for ($try = 1; ; $try++) {
    try {
      $r = Invoke-RestMethod -Method Post -Uri "https://$axhost/v1/ingest/$dataset" -Headers @{ Authorization = "Bearer $axtok" } -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 90
      if ($r.failed -gt 0) { throw "axiom failed=$($r.failed): $($r.failures | ConvertTo-Json -Depth 4 -Compress)" }
      return [int]$r.ingested
    } catch {
      if ($try -ge 4) { throw }
      Start-Sleep -Seconds (5 * $try)
    }
  }
}

# One self-shipping check per run, covering the earliest window start.
$since = if ($From) { ParseUtc $From } else { (Get-Date).ToUniversalTime().AddMinutes(-10) }
foreach ($o in $Orgs) { if (-not $From -and $state[$o]) { $c = ParseUtc $state[$o].cursor; if ($c -lt $since) { $since = $c } } }
$shipping = Get-ShippingInstances ($since.AddMinutes(-15))
if ($null -eq $shipping) { "self-shipping check failed (Axiom query) - nothing skipped this run" }

$rc = 0
foreach ($org in $Orgs) {
  $keyFile = "$env:USERPROFILE\.salad-api-key-$org"
  if (-not (Test-Path $keyFile)) { "${org}: no key file $keyFile"; $rc = 1; continue }
  $key = (Get-Content $keyFile -Raw).Trim()

  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  if ($From) { $start = FloorMs (ParseUtc $From) }
  elseif ($state[$org]) {
    $start = ParseUtc $state[$org].cursor
    foreach ($k in @($state[$org].keys)) { if ($k) { [void]$seen.Add($k) } }
  } else { $start = FloorMs ((Get-Date).ToUniversalTime().AddMinutes(-10)) }
  $stop = $end
  if (-not $From -and ($stop - $start).TotalMinutes -gt $MaxMinutes) { $stop = FloorMs ($start.AddMinutes($MaxMinutes)) }
  if ($stop -le $start) { "${org}: nothing to do (cursor $(Fmt $start))"; continue }

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $cur = $start; $calls = 0; $got = 0; $sent = 0; $dups = 0; $skipped = 0
  $buf = New-Object System.Collections.ArrayList
  $boundary = @()
  try {
    while ($true) {
      $r = Invoke-Salad $org $key $cur $stop; $calls++
      $items = @($r.items)
      foreach ($it in $items) {
        if (-not $seen.Add((ItemKey $it))) { $dups++; continue }
        if ($skip.ContainsKey([string]$it.resource.labels.container_group_name) -or ($shipping -and $shipping.ContainsKey([string]$it.resource.labels.instance_id))) { $skipped++; continue }
        $got++
        $msg = if ($null -ne $it.text_log) { $it.text_log } elseif ($it.json_log) { ConvertTo-Json -InputObject $it.json_log -Depth 8 -Compress } else { '' }
        $ev = @{ _time = $it.time; '@timestamp' = $it.time; log = @{ message = $msg }; resource = $it.resource; severity = $it.severity; via = 'salad-api' }
        if ($null -ne $it.severity_number) { $ev.severity_number = $it.severity_number }
        [void]$buf.Add($ev)
      }
      if ($buf.Count -ge 1000) { $sent += Send-Axiom $buf; $buf.Clear() }
      if ($items.Count -lt 100) { break }
      $next = FloorMs (ParseUtc $items[-1].time)
      # 100 lines inside one millisecond would never advance; step past it.
      if ($next -le $cur) { $next = $cur.AddMilliseconds(1); "${org}: >100 lines at $(Fmt $cur), skipping 1 ms" }
      $cur = $next
      if ($cur -ge $stop) { break }
    }
    $sent += Send-Axiom $buf; $buf.Clear()
  } catch {
    # Keep what was fetched; the cursor stays where the data stops.
    try { $sent += Send-Axiom $buf } catch { }
    "${org}: ERROR at $(Fmt $cur) after $calls calls: $_"
    $rc = 1
    $stop = $cur
  }
  # Next run starts at $stop; remember the lines at that millisecond so the
  # overlap is not ingested twice.
  $stopS = Fmt $stop
  $boundary = @(); if (-not $From -and -not $NoState) { $boundary = @($seen | Where-Object { $_ -and ((FloorMs (ParseUtc ($_ -split '\|')[0])) -ge $stop) }) }
  if (-not $From -and -not $NoState) { $state[$org] = @{ cursor = $stopS; keys = $boundary } }
  "{0}  {1}  {2} .. {3}  calls={4} lines={5} dups={6} skipped={7} ingested={8} self-shipping={9}  {10:n0}s" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $org, (Fmt $start), $stopS, $calls, $got, $dups, $skipped, $sent, $(if ($shipping) { $shipping.Count } else { '?' }), $sw.Elapsed.TotalSeconds
}
if (-not $From -and -not $NoState) { $state | ConvertTo-Json -Depth 4 | Set-Content $StateFile -Encoding utf8 }
exit $rc
