param(
  [string]$Exe = $(if ($env:WX_EXE) { $env:WX_EXE } else { 'C:\Program Files\Tencent\WeChat\Weixin.exe' }),
  [int]$WaitSeconds = 30,
  [switch]$Quiet
)

# "Reality" button: get the real desktop back and make sure the WeChat client is
# running on it.
#   1) if the screen currently shows the hidden desktop, switch back to Default
#   2) if no WeChat window exists, start it and wait for the window

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxHome {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SwitchDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr h, int index, System.Text.StringBuilder info, int len, out int needed);
  public static string NameOf(IntPtr h) {
    var sb = new System.Text.StringBuilder(256); int need;
    if (!GetUserObjectInformation(h, 2, sb, sb.Capacity, out need)) return "?";
    return sb.ToString();
  }
}
"@

function Get-InputName {
  $h = [WxHome]::OpenInputDesktop(0, $false, 0x0100)
  if ($h -eq [IntPtr]::Zero) { return '?' }
  $n = [WxHome]::NameOf($h)
  [void][WxHome]::CloseDesktop($h)
  return $n
}

$now = Get-InputName
if ($now -ne 'Default') {
  $h = [WxHome]::OpenDesktop('Default', 0, $false, 0x0100 -bor 0x0001 -bor 0x0080)
  if ($h -eq [IntPtr]::Zero) { Write-Output 'wx_desktop_home: cannot open Default desktop' }
  else {
    $ok = [WxHome]::SwitchDesktop($h)
    [void][WxHome]::CloseDesktop($h)
    if ($ok) { if (-not $Quiet) { Write-Output ('back to Default (was ' + $now + ')') } }
    else { Write-Output ('wx_desktop_home: SwitchDesktop(Default) failed (was ' + $now + ')') }
  }
}
else { if (-not $Quiet) { Write-Output 'already on Default' } }

function Get-WxWindow {
  foreach ($p in Get-Process Weixin -ErrorAction SilentlyContinue) {
    try { if ($p.MainWindowHandle -ne 0) { return $p } } catch { }
  }
  return $null
}

$wx = Get-WxWindow
if ($wx -eq $null) {
  if (-not (Test-Path $Exe)) { Write-Output ('wx_desktop_home: missing ' + $Exe); exit 2 }
  Write-Output 'wechat not running; starting it'
  Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) | Out-Null
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 700
    $wx = Get-WxWindow
    if ($wx -ne $null) { break }
  }
}

if ($wx -ne $null) {
  Write-Output ('wechat ready: pid ' + $wx.Id + ' window ' + $wx.MainWindowHandle)
  exit 0
}
Write-Output ('wx_desktop_home: wechat started but no window after ' + $WaitSeconds + 's')
exit 1