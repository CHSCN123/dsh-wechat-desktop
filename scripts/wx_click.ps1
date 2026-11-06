param(
  [Parameter(Mandatory = $true)][int]$X,
  [Parameter(Mandatory = $true)][int]$Y,
  [int]$DelayMs = 120,
  [switch]$DoubleClick
)

# Real left click at absolute screen coordinates (DPI aware).
# Must run on the desktop that owns the target window (see wx_vdesk_helper.ps1).

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxClick {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
  public static void At(int x, int y, int delay) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(delay);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
    System.Threading.Thread.Sleep(70);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
  }
}
"@

[void][WxClick]::SetProcessDpiAwarenessContext([IntPtr](-4))
[WxClick]::At($X, $Y, $DelayMs)
if ($DoubleClick) {
  Start-Sleep -Milliseconds 90
  [WxClick]::At($X, $Y, 80)
}
"clicked " + $X + "," + $Y
