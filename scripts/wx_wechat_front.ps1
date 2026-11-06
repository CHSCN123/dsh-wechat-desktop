param([string]$Match = '微信|WeChat|Weixin')

Add-Type -AssemblyName System.Windows.Forms
# Runs ON the hidden desktop: bring the WeChat window to the front and centre it.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxFront {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint fl, IntPtr ex);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public static bool Raise(IntPtr h) {
    keybd_event(0x12, 0x38, 0, IntPtr.Zero); keybd_event(0x12, 0x38, 2, IntPtr.Zero);
    ShowWindow(h, 9); BringWindowToTop(h); SetForegroundWindow(h);
    return true;
  }
}
"@
$w = $null
foreach ($p in Get-Process) {
  try {
    if ($p.MainWindowHandle -ne 0 -and $p.MainWindowTitle -match $Match) { $w = $p; break }
  } catch { }
}
if ($w -eq $null) { Write-Output 'wx_wechat_front: no wechat window on this desktop'; exit 1 }
$h = [IntPtr]$w.MainWindowHandle
[void][WxFront]::Raise($h)
$r = New-Object WxFront+RECT
[void][WxFront]::GetWindowRect($h, [ref]$r)
$w0 = $r.Right - $r.Left; $h0 = $r.Bottom - $r.Top
# centre it so the login page is visible no matter how the desktop is laid out
$sw = [System.Windows.Forms.SystemInformation]::VirtualScreen
[void][WxFront]::SetWindowPos($h, [IntPtr]::Zero, [int](($sw.Width - $w0) / 2), [int](($sw.Height - $h0) / 2), $w0, $h0, 0x0040)
Write-Output ('wx_wechat_front: pid ' + $w.Id + ' rect ' + $r.Left + ',' + $r.Top + ',' + $w0 + 'x' + $h0)
exit 0