param(
  [string]$Desktop = 'dshv-wx',
  [string]$Exe = 'D:\LeStoreDownload\xwechat_files\Weixin.exe',
  [int]$AutoBackSeconds = 60
)

# 虚拟现实: enter the hidden desktop, make sure the WeChat login page is up and
# centred, arm the "click outside = let me out" watcher, then show that desktop.
#
# Rolled back on 2026-10-31 to this slower, proven step-by-step version: the
# one-shot "enter" fast path was suspected of missed sends / chat switching.
#
# Escape routes, in order:
#   1) click anywhere outside the WeChat window -> instant back (wx_vdesk_escape)
#   2) nothing at all for AutoBackSeconds       -> back (watcher timeout)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Client = Join-Path $Here 'wx_vdesk_client.ps1'
$Toggle = Join-Path $Here 'wx_vdesk_toggle.ps1'
$PS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

function Client([string[]]$ArgList) {
  $out = & $PS -NoProfile -ExecutionPolicy Bypass -File $Client @ArgList 2>&1 | Out-String
  return @{ code = $LASTEXITCODE; text = $out.Trim() }
}

# 1) desktop + helper (auto-creates the desktop when it is gone)
$r = Client @('-Action', 'windows')
if ($r.code -ne 0) { Write-Output ('wx_vdesk_enter: cannot open desktop (' + $r.text + ')'); exit 2 }

$hasWeChat = $false
$json = ($r.text -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
try { foreach ($w in ($json | ConvertFrom-Json).windows) { if ([string]$w.title -match '微信|WeChat|Weixin') { $hasWeChat = $true } } } catch { }

if (-not $hasWeChat) {
  Write-Output 'wx_vdesk_enter: starting wechat on that desktop'
  $s = Client @('-Action', 'start', '-Exe', $Exe)
  if ($s.code -ne 0) { Write-Output ('wx_vdesk_enter: start failed (' + $s.text + ')'); exit 2 }
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 900
    $w2 = Client @('-Action', 'windows')
    $j2 = ($w2.text -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    $seen = $false
    try { foreach ($x in ($j2 | ConvertFrom-Json).windows) { if ([string]$x.title -match '微信|WeChat|Weixin') { $seen = $true } } } catch { }
    if ($seen) { Write-Output 'wx_vdesk_enter: wechat window is up'; break }
  }
} else {
  Write-Output 'wx_vdesk_enter: wechat already there, reusing it'
}

# 2) bring the login window up and centred, then arm the click-to-exit watcher
$f = Client @('-Action', 'exec', '-Script', (Join-Path $Here 'wx_wechat_front.ps1'))
Write-Output ('wx_vdesk_enter: front -> ' + $f.text)

$e = Client @('-Action', 'spawn', '-Script', (Join-Path $Here 'wx_vdesk_escape.ps1'), '-ScriptArgs', @('-TimeoutSeconds', [string]$AutoBackSeconds))
Write-Output ('wx_vdesk_enter: escape watcher -> ' + $e.text)

# 3) show that desktop (the toggle arms its own auto-return watchdog)
$t = & $PS -NoProfile -ExecutionPolicy Bypass -File $Toggle -Desktop $Desktop -AutoBackSeconds $AutoBackSeconds 2>&1 | Out-String
Write-Output $t.Trim()
exit 0
