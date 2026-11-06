# wx_wherem.ps1 - 教学用：把鼠标放到目标位置，运行本脚本，读回屏幕坐标 + 相对窗口比例
param(
  [string]$Desktop = 'E:\DSH\GZJT GC',
  [switch]$NoShot
)
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class Wm{[DllImport("user32.dll")]public static extern bool SetProcessDpiAwarenessContext(IntPtr c);[DllImport("user32.dll")]public static extern bool GetCursorPos(out POINT p);[DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out RECT r);[DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);[StructLayout(LayoutKind.Sequential)]public struct POINT{public int X;public int Y;}[StructLayout(LayoutKind.Sequential)]public struct RECT{public int Left;public int Top;public int Right;public int Bottom;}}'
[void][Wm]::SetProcessDpiAwarenessContext([IntPtr](-4))
$c = New-Object Wm+POINT
[void][Wm]::GetCursorPos([ref]$c)
"cursor = $($c.X),$($c.Y)"
$wx = Get-Process Weixin -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($wx) {
  $r = New-Object Wm+RECT
  [void][Wm]::GetWindowRect($wx.MainWindowHandle, [ref]$r)
  $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  "window = hwnd=$($wx.MainWindowHandle) pid=$($wx.Id) rect=$($r.Left),$($r.Top) ${w}x${h}"
  if ($w -gt 0 -and $h -gt 0) {
    "relative = {0:N4},{1:N4}" -f (($c.X - $r.Left) / $w), (($c.Y - $r.Top) / $h)
  }
  "use: wx_say.ps1 -SendX {0} -SendY {1}" -f $c.X, $c.Y
}
if (-not $NoShot) {
  Add-Type -AssemblyName System.Drawing, System.Windows.Forms
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap ([int]$b.Width), ([int]$b.Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
  $out = Join-Path $Desktop ("calib-" + (Get-Date -Format 'HHmmss') + ".png")
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  "shot = $out"
}