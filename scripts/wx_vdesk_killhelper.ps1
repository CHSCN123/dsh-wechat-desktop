$ErrorActionPreference = 'SilentlyContinue'

# Kill only real helper processes. Never touch ourselves or our ancestors: a
# caller's command line may legitimately contain the string "wx_vdesk_helper.ps1"
# (syntax checks, edits), and killing that shell looks like a random crash.
$me = $PID
$protected = New-Object System.Collections.Generic.HashSet[int]
[void]$protected.Add($me)
try {
  $cur = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $me)
  $guard = 0
  while ($cur -and [int]$cur.ParentProcessId -ne 0 -and $guard -lt 8) {
    [void]$protected.Add([int]$cur.ParentProcessId)
    $cur = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$cur.ParentProcessId)
    $guard++
  }
} catch { }

$killed = @()
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object {
  $cmd = [string]$_.CommandLine
  if ($cmd -like '*wx_vdesk_helper.ps1*' -and $cmd -notlike '*killhelper*' -and -not $protected.Contains([int]$_.ProcessId)) {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed += $_.ProcessId } catch { }
  }
}
if ($killed.Count -gt 0) { 'killed helper pid=' + ($killed -join ',') } else { 'no helper running' }
Start-Sleep -Milliseconds 700
