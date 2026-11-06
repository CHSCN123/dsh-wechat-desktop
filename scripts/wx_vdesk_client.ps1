param(
  [ValidateSet('ping','send','shot','exec','windows','start','spawn','enter')]
  [string]$Action = 'ping',
  [string]$Chat = '',
  [string]$Text = '',
  [string]$TextFile = '',
  [string]$VerifyChat = '',
  [string]$Out = '',
  [string]$Exe = '',
  [string]$Desktop = 'dshv-wx',
  [int]$AutoBackSeconds = 0,
  [string]$Script = '',
  [string[]]$ScriptArgs = @(),
  [int]$Port = 47660,
  [int]$TimeoutMs = 30000,
  [switch]$NoWake
)

# Plan A client. Wakes the on-demand helper if it is not running, then sends one
# request and returns. The helper shuts down after 15 idle minutes, so nothing
# sits in the background while the bot is quiet.
# Exit codes: 0 ok, 1 helper said no, 2 helper unreachable / could not wake.

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Launcher = Join-Path $Here 'wx_vdesk_launch.ps1'
$PS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

if ($Action -eq 'send') {
  if ($Chat -eq '') { throw 'wx_vdesk_client: -Action send needs -Chat' }
  if ($Text -eq '' -and $TextFile -ne '') {
    if (-not (Test-Path $TextFile)) { throw ('wx_vdesk_client: missing ' + $TextFile) }
    $Text = (Get-Content -Path $TextFile -Raw -Encoding UTF8).TrimEnd("`r", "`n")
  }
  if ($Text -eq '') { throw 'wx_vdesk_client: -Action send needs -Text or -TextFile' }
}
if ($Action -eq 'shot' -and $Out -eq '') { throw 'wx_vdesk_client: -Action shot needs -Out' }
if ($Action -eq 'exec' -and $Script -eq '') { throw 'wx_vdesk_client: -Action exec needs -Script' }
if ($Action -eq 'start' -and $Exe -eq '') { throw 'wx_vdesk_client: -Action start needs -Exe' }

function Invoke-HelperOnce([string]$json) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(1500)) { $client.Close(); return $null }
    $client.EndConnect($iar)
  }
  catch { try { $client.Close() } catch { }; return $null }

  try {
    $client.ReceiveTimeout = $TimeoutMs
    $stream = $client.GetStream()
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true
    $writer.WriteLine($json)
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $line = $reader.ReadLine()
    $client.Close()
    return $line
  }
  catch {
    try { $client.Close() } catch { }
    return ('__TRANSPORT__ ' + $_.Exception.Message)
  }
}

$req = @{ action = $Action }
if ($Action -eq 'send') {
  $req.chat = $Chat
  $req.text = $Text
  if ($VerifyChat -ne '') { $req.verifyChat = $VerifyChat }
}
if ($Action -eq 'shot') { $req.out = $Out }
if ($Action -eq 'start') { $req.exe = $Exe }
if ($Action -eq 'enter') {
  if ($Exe -ne '') { $req.exe = $Exe }
  $req.autoBackSeconds = $AutoBackSeconds
}
if ($Action -eq 'spawn') {
  $req.script = $Script
  if ($ScriptArgs.Count -gt 0) { $req.args = $ScriptArgs }
}
if ($Action -eq 'exec') {
  $req.script = $Script
  if ($ScriptArgs.Count -gt 0) { $req.args = $ScriptArgs }
}
$json = $req | ConvertTo-Json -Compress

$line = Invoke-HelperOnce $json

# A helper that accepts the TCP connection but never answers is a hung helper
# (one bad request used to block its single-threaded loop forever). Kill it and
# let the launcher start a fresh one instead of waiting minutes.
if ($line -like '__TRANSPORT__*') {
  Write-Output ('wx_vdesk_client: stale helper (' + $line + '); killing it')
  try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object { $_.CommandLine -like '*wx_vdesk_helper.ps1*' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } catch { }
  Start-Sleep -Milliseconds 600
  $line = $null
}

if ($null -eq $line) {
  if ($NoWake) { Write-Output ('wx_vdesk_client: helper unreachable on 127.0.0.1:' + $Port + ' (no wake requested)'); exit 2 }
  Write-Output 'wx_vdesk_client: helper asleep, waking it'
  & $PS -NoProfile -ExecutionPolicy Bypass -File $Launcher -Desktop 'dshv-wx' -Port $Port 2>&1 | Out-String | Write-Output
  $line = Invoke-HelperOnce $json
  if ($null -eq $line) { Write-Output ('wx_vdesk_client: helper still unreachable on 127.0.0.1:' + $Port); exit 2 }
}

if ($line -like '__TRANSPORT__*') { Write-Output ('wx_vdesk_client: ' + $line); exit 2 }
if ([string]::IsNullOrWhiteSpace($line)) { Write-Output 'wx_vdesk_client: empty reply from helper'; exit 2 }

$resp = $line | ConvertFrom-Json
if ($resp.out) { Write-Output $resp.out }
if ($Action -eq 'windows') { Write-Output ($resp | ConvertTo-Json -Depth 5 -Compress) }
if ($resp.ok) { exit 0 } else { exit 1 }