param(
  # Accept the newest pending friend request and say hello in the new chat.
  # ASCII-only comments: PowerShell 5.1 parses a BOM-less script as ANSI.
  [string]$Welcome = '',
  [long]$Hwnd = 0,
  [string]$DbFile = 'D:\LeStoreDownload\xwechat_files\wxid_kn207qgkufhp29_5794\db_storage\message\message_0.db',
  # Stop right before the final "确定" in the verification dialog.
  [switch]$NoConfirm,
  # Only open 新的朋友 and report whether anything is pending (no clicking).
  [switch]$Probe,
  [string]$ShotDir = 'E:\DSH\GZJT GC',
  [int]$WinX = 0, [int]$WinY = 0, [int]$WinW = 1500, [int]$WinH = 830
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System; using System.Text; using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WxFriend {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool t);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint fl, IntPtr ex);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  public static bool Force(IntPtr h) {
    IntPtr fg = GetForegroundWindow(); uint fpid = 0;
    uint ft = GetWindowThreadProcessId(fg, out fpid); uint me = GetCurrentThreadId();
    AttachThreadInput(me, ft, true);
    ShowWindow(h, 9); BringWindowToTop(h); SetForegroundWindow(h);
    AttachThreadInput(me, ft, false);
    return GetForegroundWindow() == h;
  }

  public static void Click(int x, int y) {
    SetCursorPos(x, y); System.Threading.Thread.Sleep(140);
    mouse_event(0x0002, 0, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(70);
    mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
  }

  public static void Paste(string s) {
    System.Windows.Forms.Clipboard.SetText(s);
    System.Threading.Thread.Sleep(250);
    keybd_event(0x11, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(50);
    keybd_event(0x56, 0, 0, IntPtr.Zero); System.Threading.Thread.Sleep(70);
    keybd_event(0x56, 0, 2, IntPtr.Zero); System.Threading.Thread.Sleep(50);
    keybd_event(0x11, 0, 2, IntPtr.Zero);
  }

  // Extra visible top-level window of the same process that is not the main
  // frame: the "通过朋友验证" dialog is one of these, and it opens BEHIND the
  // main window, which is why clicking 前往验证 looked like a no-op.
  static uint pidTarget; static IntPtr mainH; static List<IntPtr> extra;
  static bool Cb(IntPtr h, IntPtr l) {
    uint pid; GetWindowThreadProcessId(h, out pid);
    if (pid == pidTarget && h != mainH && IsWindowVisible(h)) {
      RECT r; if (GetWindowRect(h, out r)) {
        long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
        if (area > 40000) extra.Add(h);
      }
    }
    return true;
  }
  public static IntPtr FindDialog(uint pid, IntPtr main) {
    pidTarget = pid; mainH = main; extra = new List<IntPtr>();
    EnumWindows(new EnumProc(Cb), IntPtr.Zero);
    IntPtr best = IntPtr.Zero; long smallest = long.MaxValue;
    foreach (IntPtr h in extra) {
      RECT r; GetWindowRect(h, out r);
      long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
      if (area < smallest) { smallest = area; best = h; }
    }
    return best;
  }
  public static int[] Rect(IntPtr h) {
    RECT r; GetWindowRect(h, out r);
    return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
  }
}
"@

[void][WxFriend]::SetProcessDpiAwarenessContext([IntPtr](-4))

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

if ($Hwnd -le 0) {
  $resolve = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'wx_send.ps1') -ResolveOnly -DbFile $DbFile 2>&1 | Select-Object -Last 1
  $m = [regex]::Match([string]$resolve, 'resolve hwnd=(\d+) pid=(\d+)')
  if (-not $m.Success) { throw ('wx_friend: cannot resolve the bot window: ' + [string]$resolve) }
  $Hwnd = [long]$m.Groups[1].Value
  $script:procId = [uint32]$m.Groups[2].Value
} else {
  $script:procId = 0
}
$h = [IntPtr]$Hwnd

[void][WxFriend]::ShowWindow($h, 9)
[void][WxFriend]::SetWindowPos($h, [IntPtr]::Zero, $WinX, $WinY, $WinW, $WinH, 0x0040)
$fgBefore = [WxFriend]::GetForegroundWindow()
$cur = New-Object WxFriend+POINT
[void][WxFriend]::GetCursorPos([ref]$cur)
if (-not [WxFriend]::Force($h)) { throw ('wx_friend: cannot bring hwnd=' + $Hwnd + ' to the front') }
Start-Sleep -Milliseconds 700

function P([double]$fx, [double]$fy) { return @([int]($WinX + $WinW * $fx), [int]($WinY + $WinH * $fy)) }

try {
  # rail -> contacts
  $p = P 0.0273 0.2337
  [WxFriend]::Click($p[0], $p[1]); Start-Sleep -Milliseconds 1200

  # "新的朋友" entry sits right under 通讯录管理
  $p = P 0.1030 0.2080
  [WxFriend]::Click($p[0], $p[1]); Start-Sleep -Milliseconds 1400
  $probeShot = Shot ('friends-' + (Get-Date -Format 'HHmmss') + '.png')

  if ($Probe) { "probe hwnd=$Hwnd shot=$probeShot"; return }

  # newest request is the first row of the list
  $p = P 0.1220 0.3010
  [WxFriend]::Click($p[0], $p[1]); Start-Sleep -Milliseconds 1400

  # "前往验证" in the request detail
  $p = P 0.4110 0.4300
  [WxFriend]::Click($p[0], $p[1]); Start-Sleep -Milliseconds 2000

  $dlg = [WxFriend]::FindDialog($script:procId, $h)
  if ($dlg -eq [IntPtr]::Zero) {
    $s = Shot ('friends-nodlg-' + (Get-Date -Format 'HHmmss') + '.png')
    "no verification dialog appeared (some WeChat builds hide it behind the main window); shot=$s"
    return
  }
  $r = [WxFriend]::Rect($dlg)
  "dialog hwnd=$dlg rect=" + ($r -join ',')

  if ($NoConfirm) {
    $s = Shot ('friends-dlg-' + (Get-Date -Format 'HHmmss') + '.png')
    "dialog open, not confirmed; shot=$s"
    return
  }

  # 确定 sits at the lower-left of the dialog.
  $okX = [int]($r[0] + $r[2] * 0.47)
  $okY = [int]($r[1] + $r[3] * 0.90)
  [void][WxFriend]::Force($dlg)
  Start-Sleep -Milliseconds 500
  [WxFriend]::Click($okX, $okY)
  Start-Sleep -Milliseconds 2500

  if ($Welcome -ne '') {
    [void][WxFriend]::Force($h)
    Start-Sleep -Milliseconds 600
    # After accepting, WeChat opens the new chat; the composer sits where the
    # normal chat input is.
    $p = P 0.4700 0.7900
    [WxFriend]::Click($p[0], $p[1]); Start-Sleep -Milliseconds 600
    [WxFriend]::Paste($Welcome); Start-Sleep -Milliseconds 800
    $p = P 0.9560 0.9330
    [WxFriend]::Click($p[0], $p[1]); Start-Sleep -Milliseconds 1200
  }

  $done = Shot ('friends-done-' + (Get-Date -Format 'HHmmss') + '.png')
  "accepted hwnd=$Hwnd pid=$($script:procId) dialog=$dlg click=$okX,$okY shot=$done"
} finally {
  [WxFriend]::SetCursorPos($cur.X, $cur.Y)
  if ($fgBefore -ne [IntPtr]::Zero) { [void][WxFriend]::SetForegroundWindow($fgBefore) }
}
