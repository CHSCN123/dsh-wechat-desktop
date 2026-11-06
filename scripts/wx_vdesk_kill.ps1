param(
  [string]$Desktop = 'dshv-wx',
  [switch]$KeepWeChat
)

# Shut the hidden desktop down.
#
# Order matters: kill the bot WeChat that lives ON that desktop first (only the
# pids the helper can see - never the main-desktop client), then stop the helper.
# A desktop is destroyed by Windows as soon as its last process exits, so with
# both gone the desktop disappears on its own.
#
# The main-desktop WeChat (plan B) is never touched: we only kill what the
# helper reports as a window on THAT desktop.

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Client = Join-Path $Here 'wx_vdesk_client.ps1'
$Launcher = Join-Path $Here 'wx_vdesk_launch.ps1'
$PS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

$killed = @()
if (-not $KeepWeChat) {
  $out = & $PS -NoProfile -ExecutionPolicy Bypass -File $Client -Action windows 2>&1 | Out-String
  $line = ($out -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
  if ($line) {
    try {
      $obj = $line | ConvertFrom-Json
      foreach ($w in $obj.windows) {
        if ([string]$w.title -match '微信|WeChat|Weixin') {
          $killed += [int]$w.pid
        }
      }
    } catch { }
  }
  foreach ($p in $killed) {
    try {
      & taskkill /PID $p /T /F 2>&1 | Out-Null
      Write-Output ('killed wechat on desktop: pid ' + $p)
    } catch { Write-Output ('kill failed for pid ' + $p + ': ' + $_.Exception.Message) }
  }
}

& $PS -NoProfile -ExecutionPolicy Bypass -File $Launcher -Stop 2>&1 | Out-String | Write-Output
Start-Sleep -Milliseconds 800

# Report what is left
$out2 = & $PS -NoProfile -ExecutionPolicy Bypass -File $Client -Action windows -NoWake 2>&1 | Out-String
if ($LASTEXITCODE -eq 2) {
  Write-Output ('desktop ' + $Desktop + ' looks closed (helper gone, nothing left to poke)')
} else {
  Write-Output ('helper still up: ' + $out2.Trim())
}
exit 0