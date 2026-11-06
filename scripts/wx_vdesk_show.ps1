param(
  [string]$Desktop = 'dshv-wx',
  [string]$Exe = 'D:\LeStoreDownload\xwechat_files\Weixin.exe',
  [int]$AutoBackSeconds = 600,
  [string]$Match = '微信|WeChat|Weixin',
  [switch]$NoSwitch
)

# One entry point for the "WeChat on a hidden desktop" shortcut.
#
# Rule (user, 2026-10-30): if a WeChat window is ALREADY on that desktop, do not
# start another one - just bring the screen over so the existing login page can
# be scanned. Only when there is no WeChat window at all do we launch the exe.

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Client = Join-Path $Here 'wx_vdesk_client.ps1'
$Toggle = Join-Path $Here 'wx_vdesk_toggle.ps1'
$PS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

function Client([string[]]$ArgList) {
  $out = & $PS -NoProfile -ExecutionPolicy Bypass -File $Client @ArgList 2>&1 | Out-String
  return @{ code = $LASTEXITCODE; text = $out.Trim() }
}

# 1) wake the helper (and the desktop) and ask what windows are already up there
$r = Client @('-Action', 'windows')
if ($r.code -ne 0) {
  Write-Output ('wx_vdesk_show: helper/desktop unavailable (' + $r.text + ')')
  exit 2
}

$hasWeChat = $false
$titles = @()
try {
  $json = ($r.text -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
  $obj = $json | ConvertFrom-Json
  foreach ($w in $obj.windows) {
    $t = [string]$w.title
    $titles += $t
    if ($t -match $Match) { $hasWeChat = $true }
  }
} catch {
  Write-Output ('wx_vdesk_show: cannot parse window list: ' + $_.Exception.Message)
  exit 2
}

if ($hasWeChat) {
  Write-Output ('wx_vdesk_show: WeChat window already there (~' + $titles.Count + ' windows); not starting another one')
} else {
  Write-Output 'wx_vdesk_show: no WeChat window on that desktop; starting it once'
  $s = Client @('-Action', 'start', '-Exe', $Exe)
  Write-Output ('wx_vdesk_show: start -> ' + $s.text)
  if ($s.code -ne 0) { exit 2 }
  Start-Sleep -Seconds 3
}

if ($NoSwitch) { exit 0 }

# 2) bring the screen over (auto-return watchdog lives in the toggle script)
$t = & $PS -NoProfile -ExecutionPolicy Bypass -File $Toggle -Desktop $Desktop -AutoBackSeconds $AutoBackSeconds 2>&1 | Out-String
Write-Output $t.Trim()
exit 0