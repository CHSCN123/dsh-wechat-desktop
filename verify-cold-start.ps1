# verify-cold-start.ps1 - prove dsh-wx-desktop loaded correctly after a DSH restart
#
# ASCII comments only (Windows PowerShell 5.1 reads a BOM-less UTF-8 file as the
# ANSI code page; mojibake inside a comment can swallow the next line).
#
# What "correct" looks like after a cold start:
#   * exactly ONE "bridge ready" line since the DSH process started
#     (a second one means the plugin got mounted twice)
#   * exactly ONE watcher that owns the lock; any extra python watchers are
#     idle waiters and are harmless
#   * a selftest round trip: inbound -> sent ... via=db-owner
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify-cold-start.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify-cold-start.ps1 -WithSelftest
param(
  [switch]$WithSelftest,
  [int]$WaitSeconds = 50
)
$ErrorActionPreference = 'SilentlyContinue'

$log = 'C:\Users\LX\.dsh\weixin\wcdb\plugin.log'
$wcdb = 'C:\Users\LX\.dsh\weixin\wcdb'
$flag = Join-Path $wcdb 'selftest.flag'

Write-Output '== dsh process =='
$dsh = Get-Process | Where-Object { $_.ProcessName -like 'DSH*' } | Sort-Object StartTime | Select-Object -First 1
if (-not $dsh) { Write-Output '  no DSH process found'; exit 1 }
$boot = $dsh.StartTime
Write-Output ("  {0} pid={1} started={2}" -f $dsh.ProcessName, $dsh.Id, $boot.ToString('yyyy-MM-dd HH:mm:ss'))

Write-Output ''
Write-Output '== plugin activity since that start =='
$lines = @()
if (Test-Path $log) {
  foreach ($raw in (Get-Content $log -Encoding UTF8)) {
    if ($raw -match '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})') {
      # plugin.log timestamps are UTC; the process start time is local.
      $t = [datetime]::ParseExact($Matches[1], 'yyyy-MM-ddTHH:mm:ss', $null)
      $utc = [datetime]::SpecifyKind($t, [System.DateTimeKind]::Utc)
      if ($utc -ge $boot.ToUniversalTime().AddMinutes(-1)) { $lines += $raw }
    }
  }
}
if ($lines.Count -eq 0) {
  Write-Output '  nothing logged since the last start - plugin did NOT load'
} else {
  $ready = @($lines | Where-Object { $_ -match 'bridge ready' })
  $starts = @($lines | Where-Object { $_ -match 'starting watcher' })
  $sends = @($lines | Where-Object { $_ -match 'sent \d+ chars' })
  Write-Output ("  bridge ready lines : {0}  (want exactly 1)" -f $ready.Count)
  Write-Output ("  watcher starts     : {0}" -f $starts.Count)
  Write-Output ("  replies sent       : {0}" -f $sends.Count)
  if ($ready.Count -gt 1) {
    Write-Output '  WARN: more than one instance mounted - check for a duplicate insert row'
  }
  $lines | Select-Object -Last 8 | ForEach-Object { Write-Output ('  ' + $_) }
}

Write-Output ''
Write-Output '== watcher / lock =='
$procs = Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -like '*watch.py*' }
Write-Output ("  watcher processes: {0}" -f @($procs).Count)
$ownerFile = Join-Path $wcdb 'watch.lock.owner'
if (Test-Path $ownerFile) {
  $opid = (Get-Content $ownerFile -Raw).Trim()
  $alive = Get-Process -Id ([int]$opid) -ErrorAction SilentlyContinue
  Write-Output ("  lock owner pid={0} alive={1}" -f $opid, [bool]$alive)
} else {
  Write-Output '  no lock owner file'
}

if ($WithSelftest) {
  Write-Output ''
  Write-Output '== selftest round trip =='
  New-Item -ItemType File -Path $flag -Force | Out-Null
  foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force }
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  $ok = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $tail = Get-Content $log -Encoding UTF8 -Tail 12
    $hit = $tail | Where-Object { $_ -match 'sent \d+ chars .*via=db-owner' }
    if ($hit) {
      Write-Output '  OK:'
      $hit | Select-Object -Last 1 | ForEach-Object { Write-Output ('  ' + $_) }
      $ok = $true
      break
    }
  }
  if (-not $ok) { Write-Output ('  TIMEOUT after {0}s - see plugin.log' -f $WaitSeconds) }
}
