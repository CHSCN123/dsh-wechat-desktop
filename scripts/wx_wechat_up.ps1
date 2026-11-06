param([string]$Exe = $(if ($env:WX_EXE) { $env:WX_EXE } else { 'C:\Program Files\Tencent\WeChat\Weixin.exe' }), [int]$WaitSeconds = 25)
# Start WeChat in the CURRENT desktop if it is not running yet.
# When this script is executed by wx_vdesk_helper.ps1 the child inherits the
# virtual desktop, so WeChat ends up living there (that is the whole point).
$ErrorActionPreference = 'Stop'

$running = Get-Process -Name Weixin -ErrorAction SilentlyContinue
if (-not $running) {
  if (-not (Test-Path $Exe)) { throw ('wx_wechat_up: missing ' + $Exe) }
  Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) | Out-Null
  'started Weixin.exe'
} else {
  'Weixin already running: ' + ($running.Id -join ',')
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 700
  $p = Get-Process -Name Weixin -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
  if ($p) { 'window ready: pid=' + ($p[0].Id) + ' hwnd=' + ($p[0].MainWindowHandle); exit 0 }
}
'no visible Weixin window within ' + $WaitSeconds + 's'
exit 1