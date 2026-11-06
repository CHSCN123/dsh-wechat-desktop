param(
  # ASCII-only comments: PowerShell 5.1 reads a BOM-less UTF-8 script as ANSI,
  # and mojibake inside a comment can corrupt parsing of the following lines.
  [string]$Text = '',
  [string]$TextFile = '',
  # Optional image. WeChat 4.2 opens a file picker for the moment's photo, so a
  # moment always carries at least one picture when driven from the UI.
  [string]$Image = '',
  # 0 = resolve automatically (the client that OWNS the bot account database).
  [long]$Hwnd = 0,
  [string]$DbFile = 'D:\LeStoreDownload\xwechat_files\wxid_kn207qgkufhp29_5794\db_storage\message\message_0.db',
  # Prepare the composer but do not press the publish button.
  [switch]$NoPublish,
  [string]$ShotDir = 'E:\DSH\GZJT GC',
  # Window is parked at this rect so the control fractions below stay valid.
  [int]$WinX = 0,
  [int]$WinY = 0,
  [int]$WinW = 1500,
  [int]$WinH = 830
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxMoments {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  public static POINT SaveCursor() { POINT p; GetCursorPos(out p); return p; }
  public static void RestoreCursor(POINT p) { SetCursorPos(p.X, p.Y); }

  public static bool Raise(IntPtr h) {
    // A single Alt tap releases the foreground lock Windows puts on a window
    // that the user just left, otherwise SetForegroundWindow is a no-op.
    keybd_event(0x12, 0x38, 0, IntPtr.Zero); keybd_event(0x12, 0x38, 2, IntPtr.Zero);
    ShowWindow(h, 9);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    return GetForegroundWindow() == h;
  }

  public static void ClickAt(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(120);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
    System.Threading.Thread.Sleep(60);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
  }

  public static void PasteText(string s) {
    System.Windows.Forms.Clipboard.SetText(s);
    System.Threading.Thread.Sleep(250);
    keybd_event(0x11, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(50);
    keybd_event(0x56, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(70);
    keybd_event(0x56, 0, 2, IntPtr.Zero); System.Threading.Thread.Sleep(50);
    keybd_event(0x11, 0, 2, IntPtr.Zero);
  }

  public static void PressEnter() {
    keybd_event(0x0D, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(60);
    keybd_event(0x0D, 0, 2, IntPtr.Zero);
  }
}
"@

[void][WxMoments]::SetProcessDpiAwarenessContext([IntPtr](-4))

if ($Text -eq '' -and $TextFile -ne '') {
  $Text = Get-Content -LiteralPath $TextFile -Raw -Encoding UTF8
}
if ($Text -eq '') { throw 'wx_moments: -Text or -TextFile is required' }
if ($Image -ne '' -and -not (Test-Path -LiteralPath $Image)) { throw ('wx_moments: image not found: ' + $Image) }

function Shot([string]$name) {
  if (-not (Test-Path -LiteralPath $ShotDir)) { return '' }
  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object System.Drawing.Bitmap ([int]$b.Width), ([int]$b.Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
  $path = Join-Path $ShotDir $name
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  return $path
}

# --- 1. Which window is the bot client? -------------------------------
if ($Hwnd -le 0) {
  $sendScript = Join-Path $PSScriptRoot 'wx_send.ps1'
  $resolve = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sendScript -ResolveOnly -DbFile $DbFile 2>&1 | Select-Object -Last 1
  $m = [regex]::Match([string]$resolve, 'resolve hwnd=(\d+) pid=(\d+) via=(\S+)')
  if (-not $m.Success) {
    throw ('wx_moments: cannot resolve the bot window (' + [string]$resolve + '). Is the bot account logged in?')
  }
  $Hwnd = [long]$m.Groups[1].Value
}
$h = [IntPtr]$Hwnd

# --- 2. Park the window so the control fractions are valid ------------
[void][WxMoments]::ShowWindow($h, 9)
[void][WxMoments]::SetWindowPos($h, [IntPtr]::Zero, $WinX, $WinY, $WinW, $WinH, 0x0040)
$fgBefore = [WxMoments]::GetForegroundWindow()
$cursorBefore = [WxMoments]::SaveCursor()
if (-not [WxMoments]::Raise($h)) {
  [WxMoments]::RestoreCursor($cursorBefore)
  throw ('wx_moments: cannot bring hwnd=' + $Hwnd + ' to the front; refusing to click blindly')
}
Start-Sleep -Milliseconds 600

function Point([double]$fx, [double]$fy) {
  return @([int]($WinX + $WinW * $fx), [int]($WinY + $WinH * $fy))
}

try {
  # Rail "discover" icon, then the Moments entry inside that panel.
  $p = Point 0.0273 0.3690
  [WxMoments]::ClickAt($p[0], $p[1]); Start-Sleep -Milliseconds 1200
  $p = Point 0.0907 0.1520
  [WxMoments]::ClickAt($p[0], $p[1]); Start-Sleep -Milliseconds 1200

  if ($Image -ne '') {
    # Top-right camera of the Moments panel opens a file picker.
    $p = Point 0.9247 0.0831
    [WxMoments]::ClickAt($p[0], $p[1]); Start-Sleep -Milliseconds 1800
    [WxMoments]::PasteText($Image); Start-Sleep -Milliseconds 600
    [WxMoments]::PressEnter(); Start-Sleep -Milliseconds 2600
  }

  # Caption field of the composer.
  $p = Point 0.4667 0.2169
  [WxMoments]::ClickAt($p[0], $p[1]); Start-Sleep -Milliseconds 700
  [WxMoments]::PasteText($Text); Start-Sleep -Milliseconds 900

  $shot = Shot ('moments-compose-' + (Get-Date -Format 'HHmmss') + '.png')
  if ($NoPublish) {
    "composed (not published) shot=$shot hwnd=$Hwnd"
    return
  }

  # Publish button of the composer.
  $p = Point 0.4507 0.7843
  [WxMoments]::ClickAt($p[0], $p[1])
  Start-Sleep -Milliseconds 3500
  $shot2 = Shot ('moments-posted-' + (Get-Date -Format 'HHmmss') + '.png')
  "published attempt hwnd=$Hwnd compose=$shot after=$shot2"

  $ledger = Join-Path $PSScriptRoot 'wx_activity.ps1'
  if (Test-Path -LiteralPath $ledger) {
    try {
      $summary = $Text
      if ($summary.Length -gt 80) { $summary = $summary.Substring(0, 80) }
      & $ledger -Add -Kind moment -Actor 'moments' -Text $summary | Out-Null
    } catch { }
  }
} finally {
  [WxMoments]::RestoreCursor($cursorBefore)
  if ($fgBefore -ne [IntPtr]::Zero) { [void][WxMoments]::SetForegroundWindow($fgBefore) }
}
