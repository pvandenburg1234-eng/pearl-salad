# fleet.ps1 [-Minutes 15] [-Events 3]
# One row per Salad worker from the Axiom dataset salad-prl: last reported
# hashrate, watts/temp/clock (NVIDIA miners only), shares, seconds since the
# worker's last log line, and its recent === events. Query token comes from
# C:\Users\pvand\.axiom-token (read-only, one dataset).
param([int]$Minutes = 15, [int]$Events = 3)
$ErrorActionPreference = 'Stop'
$tok = (Get-Content "$env:USERPROFILE\.axiom-token" -Raw).Trim()
$apl = @"
['salad-prl']
| where _time > ago(${Minutes}m) and isnull(probe)
| project ts=['@timestamp'], m=['resource.labels.machine_id'], g=['resource.labels.container_group_name'], msg=['log.message']
| where msg matches regex @'TH/s|th \||pearl hashrate|share accepted|shares=|^=== '
| sort by ts asc
| limit 50000
"@
$body = @{ apl = $apl; startTime = (Get-Date).ToUniversalTime().AddMinutes(-$Minutes - 1).ToString('o'); endTime = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o') } | ConvertTo-Json
$r = Invoke-RestMethod -Method Post -Uri 'https://api.axiom.co/v1/datasets/_apl?format=legacy' -Headers @{ Authorization = "Bearer $tok" } -ContentType 'application/json' -Body $body
$rows = @($r.matches | ForEach-Object { $_.data } | Sort-Object { [datetimeoffset]$_.ts })
$now = (Get-Date).ToUniversalTime()
$ansi = [regex]'\x1b\[[0-9;]*[A-Za-z]'

$w = @{}
foreach ($row in $rows) {
  $m = $row.m; if (-not $m) { continue }
  if (-not $w[$m]) { $w[$m] = [ordered]@{ machine = $m.Substring(0,8); group = $row.g; gpu = ''; ths = ''; watts = ''; temp = ''; mhz = ''; shares = 0; sharesRun = ''; last = $null; events = New-Object System.Collections.ArrayList; miner = '' } }
  $x = $w[$m]
  $msg = $ansi.Replace([string]$row.msg, '') -replace '^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\]\s*', ''
  $x.last = ([datetimeoffset]$row.ts).UtcDateTime
  # SRBMiner stats row:  #0  RTX 5080 Laptop Gpu   129.64 TH/s   174.8W  0.742  -  85C  2490  11301   20  0  0
  if ($msg -match '^#\d+\s+(.+?)\s+([\d.]+)\s*TH/s\s+([\d.]+)W\s+[\d.]+\s+\S+\s+(\d+)C\s+(\d+)\s+\d+\s+(\d+)') {
    $x.miner = 'srb'; $x.gpu = $matches[1]; $x.ths = [double]$matches[2]; $x.watts = $matches[3]; $x.temp = $matches[4]; $x.mhz = $matches[5]; $x.sharesRun = [int]$matches[6]
  }
  # BzMiner per-minute line: pearl hashrate 135.05th  shares=423
  elseif ($msg -match 'pearl hashrate\s+([\d.]+)\s*([kmgtp]?h)\b.*shares=(\d+)') {
    $x.miner = 'bz'; $x.ths = [double]$matches[1]; $x.sharesRun = [int]$matches[3]
  }
  # BzMiner summary row: | smry | ... | 133.45th | 135.04th |  (last column = miner rate)
  elseif ($msg -match '^\|\s*smry\s*\|' ) {
    $cols = $msg -split '\|' | ForEach-Object { $_.Trim() }
    $rates = @($cols | Where-Object { $_ -match '^[\d.]+\s*th$' })
    if ($rates.Count -gt 0) { $x.miner = 'bz'; $x.ths = [double]($rates[-1] -replace 'th','').Trim() }
  }
  # krig: Total: 51.7 TH/s shares: 134 accepted 0 stale 0 rejected
  elseif ($msg -match '^\S+\s+Total:\s+([\d.]+)\s*TH/s.*?(\d+) accepted') {
    $x.miner = 'krig'; $x.ths = [double]$matches[1]; $x.sharesRun = [int]$matches[2]
  }
  elseif ($msg -match 'share accepted') { $x.shares++ }
  elseif ($msg -match '^=== (host check|HOST IS|pool check: (no|TLS handshake works)|asking Salad|reallocation|\[\w+\] (exited|no accepted|ACCEPTED SHARE|starting)|no miner|HOST IS|NVIDIA power limit:.*W of)') {
    $t = ([datetimeoffset]$row.ts).UtcDateTime.ToString('HH:mm')
    $short = ($msg -replace '^=== ','' -replace ' ===$','')
    if ($short.Length -gt 70) { $short = $short.Substring(0,70) + '...' }
    [void]$x.events.Add("$t $short")
  }
}

$total = 0.0
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add(('{0,-8} {1,-14} {2,-5} {3,-24} {4,7} {5,6} {6,4} {7,5} {8,7} {9,6}  {10}' -f 'machine','group','miner','gpu','TH/s','W','C','MHz','shares','age s','recent events (UTC)'))
foreach ($m in ($w.Keys | Sort-Object { $w[$_].group }, { $w[$_].machine })) {
  $x = $w[$m]
  $age = if ($x.last) { [int]($now - $x.last).TotalSeconds } else { '' }
  $ev = @($x.events | Select-Object -Last $Events) -join ' | '
  $sh = if ($x.sharesRun -ne '') { "$($x.sharesRun)" } else { "+$($x.shares)" }
  if ($x.ths -ne '') { $total += [double]$x.ths }
  $g = $x.group; if ($g.Length -gt 14) { $g = $g.Substring(0,14) }
  $gpu = $x.gpu; if ($gpu.Length -gt 24) { $gpu = $gpu.Substring(0,24) }
  [void]$lines.Add(('{0,-8} {1,-14} {2,-5} {3,-24} {4,7} {5,6} {6,4} {7,5} {8,7} {9,6}  {10}' -f $x.machine,$g,$x.miner,$gpu,$x.ths,$x.watts,$x.temp,$x.mhz,$sh,$age,$ev))
}
"salad-prl, last $Minutes min, $($rows.Count) lines, $($w.Count) workers, sum of last reported rates: $([math]::Round($total,1)) TH/s   (UTC now $($now.ToString('HH:mm:ss')))"
$lines -join "`n"
