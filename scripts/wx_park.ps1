# wx_park.ps1 - put the WeChat window back to a known geometry before replying.
# 2026-10-31 per user suggestion: just park the window each time.
param([int]$W = 1500, [int]$H = 830, [int]$X = 0, [int]$Y = 0)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxPark2 {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
[void][WxPark2]::SetProcessDpiAwarenessContext([IntPtr](-4))

$cand = Get-Process | Where-Object {
  $_.MainWindowHandle -ne 0 -and ($_.ProcessName -eq 'WeChat' -or $_.ProcessName -eq 'Weixin' -or $_.ProcessName -like '*wechat*')
} | Select-Object -First 1
if (-not $cand) { throw "wx_park: no WeChat main window found" }

$h = $cand.MainWindowHandle
if ([WxPark2]::IsIconic($h)) { [void][WxPark2]::ShowWindow($h, 9); Start-Sleep -Milliseconds 500 }
[void][WxPark2]::ShowWindow($h, 9)
Start-Sleep -Milliseconds 200
[void][WxPark2]::SetWindowPos($h, [IntPtr]::Zero, $X, $Y, $W, $H, 0x0040)
Start-Sleep -Milliseconds 400

$r = New-Object WxPark2+RECT
[void][WxPark2]::GetWindowRect($h, [ref]$r)
$ok = (($r.Right - $r.Left) -eq $W) -and (($r.Bottom - $r.Top) -eq $H)
Write-Output ("wx_park: pid={0} hwnd={1} rect={2},{3} {4}x{5} ok={6}" -f $cand.Id, $h.ToInt64(), $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top), $ok)
if (-not $ok) { exit 1 }
