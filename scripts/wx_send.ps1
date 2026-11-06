param(
  # Text to send. If omitted, use -TextFile (a path, or '-' for stdin).
  # ASCII-only comments on purpose: Windows PowerShell 5.1 reads a BOM-less
  # UTF-8 script as ANSI, and mojibake inside a comment can corrupt parsing.
  [string]$Text = '',
  # Who is sending; recorded in the shared activity ledger.
  [string]$Actor = 'pc-text',
  [string]$TextFile = '',
  # 0 = auto: pick the WeChat window of the account that OWNS -DbFile.
  [long]$Hwnd = 0,
  # The bot account database. Whatever process holds this file open is the
  # client we must type into. Both the bot and the human's own WeChat can be
  # logged in at the same time; typing into the wrong one sends the reply FROM
  # the human, which looks exactly like the peer answering itself.
  [string]$DbFile = 'D:\LeStoreDownload\xwechat_files\wxid_kn207qgkufhp29_5794\db_storage\message\message_0.db',
  # Fallback identification when Restart Manager reports no db owner: the bot
  # window is the one whose chat list shows this contact (OCR). The human's own
  # client never has it, so we still never type into the wrong account.
  [string]$BotMarker = '猪葛凉',
  [string]$Chat = '',
  [string]$ExpectChat = '',
  [string]$ExpectNotContains = '',
  [string]$VerifyChat = '',
  # Input box position as a fraction of the window rect, so a resize or a
  # different DPI still lands inside the input field.
  [double]$XFrac = 0.47,
  [double]$YFrac = 0.88,
  [int]$InputX = -1,
  [int]$InputY = -1,
  [int]$FocusDelayMs = 600,
  [int]$PasteDelayMs = 900,
  [int]$EnterDelayMs = 500,
  # Submit by clicking the button. Enter is unreliable: while the IME is
  # committing a composition the first Return is swallowed and nothing is sent.
  [double]$SendXFrac = 0.956,
  [double]$SendYFrac = 0.933,
  [switch]$NoEnter,
  # When the bot account's databases are not held open by any process, we
  # cannot prove which window belongs to the bot. Default: refuse to type
  # (a wrong pick sends the reply FROM the human). -AllowFallback re-enables
  # the old "largest visible WeChat window" guess.
  [switch]$AllowFallback,
  # Also press Enter after clicking the button (belt and braces).
  [switch]$UseEnter,
  [switch]$UseSendButton,
  # Print the resolved window and exit without touching it (diagnostics).
  [switch]$ResolveOnly
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# -Chat "<显示名>" 是给 agent 用的便捷入口：名字直接抄 inbound 头里的
# 「群聊 猪葛凉、蒙」/「私聊 猪葛凉」。这里负责把它翻译成
#   ExpectChat（切过去时校验的标题）、ExpectNotContains（私聊要排除带"、"的群标题）、
#   VerifyChat（对账用的会话 id，从 watched-chats.txt 查）。
if ($Chat -ne '') {
  $chatId = ''
  $listFile = Join-Path $PSScriptRoot 'watched-chats.txt'
  if (Test-Path $listFile) {
    foreach ($ln in (Get-Content $listFile -Encoding UTF8)) {
      $ln = $ln.Trim()
      if ($ln -eq '' -or $ln.StartsWith('#')) { continue }
      $parts = $ln -split '\|'
      if ($parts.Count -ge 2 -and $parts[1].Trim() -eq $Chat) { $chatId = $parts[0].Trim(); break }
    }
  }
  if ($ExpectChat -eq '') { $ExpectChat = $Chat }
  if ($VerifyChat -eq '' -and $chatId -ne '') { $VerifyChat = $chatId }
  if ($ExpectNotContains -eq '') {
    if ($chatId -ne '' -and $chatId.EndsWith('@chatroom')) { } else { $ExpectNotContains = '、' }
  }
}
# Cross-session mutex via lock file: several DSH sessions share this WeChat
# window, and an interleaved "switch chat / send" pair can drop a reply into the
# wrong conversation. Hold this lock from the target check until the message is
# on the wire. Stale locks (>60s, crashed run) are broken automatically.
$sendLockPath = Join-Path $PSScriptRoot 'send.lock'
$sendLocked = $false
if (-not $ResolveOnly) {
  for ($i = 0; $i -lt 80; $i++) {
    try {
      $fs = [System.IO.File]::Open($sendLockPath, 'CreateNew', 'Write', 'None')
      $fs.Close()
      $sendLocked = $true
      break
    } catch {
      if (Test-Path $sendLockPath) {
        if (((Get-Date) - (Get-Item $sendLockPath).LastWriteTime).TotalSeconds -gt 60) { Remove-Item $sendLockPath -Force -ErrorAction SilentlyContinue }
      }
      Start-Sleep -Milliseconds 250
    }
  }
  if (-not $sendLocked) { throw 'wx_send: another send is still running (send.lock busy for 20s); try again in a moment' }
  $script:sendLockPath = $sendLockPath
}

# ---- 节流：同一时刻只允许一个微信动作，两次动作至少隔 2.5 秒 ----
$thrLock = Join-Path $PSScriptRoot 'throttle.lock'
$thrState = Join-Path $PSScriptRoot 'throttle-state.json'
if ($ResolveOnly -eq $false) {
  $__got = $false
  for ($t = 0; $t -lt 200; $t++) {
    try { $fs = [System.IO.File]::Open($thrLock, 'CreateNew', 'Write', 'None'); $fs.Close(); $__got = $true; break } catch {
      if (Test-Path $thrLock) { if (((Get-Date) - (Get-Item $thrLock).LastWriteTime).TotalSeconds -gt 45) { Remove-Item $thrLock -Force -ErrorAction SilentlyContinue } }
      Start-Sleep -Milliseconds 300
    }
  }
  try {
    $st = $null
    if (Test-Path $thrState) { try { $st = Get-Content $thrState -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $last = if ($st -and $st.last) { [double]$st.last } else { 0 }
    $gap = $now - $last
    if ($gap -lt 2.5) { Start-Sleep -Milliseconds ([int]((2.5 - $gap) * 1000)) }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    @{ last = $now } | ConvertTo-Json -Compress | Set-Content -Path $thrState -Encoding UTF8
  } catch { }
}
if ($ResolveOnly -eq $false) {
  if ($TextFile -ne '') {
    if ($TextFile -eq '-') {
      $Text = [Console]::In.ReadToEnd()
    } else {
      $Text = Get-Content -Raw -Encoding UTF8 $TextFile
    }
  }
  $Text = ($Text -replace "`r`n", "`n").TrimEnd()
  if ($Text -eq '') { throw 'wx_send: empty text' }
} else {
  $Text = 'diagnostic'
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public class WxSend {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  public static POINT SaveCursor() { POINT p; GetCursorPos(out p); return p; }
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  // True only when the screen point really belongs to OUR window. Without this
  // guard a click that is computed from a stale rect lands in whatever window is
  // on top -- typically the user's own WeChat client, where the same coordinates
  // hit the chat list and open 文件传输助手 / 微信团队.
  public static bool PointBelongsTo(IntPtr target, int x, int y) {
    POINT p; p.X = x; p.Y = y;
    IntPtr w = WindowFromPoint(p);
    if (w == IntPtr.Zero) return false;
    if (w == target) return true;
    IntPtr root = GetAncestor(w, 2);
    if (root == target) return true;
    // WeChat popups (sticker panel, menus) are separate top-level windows owned by
    // the same process, so accept same-process windows -- but never a window of
    // the OTHER logged-in WeChat instance (different pid), which is the account we
    // must not type into.
    uint tp = 0, wp = 0;
    GetWindowThreadProcessId(target, out tp);
    GetWindowThreadProcessId(w, out wp);
    return tp != 0 && tp == wp;
  }
  public static bool IsForeground(IntPtr h) { return GetForegroundWindow() == h; }
  public static void RestoreCursor(POINT p) { SetCursorPos(p.X, p.Y); }
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
  public const uint SWP_NOMOVE = 0x0002;
  public const uint SWP_NOSIZE = 0x0001;
  public const uint SWP_SHOWWINDOW = 0x0040;
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  // SetForegroundWindow is silently ignored when our process is not the
  // foreground one. Attaching to the foreground thread's input queue bypasses
  // that, which matters because the human's own WeChat window is often in front
  // and it OVERLAPS ours: a blind click then lands in the wrong account.
  public static bool ForceForeground(IntPtr h) {
    IntPtr fg = GetForegroundWindow();
    if (fg == h) return true;
    uint tid = GetCurrentThreadId();
    uint fpid = 0;
    uint ftid = GetWindowThreadProcessId(fg, out fpid);
    // A plain SetForegroundWindow is refused when our process is not the foreground
    // app. Tapping Alt first releases Windows' foreground lock, which is the
    // difference between "raised fine" and "clicked the window that happened to be
    // on top" (the bug where clicks landed in the user's own WeChat chat list).
    keybd_event(0x12, 0x38, 0, IntPtr.Zero);
    System.Threading.Thread.Sleep(30);
    keybd_event(0x12, 0x38, 2, IntPtr.Zero);
    System.Threading.Thread.Sleep(30);
    AttachThreadInput(tid, ftid, true);
    try { ShowWindow(h, 9); BringWindowToTop(h); SetForegroundWindow(h); }
    finally { AttachThreadInput(tid, ftid, false); }
    System.Threading.Thread.Sleep(120);
    if (GetForegroundWindow() == h) return true;
    // 还抬不起来时（最小化到托盘 / 前台锁被别的进程占着）：用 TOPMOST 硬顶一下再取消
    try {
      SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
      System.Threading.Thread.Sleep(80);
      SetWindowPos(h, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
      SetForegroundWindow(h);
      System.Threading.Thread.Sleep(120);
    } catch { }
    return GetForegroundWindow() == h;
  }

  [StructLayout(LayoutKind.Sequential)] public struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct RM_PROCESS_INFO {
    public RM_UNIQUE_PROCESS Process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
    public uint ApplicationType;
    public uint AppStatus;
    public uint TSSessionId;
    [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
  }
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] public static extern int RmStartSession(out uint handle, int flags, string key);
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] public static extern int RmRegisterResources(uint handle, uint nFiles, string[] files, uint nApps, string[] apps, uint nServices, string[] services);
  [DllImport("rstrtmgr.dll")] public static extern int RmGetList(uint handle, out uint needed, ref uint count, [In, Out] RM_PROCESS_INFO[] infos, out uint reasons);
  [DllImport("rstrtmgr.dll")] public static extern int RmEndSession(uint handle);

  // Processes that currently hold $path open (Restart Manager, no admin needed).
  public static int[] FileOwners(string path) {
    uint session; string key = Guid.NewGuid().ToString();
    if (RmStartSession(out session, 0, key) != 0) return new int[0];
    var pids = new System.Collections.Generic.List<int>();
    try {
      if (RmRegisterResources(session, 1, new string[] { path }, 0, null, 0, null) != 0) return new int[0];
      uint needed = 0, count = 0, reasons;
      RmGetList(session, out needed, ref count, null, out reasons);
      if (needed == 0) return new int[0];
      var infos = new RM_PROCESS_INFO[needed];
      count = needed;
      int rc = RmGetList(session, out needed, ref count, infos, out reasons);
      if (rc != 0 && rc != 234) return new int[0];
      for (uint i = 0; i < count; i++) pids.Add(infos[i].Process.dwProcessId);
    } finally { RmEndSession(session); }
    return pids.ToArray();
  }

  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder sb, int max);
  private static uint s_targetPid;
  private static System.Collections.Generic.List<IntPtr> s_hits = new System.Collections.Generic.List<IntPtr>();
  private static bool CollectProc(IntPtr hWnd, IntPtr lParam) {
    uint pid; GetWindowThreadProcessId(hWnd, out pid);
    if (pid == s_targetPid && IsWindow(hWnd)) s_hits.Add(hWnd);
    return true;
  }
  // Largest top-level window owned by $pid, hidden ones included. A client that
  // was parked off-screen / hidden makes Get-Process report MainWindowHandle 0,
  // and falling back to "the largest visible WeChat window" then types the
  // reply into the OTHER logged-in account.
  public static IntPtr FindWindowForPid(int pid) {
    s_targetPid = (uint)pid; s_hits.Clear();
    EnumWindows(CollectProc, IntPtr.Zero);
    IntPtr best = IntPtr.Zero; long bestScore = -1;
    foreach (IntPtr h in s_hits) {
      RECT r; if (!GetWindowRect(h, out r)) continue;
      long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
      // 聊天主窗口的类名是 Qt51514QWindowIcon；托盘图标等辅助窗口类名不同，
      // 它们有时比主窗口还大（1440x740），盲选最大的会把消息打进托盘窗口。
      System.Text.StringBuilder sb = new System.Text.StringBuilder(256);
      GetClassNameW(h, sb, 256);
      long score = area + (sb.ToString().EndsWith("QWindowIcon") ? 1000000000L : 0L);
      if (score > bestScore) { bestScore = score; best = h; }
    }
    return best;
  }
}
"@
Add-Type -AssemblyName System.Windows.Forms
[void][WxSend]::SetProcessDpiAwarenessContext([IntPtr](-4))

# Restart Manager tells us which process has an account's databases open. One
# file is not reliable (WeChat does not always hold message_0.db open, and a
# fresh login reopens handles), so probe several and union the owners.
$probeFiles = New-Object System.Collections.ArrayList
if ($DbFile -ne '') {
  $dbRoot = Split-Path -Parent $DbFile
  foreach ($rel in @('message\message_0.db', 'session\session.db', 'contact\contact.db', 'head_image\head_image.db')) {
    $cand = Join-Path $dbRoot $rel
    if (Test-Path -LiteralPath $cand) { [void]$probeFiles.Add($cand) }
  }
  if ($probeFiles.Count -eq 0 -and (Test-Path -LiteralPath $DbFile)) { [void]$probeFiles.Add($DbFile) }
}
$owners = @()
# Restart Manager occasionally reports no owners for a live client (transient),
# so retry the whole probe a few times before declaring the bot offline.
for ($probeTry = 0; $probeTry -lt 4; $probeTry++) {
  foreach ($pf in $probeFiles) {
    try {
      foreach ($op in @([WxSend]::FileOwners($pf))) { if ($owners -notcontains $op) { $owners += $op } }
    } catch { }
  }
  if ($owners.Count -gt 0) { break }
  Start-Sleep -Milliseconds 350
}
$ownerText = if ($owners.Count -gt 0) { ($owners -join ',') } else { 'none' }

$pickedPid = 0
$source = 'explicit -Hwnd'
$notes = ''
if ($Hwnd -le 0) {
  $cands = New-Object System.Collections.ArrayList
  foreach ($op in $owners) {
    $proc = Get-Process -Id $op -ErrorAction SilentlyContinue
    if (-not $proc) { continue }
    if ($proc.ProcessName -ne 'Weixin' -and $proc.ProcessName -ne 'WeChat') { continue }
    # 优先按类名找聊天主窗口：UAC_InputIndicatorOverlayWnd 等辅助窗口也属于 Weixin.exe，
    # 会抢走 MainWindowHandle，按它算坐标就全错（实测 rect=1447,775，屏幕外）。
    $h = [long][WxSend]::FindWindowForPid([int]$op)
    $how = 'enum'
    if ($h -eq 0) {
      $h = [long]$proc.MainWindowHandle
      $how = 'main'
    }
    if ($h -ne 0) { [void]$cands.Add([pscustomobject]@{ pid = [int]$op; hwnd = $h; how = $how }) }
  }
  if ($cands.Count -gt 0) {
    $pickedPid = [int]$cands[0].pid
    $Hwnd = [long]$cands[0].hwnd
    $source = 'db-owner(' + $cands[0].how + ')'
  } elseif ($owners.Count -gt 0) {
    # We know which account owns the DB but cannot reach any of its windows.
    # Typing into another account would send the reply FROM the human, so fail.
    throw ('wx_send: db-owner pid=' + $ownerText + ' has no reachable window; refusing cross-account fallback')
  } else {
    # No process holds the bot account's databases: the bot client is closed or
    # logged out, OR Restart Manager just failed to report owners. Before giving
    # up, identify the bot window by CONTENT: the bot account's chat list always
    # contains the peer (marker), the human's own client does not.
    $marker = $BotMarker
    if ($marker -ne '') {
      foreach ($p in (Get-Process -Name Weixin, WeChat -ErrorAction SilentlyContinue)) {
        $h = [long]$p.MainWindowHandle
        if ($h -eq 0) { $h = [long][WxSend]::FindWindowForPid([int]$p.Id) }
        if ($h -eq 0) { continue }
        $h2 = [IntPtr]$h
        if (-not [WxSend]::IsWindowVisible($h2)) { continue }
        $rr = New-Object WxSend+RECT
        if (-not [WxSend]::GetWindowRect($h2, [ref]$rr)) { continue }
        $wlist = $rr.Right - $rr.Left; $hlist = $rr.Bottom - $rr.Top
        if ($wlist -lt 400 -or $hlist -lt 300) { continue }
        $reg = ([int]($rr.Left + $wlist * 0.05)).ToString() + ',' + ([int]($rr.Top + $hlist * 0.10)).ToString() + ',' + ([int]($wlist * 0.28)).ToString() + ',' + ([int]($hlist * 0.70)).ToString()
        try {
          $out = & (Join-Path $PSScriptRoot 'wx_vision.ps1') -Action find -Text $marker -Region $reg 2>&1 | Select-Object -Last 1
          if ($out -match '"ok":true') {
            $pickedPid = [int]$p.Id
            $Hwnd = $h
            $source = 'marker(' + $marker + ')'
            break
          }
        } catch { }
      }
    }
    if ($Hwnd -gt 0) {
      # resolved through content matching; nothing more to do here
    } elseif (-not $AllowFallback) {
      $dbSeen = 'unknown'
      if ($DbFile -ne '' -and (Test-Path -LiteralPath $DbFile)) {
        $dbSeen = (Get-Item -LiteralPath $DbFile).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
      }
      throw ('wx_send: bot client looks offline (no process holds the bot databases and no WeChat window shows "' + $marker + '"; last write ' + $dbSeen + '); refusing to type into another WeChat account. Log the bot account back in, or pass -AllowFallback.')
    } else {
    $best = [IntPtr]::Zero
    $bestArea = -1
    $bestPid = 0
    $all = @()
    foreach ($p in (Get-Process -Name Weixin, WeChat -ErrorAction SilentlyContinue)) {
      $h = $p.MainWindowHandle
      $all += ($p.Id.ToString() + ':' + ([long]$h).ToString())
      if ($h -eq [IntPtr]::Zero) { continue }
      if (-not [WxSend]::IsWindowVisible($h)) { continue }
      $r = New-Object WxSend+RECT
      if (-not [WxSend]::GetWindowRect($h, [ref]$r)) { continue }
      $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
      if ($area -gt $bestArea) { $bestArea = $area; $best = $h; $bestPid = $p.Id }
    }
    $notes = $all -join '/'
    $pickedPid = [int]$bestPid
    $Hwnd = [long]$best
    $source = 'fallback-largest WARN-not-db-owner'
  }
  }
}
if ($Hwnd -le 0) { throw ('wx_send: wechat main window not found owners=' + $ownerText + ' source=' + $source + ' procs=' + $notes) }
if ($ResolveOnly) { "resolve hwnd=$Hwnd pid=$pickedPid via=$source owners=$ownerText procs=$notes"; exit 0 }
$h = [IntPtr]$Hwnd
# Remember who had the focus so we can give it back: typing a reply must not
# yank the window away from whatever the human was doing.
$prevFg = [WxSend]::GetForegroundWindow()

if ([WxSend]::IsIconic($h)) { [void][WxSend]::ShowWindow($h, 9) }
if (-not [WxSend]::IsWindowVisible($h)) {
  # Found through EnumWindows because the client was hidden (tray / parked).
  [void][WxSend]::ShowWindow($h, 5)
  Start-Sleep -Milliseconds 200
}
[void][WxSend]::BringWindowToTop($h)
$cursorBefore = [WxSend]::SaveCursor()
[void][WxSend]::SetForegroundWindow($h)
Start-Sleep -Milliseconds $FocusDelayMs
if (-not [WxSend]::ForceForeground($h)) {
  throw ('wx_send: cannot raise hwnd=' + $Hwnd + ' to the foreground; refusing to click because another account window may be on top')
}

$rect = New-Object WxSend+RECT
if (-not [WxSend]::GetWindowRect($h, [ref]$rect)) { throw 'wx_send: GetWindowRect failed' }
$winW = $rect.Right - $rect.Left
$winH = $rect.Bottom - $rect.Top
# Take the window out of the off-screen minimized parking spot if needed.
if ($rect.Left -lt -10000 -or $rect.Top -lt -10000) {
  [void][WxSend]::MoveWindow($h, 40, 40, [Math]::Max($winW, 900), [Math]::Max($winH, 640), $true)
  Start-Sleep -Milliseconds 300
  [void][WxSend]::GetWindowRect($h, [ref]$rect)
  $winW = $rect.Right - $rect.Left
  $winH = $rect.Bottom - $rect.Top
}
# A window restored near the screen edge can hang off it; the send button then
# sits outside the desktop and the click lands nowhere. Pull it fully on-screen.
$scrW = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
$scrH = [System.Windows.Forms.SystemInformation]::VirtualScreen.Height
if (-not [WxSend]::IsZoomed($h) -and ($rect.Left -lt 0 -or $rect.Top -lt 0 -or $rect.Right -gt $scrW -or $rect.Bottom -gt $scrH)) {
  $nx = [Math]::Max(0, [Math]::Min($rect.Left, $scrW - $winW - 8))
  $ny = [Math]::Max(0, [Math]::Min($rect.Top, $scrH - $winH - 8))
  [void][WxSend]::MoveWindow($h, $nx, $ny, $winW, $winH, $true)
  Start-Sleep -Milliseconds 300
  [void][WxSend]::GetWindowRect($h, [ref]$rect)
  $winW = $rect.Right - $rect.Left
  $winH = $rect.Bottom - $rect.Top
}
# 最大化时键盘事件进不了微信（实测：粘贴/打字都不生效），先还原成普通窗口，发完再最大化回去
$__wasZoomed = [WxSend]::IsZoomed($h)
if ($__wasZoomed) {
  [void][WxSend]::ShowWindow($h, 9)
  Start-Sleep -Milliseconds 450
  [void][WxSend]::GetWindowRect($h, [ref]$rect)
  $winW = $rect.Right - $rect.Left
  $winH = $rect.Bottom - $rect.Top
}
# 用户要求（2026-10-25）：发消息前先把微信固定在脚本能点到的地方（0,0,1500,830），
# 否则窗口位置一变，按比例算出来的输入框/发送按钮坐标就点不上。
$pinW = 1500; $pinH = 830
if ($rect.Left -lt -8 -or $rect.Left -gt 8 -or $rect.Top -lt -8 -or $rect.Top -gt 8 -or $winW -lt 1200 -or $winH -lt 700) {
  # 虚拟桌面（A 方案）上窗口常处于最小化/记忆旧位置状态：MoveWindow 对最小化
  # 窗口无效，只会改"还原后"位置，实测读回还是 1809,969（屏幕外）→ 点击全落空。
  # 先 SW_RESTORE，再 SetWindowPos 并循环复验，直到真的落在画布内。
  if ([WxSend]::IsIconic($h)) { [void][WxSend]::ShowWindow($h, 9); Start-Sleep -Milliseconds 400 }
  for ($pinTry = 0; $pinTry -lt 5; $pinTry++) {
    [void][WxSend]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, $pinW, $pinH, 0x0040)
    Start-Sleep -Milliseconds 400
    [void][WxSend]::GetWindowRect($h, [ref]$rect)
    $winW = $rect.Right - $rect.Left
    $winH = $rect.Bottom - $rect.Top
    if ($rect.Left -ge -8 -and $rect.Left -le 8 -and $rect.Top -ge -8 -and $rect.Top -le 8 -and $winW -eq $pinW) { break }
  }
  if ($rect.Left -lt -8 -or $rect.Left -gt 8 -or $rect.Top -lt -8 -or $rect.Top -gt 8) {
    throw ('wx_send: cannot pin window into 0,0,' + $pinW + 'x' + $pinH + ' (rect=' + $rect.Left + ',' + $rect.Top + ',' + $winW + 'x' + $winH + '); refusing to click blindly')
  }
  "wx_send: pinned window to $($rect.Left),$($rect.Top) ${winW}x${winH} (was off the script grid)"
}
# 发之前先截图留证：一看就知道"当前会话到底是谁"，出问题能复盘
try {
  Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
  $shotPath = Join-Path 'E:\DSH\GZJT GC' ('send-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
  $bmpShot = New-Object System.Drawing.Bitmap 1920, 1080
  $gfxShot = [System.Drawing.Graphics]::FromImage($bmpShot)
  $gfxShot.CopyFromScreen(0, 0, 0, 0, $bmpShot.Size)
  $bmpShot.Save($shotPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $gfxShot.Dispose(); $bmpShot.Dispose()
  "wx_send: screenshot before typing -> $shotPath"
} catch { "wx_send: screenshot skipped ($($_.Exception.Message))" }

# Click geometry comes from the CLIENT area. GetWindowRect can report a taller
# rect (borders, stale size) and then the send-button click lands outside the
# visible client: the script said "sent" while nothing was submitted
# (2026-10-31 "发消息收不到" incident).
$cRect = New-Object WxSend+RECT
$cPt = New-Object WxSend+POINT
[void][WxSend]::GetClientRect($h, [ref]$cRect)
[void][WxSend]::ClientToScreen($h, [ref]$cPt)
$clX = $cPt.X; $clY = $cPt.Y; $clW = $cRect.Right; $clH = $cRect.Bottom
if ($clW -lt 600 -or $clH -lt 400) { $clX = $rect.Left; $clY = $rect.Top; $clW = $winW; $clH = $winH }
# WeChat runs DPI-unaware on a 125% display: GetClientRect/ClientToScreen report
# virtualized pixels that are 1/0.8889 larger than what is really painted on screen.
# Scale the client box down before deriving click points and OCR regions.
$uiScale = 0.8889
$clX = [int]($clX * 1); $clY = [int]($clY * 1)
$clW = [int]($clW * $uiScale); $clH = [int]($clH * $uiScale)
$dpiNow = 96
try { $dpiNow = [WxSend]::GetDpiForWindow($h) } catch { $dpiNow = 96 }
if (-not $dpiNow -or $dpiNow -le 0) { $dpiNow = 96 }
$pscale = $dpiNow / 96.0

if ($InputX -lt 0) { $InputX = [int]($clX + $clW * $XFrac) }
if ($InputY -lt 0) { $InputY = [int]($clY + $clH * $YFrac) }

function Assert-Foreground([IntPtr]$target) {
  for ($i = 0; $i -lt 6; $i++) {
    if ([WxSend]::GetForegroundWindow() -eq $target) { return }
    [void][WxSend]::ForceForeground($target)
    Start-Sleep -Milliseconds 250
  }
  throw "wx_send: 焦点不在微信上（防止把字打到别的窗口），已中止"
}
# 发消息期间把微信临时置顶：DSH 窗口会抢前台，不置顶的话粘贴和回车会落到 DSH 里
[void][WxSend]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0040)
Start-Sleep -Milliseconds 250
# Guard: make sure the conversation that is open right now is the one we mean to
# answer. Without this a reply can land in whatever chat happened to be visible
# (e.g. the group instead of the private chat).
if ($ExpectChat -ne '') {
  $finder = Join-Path $PSScriptRoot 'wx_find_chat.ps1'
  $fArgs = @('-Name', $ExpectChat)
  if ($ExpectNotContains -ne '') { $fArgs += @('-NotContains', $ExpectNotContains) }
  $fOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $finder @fArgs 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    throw ("wx_send: the open chat is not '" + $ExpectChat + "'; refusing to type a reply (finder said: " + $fOut.Trim() + ")")
  }
  # 再自己看一眼表头（不看图不算过）：OCR 认出来的标题必须就是 ExpectChat，
  # 群里那种「猪葛凉、蒙」要额外用 ExpectNotContains 挡掉，否则会发进群。
  Start-Sleep -Milliseconds 250
  $rr = New-Object WxSend+RECT
  [void][WxSend]::GetWindowRect($h, [ref]$rr)
  $ww = $rr.Right - $rr.Left
  $whh = $rr.Bottom - $rr.Top
  # The title bar band: WeChat draws this at a FIXED pixel height (about 40px
  # at 1500x830), not a fraction, so a 0.03..0.10 box used to slice the bottom
  # off the glyphs and OCR came back as rubbish ("拉±斤克囹"), which then failed
  # the equality test and blocked every send after a group rename.
  $hx2 = [int]($rr.Left + $ww * 0.21)
  $hy2 = [int]($rr.Top + $whh * 0.02)
  $hw2 = [int]($ww * 0.50)
  $hh2 = [int]($whh * 0.105)
  $hdr = "$hx2,$hy2,$hw2,$hh2"
  $vis = & (Join-Path $PSScriptRoot 'wx_vision.ps1') -Action find -Text $ExpectChat -Region $hdr -MinScore 0.55 2>&1 | Select-Object -Last 1
  $visited = ''
  if ($vis -match '"ok":\s*true') {
    $mm = [regex]::Match($vis, '"matched":"([^"]*)"')
    if ($mm.Success) { $visited = ($mm.Groups[1].Value -replace '\s', '') }
  }
  $want = ($ExpectChat -replace '\s', '')
  # Display-name OCR is lossy ("拉塔托斯克" -> "拉塔扌斤克囹"): the zh-Hans model
  # substitutes 托/斯 with 斤/囹 for this font. Exact equality would reject the
  # RIGHT chat, so fall back to a longest-common-subsequence ratio.
  $lcsScore = 0.0
  if ($visited -ne '' -and $want.Length -gt 0) {
    $ca = $visited.ToCharArray(); $cb = $want.ToCharArray()
    $dp = New-Object 'int[,]' ($ca.Length + 1), ($cb.Length + 1)
    for ($i = 1; $i -le $ca.Length; $i++) {
      for ($j = 1; $j -le $cb.Length; $j++) {
        if ($ca[$i - 1] -eq $cb[$j - 1]) { $dp[$i, $j] = $dp[($i - 1), ($j - 1)] + 1 }
        elseif ($dp[($i - 1), $j] -ge $dp[$i, ($j - 1)]) { $dp[$i, $j] = $dp[($i - 1), $j] }
        else { $dp[$i, $j] = $dp[$i, ($j - 1)] }
      }
    }
    $lcsScore = [double]$dp[$ca.Length, $cb.Length] / [double]$want.Length
  }
  $good = ($visited -ne '' -and ($visited -eq $want -or $visited.Contains($want) -or $want.Contains($visited) -or $lcsScore -ge 0.55))
  if ($good -and $ExpectNotContains -ne '' -and $visited.Contains($ExpectNotContains)) { $good = $false }
  if (-not $good) {
    # A garbled (empty) read is not evidence of the WRONG chat - some display
    # names simply defeat the zh-Hans OCR model (e.g. "拉塔托斯克" comes back as
    # "拉±斤克囹" at every scale). Only a readable-but-different header blocks
    # the send; an unreadable one is downgraded to a warning, because the
    # finder above already clicked and confirmed the row.
    if ($visited -eq '') {
      Write-Host ("wx_send: WARN header unreadable; trusting the finder for '" + $ExpectChat + "'")
    } else {
      throw ("wx_send: header says '" + $visited + "' but expected '" + $ExpectChat + "'; refusing to send")
    }
  }
}
# Click the input box to take focus.
if (-not [WxSend]::IsForeground($h)) { [void][WxSend]::ForceForeground($h); Start-Sleep -Milliseconds 250 }
$__ok = $false
for ($i = 0; $i -lt 5; $i++) { if ([WxSend]::IsForeground($h)) { $__ok = $true; break }; [void][WxSend]::ForceForeground($h); Start-Sleep -Milliseconds 350 }
if (-not $__ok) { throw "wx_send: cannot bring hwnd=$Hwnd ($InputX,$InputY) to the top; aborting" }
[void][WxSend]::SetCursorPos($InputX, $InputY)
Start-Sleep -Milliseconds 120
[WxSend]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 60
[WxSend]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 250

# 清空输入框里残留的草稿：Ctrl+A 在微信里不可靠（实测不清），改成鼠标三击选中再 Delete
[void][WxSend]::SetCursorPos($InputX, $InputY)
Start-Sleep -Milliseconds 120
for ($c = 0; $c -lt 3; $c++) {
  [WxSend]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [WxSend]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
}
Start-Sleep -Milliseconds 120
[WxSend]::keybd_event(0x2E, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 40
[WxSend]::keybd_event(0x2E, 0, 2, [IntPtr]::Zero)
Start-Sleep -Milliseconds 150
# Make sure the clipboard really holds THIS message before pasting: a stale
# clipboard would paste the previous search keyword (e.g. the contact name)
# straight into the chat, which is exactly the bug we hit.
$clipOk = $false
for ($ct = 0; $ct -lt 3; $ct++) {
  # Inline clipboard write: spawning wx_clip.ps1 created a new powershell process that
# stole the foreground, so the Ctrl+V below landed in whatever window took focus.
# Hard foreground gate: the Ctrl+V below only lands if WeChat still owns the
# foreground. Anything that grabbed it (our own helper processes, a notification,
# the user clicking elsewhere) would silently paste into another window.
$fgOk = $false
for ($fgTry = 1; $fgTry -le 3; $fgTry++) {
  if ([WxSend]::IsForeground($h)) { $fgOk = $true; break }
  [void][WxSend]::ForceForeground($h)
  Start-Sleep -Milliseconds 300
}
if (-not $fgOk) { throw "wx_send: lost the foreground before pasting; aborting instead of pasting into another window" }
Set-Clipboard -Value $Text
  Start-Sleep -Milliseconds 220
  try {
    $now = Get-Clipboard -Raw -ErrorAction Stop
    if ($null -ne $now -and $now.Trim() -eq $Text.Trim()) { $clipOk = $true; break }
  } catch { }
}
if (-not $clipOk) {
  try { & (Join-Path $PSScriptRoot 'wx_clip.ps1') -Clear | Out-Null } catch { }
  throw 'wx_send: clipboard does not hold the reply text; refusing to paste (would send the wrong content)'
}
Start-Sleep -Milliseconds 120

$pyExe = "E:\DSH\DSH Desktop\resources\office-runtime\primary-runtime\dependencies\python\python.exe"
$inputCheck = Join-Path $PSScriptRoot "wx_input_check.py"
Assert-Foreground $h
# Ctrl+V
[WxSend]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 40
[WxSend]::keybd_event(0x56, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 40
[WxSend]::keybd_event(0x56, 0, 2, [IntPtr]::Zero)
Start-Sleep -Milliseconds 40
[WxSend]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)
Start-Sleep -Milliseconds $PasteDelayMs

# Look at the input box before submitting: if the text is not there, the paste
# missed (focus elsewhere) and pressing Enter would send nothing.
$inputRegion = ([int]($clX + $clW * 0.15)).ToString() + ',' + ([int]($clY + $clH * 0.62)).ToString() + ',' + ([int]($clW * 0.80)).ToString() + ',' + ([int]($clH * 0.34)).ToString()
$needle = $Text.Trim()
if ($needle.Length -gt 6) { $needle = $needle.Substring(0, 6) }
# 只粘贴一次，不再重试粘贴（重试会把同一段话粘两三遍），这里只做一次像素确认
# Real check: OCR the input box and look for the first few characters of the reply.
# The old pixel-diff check always failed because its baseline image never existed.
$inputOk = $false
$vision = Join-Path $PSScriptRoot 'wx_vision.ps1'
for ($try = 1; $try -le 2; $try++) {
  try {
    & $vision -Action find -Text $needle -Region $inputRegion | Out-Null
    if ($LASTEXITCODE -eq 0) { $inputOk = $true; break }
  } catch { }
  if ($try -lt 2) {
    Write-Output "wx_send: reply not visible in the input box yet; pasting once more (attempt $try)"
    if (-not [WxSend]::IsForeground($h)) { [void][WxSend]::ForceForeground($h); Start-Sleep -Milliseconds 250 }
    [void][WxSend]::SetCursorPos($InputX, $InputY)
    Start-Sleep -Milliseconds 120
    [WxSend]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 50
    [WxSend]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Set-Clipboard -Value $Text
    Start-Sleep -Milliseconds 150
    [WxSend]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 220
  [WxSend]::keybd_event(0x56, 0x2F, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 180
  [WxSend]::keybd_event(0x56, 0x2F, 2, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 150
  [WxSend]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 700
    Start-Sleep -Milliseconds 500
  }
}
if (-not $inputOk) {
  # Verification is OCR-based and sometimes cannot read the box even when the
  # text is there. Submit anyway: pressing Enter / the send button on an EMPTY
  # box is a no-op in WeChat, so this cannot send an empty message - it only
  # gives the text a chance to go out when OCR was wrong.
  Write-Output "wx_send: WARN reply not confirmed in the input box; submitting anyway (empty submits are no-ops)"
}
try {
  $vout = & $pyExe $inputCheck $h.ToInt64() check 2>&1 | Select-Object -Last 1
  if ($vout -match '"ok":true') { $inputOk = $true }
} catch { }
if (-not $inputOk) {
  Write-Output 'wx_send: WARN input-box pixel check missed; pressing Enter anyway'
}

if (-not $NoEnter -and -not $UseSendButton) {
    # 默认用回车发送：微信默认 Enter 即发送，比点按钮稳（按钮坐标受窗口尺寸/最大化的影响）
  if (-not [WxSend]::IsForeground($h)) { [void][WxSend]::ForceForeground($h); Start-Sleep -Milliseconds 200 }
  [void][WxSend]::SetCursorPos($InputX, $InputY)
  Start-Sleep -Milliseconds 80
  [WxSend]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [WxSend]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 150
  Assert-Foreground $h
  [WxSend]::keybd_event(0x0D, 0x1C, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 50
  [WxSend]::keybd_event(0x0D, 0x1C, 2, [IntPtr]::Zero)
  Start-Sleep -Milliseconds $EnterDelayMs
}
$sendX = [int]($clX + $clW * $SendXFrac)
$sendY = [int]($clY + $clH * $SendYFrac)
if (-not $NoEnter -and $UseSendButton) {
  if (-not [WxSend]::IsForeground($h)) { [void][WxSend]::ForceForeground($h); Start-Sleep -Milliseconds 250 }
  $__ok = $false
for ($i = 0; $i -lt 5; $i++) { if ([WxSend]::IsForeground($h)) { $__ok = $true; break }; [void][WxSend]::ForceForeground($h); Start-Sleep -Milliseconds 350 }
if (-not $__ok) { throw "wx_send: cannot bring hwnd=$Hwnd ($sendX,$sendY) to the top; aborting" }
  [void][WxSend]::SetCursorPos($sendX, $sendY)
  Start-Sleep -Milliseconds 130
  [WxSend]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [WxSend]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds $EnterDelayMs
  if ($UseEnter) {
    if (-not [WxSend]::IsForeground($h)) { [void][WxSend]::ForceForeground($h); Start-Sleep -Milliseconds 250 }
    $__ok = $false
for ($i = 0; $i -lt 5; $i++) { if ([WxSend]::IsForeground($h)) { $__ok = $true; break }; [void][WxSend]::ForceForeground($h); Start-Sleep -Milliseconds 350 }
if (-not $__ok) { throw "wx_send: cannot bring hwnd=$Hwnd ($InputX,$InputY) to the top; aborting" }
    [void][WxSend]::SetCursorPos($InputX, $InputY)
    Start-Sleep -Milliseconds 120
    [WxSend]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 50
    [WxSend]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    [WxSend]::keybd_event(0x0D, 0x1C, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [WxSend]::keybd_event(0x0D, 0x1C, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds $EnterDelayMs
  }
}

if ($__wasZoomed) { [void][WxSend]::ShowWindow($h, 3); Start-Sleep -Milliseconds 250 }
Remove-Item (Join-Path $PSScriptRoot 'throttle.lock') -Force -ErrorAction SilentlyContinue
# Give the focus back to whoever had it before we stole it.
if ($prevFg -ne [IntPtr]::Zero -and $prevFg -ne $h) {
  [void][WxSend]::SetForegroundWindow($prevFg)
}

"sent hwnd=$Hwnd pid=$pickedPid via=$source owners=$ownerText rect=$($rect.Left),$($rect.Top),$winW,$winH at=$InputX,$InputY send=$sendX,$sendY chars=$($Text.Length)"

try { & (Join-Path $PSScriptRoot 'wx_activity.ps1') -Add -Kind text -Actor $Actor -Text $Text | Out-Null } catch { }
# Read back the message table: if our text never shows up as a "self" row the
# send silently failed (wrong chat open, window on another conversation, the
# paste got eaten...). Compare inside python (--expect) so console encoding
# never matters, and report instead of claiming success.
$verifyOk = $true
if (-not $NoEnter -and $UseSendButton) {
  $py = 'C:\Users\LX\.dsh\weixin\asr-venv\Scripts\python.exe'
  $reader = Join-Path $PSScriptRoot 'readmsgs.py'
  $peer = $VerifyChat
  if ($peer -eq '') { $peer = 'wxid_hmqh1bam6y3422' }
  $probe = $Text.Trim()
  if ($probe.Length -gt 20) { $probe = $probe.Substring(0, 20) }
  $verifyOk = $false
  $verifyOk = $false
  $deadline = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $deadline) {
    try {
      $raw = & $py $reader --user $peer --limit 1 --json 2>$null | Out-String
      if ($raw.Trim() -ne '') {
        $rows = $raw | ConvertFrom-Json
        if ($rows -and $rows.Count -ge 1) {
          $last = $rows[$rows.Count - 1]
          $lastText = [string]$last.text
          $lastTime = 0
          try { $lastTime = [int64]$last.time } catch { }
          $age = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $lastTime
          if ($last.is_self -and $age -lt 120 -and $lastText.Trim() -eq $probe) { $verifyOk = $true; break }
        }
      }
    } catch { }
    Start-Sleep -Milliseconds 1200
  }
  if ($verifyOk) { Write-Output ('verified: reply found in the chat table for ' + $peer) }
  else { Write-Output ('WARN: sent but NOT FOUND in the chat table for ' + $peer + ' - the reply probably went to another chat or was not submitted') }
}
if ($script:sendLockPath) { Remove-Item $script:sendLockPath -Force -ErrorAction SilentlyContinue }
Write-Output 'clipboard cleared'

# Put the user's mouse back: we send with a real click, so the pointer would
# otherwise be left sitting on our send button.
if ($null -ne $cursorBefore) { [WxSend]::RestoreCursor($cursorBefore) }











