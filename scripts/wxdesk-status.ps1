# wxdesk-status.ps1 - health check for the dsh-wx-desktop plugin (ASCII comments only)
#
# Windows PowerShell 5.1 reads BOM-less UTF-8 as the ANSI code page, and a
# mojibake comment can swallow the next line. Keep this file ASCII, or save it
# with a BOM.
$ErrorActionPreference = 'SilentlyContinue'

$log = 'C:\Users\LX\.dsh\weixin\wcdb\plugin.log'
$profileDir = 'C:\Users\LX\AppData\Roaming\dsh-desktop\harness\profiles\web'

Write-Output '== watcher processes =='
$procs = Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
  Where-Object { $_.CommandLine -like '*watch.py*' }
if ($procs) {
  $procs | ForEach-Object { Write-Output ("  pid={0} started={1}" -f $_.ProcessId, $_.CreationDate) }
  Write-Output ("  count={0} (one owner + waiters is normal)" -f @($procs).Count)
} else {
  Write-Output '  none - the plugin is probably disabled or failed to start'
}

Write-Output ''
Write-Output '== lock =='
# watch.lock itself is byte-locked by the owner, so it cannot be read; the
# watcher mirrors its pid into watch.lock.owner for diagnostics.
$ownerFile = 'C:\Users\LX\.dsh\weixin\wcdb\watch.lock.owner'
if (Test-Path $ownerFile) {
  $opid = (Get-Content $ownerFile -Raw).Trim()
  $alive = Get-Process -Id ([int]$opid) -ErrorAction SilentlyContinue
  Write-Output ("  owner pid={0} alive={1}" -f $opid, [bool]$alive)
} else {
  Write-Output '  no watch.lock.owner (watcher not running?)'
}

Write-Output ''
Write-Output '== plugin registration =='
$pkg = Get-Content (Join-Path $profileDir 'package.json') -Raw
Write-Output ("  dependency: {0}" -f ($pkg -match '"dsh-wx-desktop"\s*:\s*"link:'))
Write-Output ("  bundles:    {0}" -f ($pkg -match '"bundles"[\s\S]*"dsh-wx-desktop"'))
$patch = Get-Content (Join-Path $profileDir 'cordis.patch.yml') -Raw
if ($patch -match '(?m)^- id: dsh-wx-desktop\r?\n\s+disabled:\s*(\w+)') {
  Write-Output ("  disabled flag in patch layer: {0}" -f $Matches[1])
} else {
  Write-Output '  no patch-layer row (bundle layer only)'
}

Write-Output ''
Write-Output '== recent plugin log (last 20) =='
if (Test-Path $log) { Get-Content $log -Encoding UTF8 -Tail 20 } else { Write-Output '  no plugin.log yet' }

Write-Output ''
Write-Output '== recent inbound messages (last 5) =='
$inbox = 'C:\Users\LX\.dsh\weixin\wcdb\inbox.jsonl'
if (Test-Path $inbox) { Get-Content $inbox -Encoding UTF8 -Tail 5 } else { Write-Output '  no inbox.jsonl yet' }
