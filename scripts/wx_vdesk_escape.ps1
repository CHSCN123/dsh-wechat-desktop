param(
  [int]$TimeoutSeconds = 600,
  [string]$Match = '微信|WeChat|Weixin',
  [int]$GraceMs = 1500
)

# Runs ON the hidden desktop. Escape hatch: click anywhere that is NOT inside the
# WeChat window and the screen goes straight back to the normal desktop.
#
# Why: that desktop has no shell and no icons (pure black), so there is nothing to
# click to get out. The WeChat window is the one thing that is visible; clicking
# outside it means "let me out".

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxEsc {
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SwitchDesktop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

function Get-WxRect {
  foreach ($p in Get-Process) {
    try {
      if ($p.MainWindowHandle -ne 0 -and $p.MainWindowTitle -match $Match) {
        $r = New-Object WxEsc+RECT
        if ([WxEsc]::GetWindowRect([IntPtr]$p.MainWindowHandle, [ref]$r)) { return $r }
      }
    } catch { }
  }
  return $null
}

function Go-Back {
  $d = [WxEsc]::OpenDesktop('Default', 0, $false, 0x000F01FF)
  if ($d -eq [IntPtr]::Zero) { Write-Output 'wx_vdesk_escape: cannot open Default'; return $false }
  $ok = [WxEsc]::SwitchDesktop($d)
  [void][WxEsc]::CloseDesktop($d)
  Write-Output ('wx_vdesk_escape: clicked outside -> back to Default: ' + $ok)
  return $ok
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$start = Get-Date
while ((Get-Date) -lt $deadline) {
  if (((Get-Date) - $start).TotalMilliseconds -lt $GraceMs) { Start-Sleep -Milliseconds 100; continue }
  $down = ([WxEsc]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
  if ($down) {
    $pt = New-Object WxEsc+POINT
    [void][WxEsc]::GetCursorPos([ref]$pt)
    $r = Get-WxRect
    $inside = $false
    if ($r -ne $null) {
      $inside = ($pt.X -ge $r.Left -and $pt.X -le $r.Right -and $pt.Y -ge $r.Top -and $pt.Y -le $r.Bottom)
    }
    if (-not $inside) { [void](Go-Back); exit 0 }
    # wait for release so one click does not count twice
    while ((([WxEsc]::GetAsyncKeyState(0x01)) -band 0x8000) -ne 0) { Start-Sleep -Milliseconds 60 }
  }
  Start-Sleep -Milliseconds 90
}
Write-Output ('wx_vdesk_escape: nothing clicked for ' + $TimeoutSeconds + 's -> back to Default')
[void](Go-Back)
exit 0