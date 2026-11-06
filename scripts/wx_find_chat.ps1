<#
wx_find_chat.ps1 - open a conversation by LOOKING at the chat list (OCR) and
clicking the row, instead of typing into the search box.

Usage:
  wx_find_chat.ps1 -Name "猪葛凉、蒙"
  wx_find_chat.ps1 -Name "猪葛凉" -NotContains "、"
  wx_find_chat.ps1 -Name "猪葛凉、蒙" -Json

Exit codes: 0 = on the target chat, 1 = could not get there.
Keep the UTF-8 BOM: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
#>
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [double]$MinScore = 0.55,
  [int]$Scale = 3,
  [switch]$Json,
  [string]$NotContains = '',
  [switch]$NoRaise
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$vision = Join-Path $here 'wx_vision.ps1'
$send = Join-Path $here 'wx_send.ps1'
$cacheFile = Join-Path $here 'last-open-chat.txt'
$cachedHwnd = ''

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxFc {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint fl, IntPtr ex);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  public static bool Raise(IntPtr h) {
    keybd_event(0x12, 0x38, 0, IntPtr.Zero);
    keybd_event(0x12, 0x38, 2, IntPtr.Zero);
    ShowWindow(h, 9);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    return GetForegroundWindow() == h;
  }
}
"@
[void][WxFc]::SetProcessDpiAwarenessContext([IntPtr](-4))

function Resolve-BotWindow {
  $raw = & $send -ResolveOnly 2>&1 | Out-String
  $m = [regex]::Match($raw, 'resolve hwnd=(\d+) pid=(\d+) via=(\S+)')
  if (-not $m.Success) { throw ('wx_find_chat: cannot resolve the bot window: ' + $raw.Trim()) }
  return [pscustomobject]@{ Hwnd = [int64]$m.Groups[1].Value; ProcId = $m.Groups[2].Value; Via = $m.Groups[3].Value }
}

function Get-Rect([IntPtr]$h) {
  $r = New-Object WxFc+RECT
  [void][WxFc]::GetWindowRect($h, [ref]$r)
  return $r
}

function Run-Vision {
  param([string[]]$ArgList)
  $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $vision @ArgList 2>&1 | Out-String
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Norm-Title([string]$s) {
  if ($null -eq $s) { return '' }
  $x = ($s -replace '\s', '')
  $x = $x -replace '[、，,]', ''
  $x = $x -replace '\(\d+\)', ''
  $x = $x -replace '（\d+）', ''
  return $x
}

function Score-Line([string]$line, [string]$needle) {
  $a = Norm-Title $line
  $b = Norm-Title $needle
  if ($b -eq '') { return 0.0 }
  if ($a -eq $b) { return 1.0 }
  if ($a.StartsWith($b) -or $b.StartsWith($a)) { return 0.9 }
  $i = 0
  foreach ($ch in $b.ToCharArray()) {
    $idx = $a.IndexOf($ch, $i)
    if ($idx -ge 0) { $i = $idx + 1 }
  }
  return [double]$i / [double]$b.Length
}

# Mode A (virtual desktop): the bot client's window lives on a *different*
# desktop, so it is invisible from here and resolving it must fail. In that
# case do not fail the whole call: the A-scheme sender (wx_vdesk_client.ps1)
# switches the conversation inside the virtual desktop while sending, and the
# B-scheme sender re-checks via -ExpectChat. Only soft-succeed when
# wcdb\wx-mode.json says mode=a; otherwise keep the hard failure.
$modeFile = Join-Path $here 'wx-mode.json'
$modeA = $false
try {
  if (Test-Path -LiteralPath $modeFile) {
    $mm = Get-Content -LiteralPath $modeFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$mm.mode -eq 'a') { $modeA = $true }
  }
} catch { }
try {
  $win = Resolve-BotWindow
} catch {
  if ($modeA) {
    'find-chat: bot window is on the virtual desktop (mode a); the helper switches the chat while sending'
    exit 0
  }
  throw
}
$hwnd = [IntPtr]$win.Hwnd

# Always normalise the geometry before OCR. `wx_send.ps1 -ResolveOnly` (and other
# helpers) can leave the client parked at -32000,-32000 with a tiny rect; OCR then
# fails with "capture region is entirely outside the screen". Restore + move it and
# verify the result instead of trusting one call (2026-10-31: chat switching broke
# exactly this way).
$rect = Get-Rect $hwnd
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
for ($try = 0; $try -lt 3; $try++) {
  if ($w -eq 1500 -and $h -eq 830 -and $rect.Left -eq 0 -and $rect.Top -eq 0) { break }
  [void][WxFc]::ShowWindow($hwnd, 9)
  Start-Sleep -Milliseconds 200
  [void][WxFc]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 1500, 830, 0x0040)
  Start-Sleep -Milliseconds 350
  $rect = Get-Rect $hwnd
  $w = $rect.Right - $rect.Left
  $h = $rect.Bottom - $rect.Top
}
if ($w -lt 900 -or $h -lt 600 -or $rect.Left -lt -2000 -or $rect.Top -lt -2000) {
  throw ("wx_find_chat: the WeChat window is not on screen (rect={0},{1},{2}x{3}, hwnd={4}); bring the bot client back to the main desktop" -f $rect.Left, $rect.Top, $w, $h, $win.Hwnd)
}
if (-not $NoRaise) {
  for ($i = 0; $i -lt 4; $i++) {
    if ([WxFc]::Raise($hwnd)) { break }
    Start-Sleep -Milliseconds 300
  }
  Start-Sleep -Milliseconds 200
}

$left = $rect.Left
$top = $rect.Top
$listRegion = ('{0},{1},{2},{3}' -f [int]($left + 0.035 * $w), [int]($top + 0.10 * $h), [int](0.29 * $w), [int](0.72 * $h))
# The header strip must start to the RIGHT of the chat list, otherwise OCR also
# reads the list rows and we get "already on <other chat>" while sitting in the
# wrong conversation (that made the bot skip the switch). List column is ~0.29W.
$headerRegion = ('{0},{1},{2},{3}' -f [int]($left + 0.31 * $w), [int]($top + 0.02 * $h), [int](0.30 * $w), [int](0.075 * $h))

function Test-Header {
  param([string]$want)
  $sc = Run-Vision -ArgList @('-Action', 'text', '-Region', $headerRegion, '-Scale', ($Scale | Out-String).Trim())
  if (-not ($sc -and $sc.ok)) { return $false }
  $joined = (($sc.lines | ForEach-Object { $_.text }) -join '')
  $plain = Norm-Title $joined
  $needle = Norm-Title $want
  if ($needle -eq '') { return $false }
  # 用原始文本判断「、」：Norm-Title 会把标点去掉，拿去比就永远比不出来（踩过：把群当成私聊）
  if ($NotContains -ne '' -and ($joined.Contains($NotContains) -or $plain.Contains($NotContains))) { return $false }
  # Exact equality is too brittle: OCR renders the member-count suffix as a
  # stray glyph ("黑暗四天王(5)" -> "黑暗四天王囹"). Accept a line that covers
  # the whole name in order instead.
  if ($plain -eq $needle) { return $true }
  return ((Score-Line $joined $want) -ge 0.85)
}

$result = [pscustomobject]@{ ok = $false; via = ''; hwnd = $win.Hwnd; name = $Name; click = $null; matched = '' }

# 1) Trust only the cache, never the header, for "we are already there".
# OCR regularly truncates the group title ("猪葛凉、蒙(3)" -> "猪葛凉") and that made
# the finder claim it was already on the private chat while sitting in the group.
$cached = ''
try {
  if (Test-Path $cacheFile) {
    $age = ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalSeconds
    if ($age -lt 120) {
      $lines = [System.IO.File]::ReadAllLines($cacheFile)
      if ($lines.Count -ge 1) { $cached = $lines[0].Trim() }
      if ($lines.Count -ge 2) { $cachedHwnd = $lines[1].Trim() }
    }
  }
} catch { $cached = '' }

if ($cached -eq $Name -and $cachedHwnd -eq ([string]$hwnd)) {
  $result.ok = $true
  $result.via = 'cached'
  $result.matched = 'header'
} else {
  # 2) look at the list and click the best matching row
  $sc = Run-Vision -ArgList @('-Action', 'text', '-Region', $listRegion, '-Scale', ($Scale | Out-String).Trim())
  $best = $null
  $bestScore = 0.0
  if ($sc -and $sc.ok) {
    foreach ($ln in $sc.lines) {
      $txt = [string]$ln.text
      if ($txt.Contains(':') -or $txt.Contains('：')) { continue }
      if ($txt.TrimEnd().EndsWith([char]0x3001)) {
        # Group rows are split by OCR: the name line ends with the ideographic
        # comma ("猪葛凉、") and the second member is on another line. For a group
        # target that first line IS the row we want; for a private target skip it.
        if ($Name.Contains([char]0x3001)) {
          $firstSeg = $Name.Split([char]0x3001)[0]
          if ((Norm-Title $txt) -eq (Norm-Title $firstSeg)) { $best = $ln; $bestScore = 1.0; break }
        }
        continue
      }
      if ($NotContains -ne '' -and (Norm-Title $txt).Contains($NotContains)) { continue }
      $s = Score-Line $txt $Name
      if ($s -gt $bestScore) { $bestScore = $s; $best = $ln }
    }
  }
  if ($best -and $bestScore -ge $MinScore) {
    $cx = [int]($best.x + $best.w / 2)
    $cy = [int]($best.y + $best.h / 2)
    [void][WxFc]::SetCursorPos($cx, $cy)
    Start-Sleep -Milliseconds 150
    [WxFc]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [WxFc]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 900
    $result.click = @($cx, $cy)
    $result.matched = $best.text
    $bt = Norm-Title $best.text
    $bn = Norm-Title $Name
    $groupRow = ([string]$best.text).TrimEnd().EndsWith([char]0x3001) -and $bn.StartsWith($bt)
    # A click is NOT proof that the chat opened: the row can highlight while the
    # message pane stays on the welcome screen (seen 2026-10-31). Verify by the
    # header, and if it is not there yet, click once more before believing it.
    $opened = $false
    if (Test-Header $Name) { $opened = $true }
    if (-not $opened) {
      Start-Sleep -Milliseconds 400
      [void][WxFc]::SetCursorPos($cx, $cy)
      Start-Sleep -Milliseconds 250
      [WxFc]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 60
      [WxFc]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 900
      if (Test-Header $Name) { $opened = $true }
    }
    if ($opened -or $groupRow) { $result.ok = $true; $result.via = 'list-click' }
  } else {
    # The list may be scrolled away from the target: scroll it to the top, then try
    # exactly once more before giving up (2026-10-31: a scrolled list made the
    # finder miss 猪葛凉 entirely and fail the switch).
    $result.matched = ''
    [void][WxFc]::SetCursorPos([int]($left + 0.15 * $w), [int]($top + 0.35 * $h))
    Start-Sleep -Milliseconds 150
    for ($i = 0; $i -lt 6; $i++) {
      [WxFc]::mouse_event(0x0800, 0, 0, [uint32]120, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 60
    }
    Start-Sleep -Milliseconds 400
    $sc2 = Run-Vision -ArgList @('-Action', 'text', '-Region', $listRegion, '-Scale', ($Scale | Out-String).Trim())
    if ($sc2 -and $sc2.ok) {
      $best = $null
      $bestScore = 0.0
      foreach ($ln in $sc2.lines) {
        $txt = [string]$ln.text
        if ($txt.Contains(':') -or $txt.Contains('：')) { continue }
        if ($txt.TrimEnd().EndsWith([char]0x3001)) {
        # Group rows are split by OCR: the name line ends with the ideographic
        # comma ("猪葛凉、") and the second member is on another line. For a group
        # target that first line IS the row we want; for a private target skip it.
        if ($Name.Contains([char]0x3001)) {
          $firstSeg = $Name.Split([char]0x3001)[0]
          if ((Norm-Title $txt) -eq (Norm-Title $firstSeg)) { $best = $ln; $bestScore = 1.0; break }
        }
        continue
      }
      if ($NotContains -ne '' -and (Norm-Title $txt).Contains($NotContains)) { continue }
        $s = Score-Line $txt $Name
        if ($s -gt $bestScore) { $bestScore = $s; $best = $ln }
      }
      if ($best -and $bestScore -ge $MinScore) {
        $cx = [int]($best.x + $best.w / 2)
        $cy = [int]($best.y + $best.h / 2)
        [void][WxFc]::SetCursorPos($cx, $cy)
        Start-Sleep -Milliseconds 150
        [WxFc]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 60
        [WxFc]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 900
        $result.click = @($cx, $cy)
        $result.matched = $best.text
        if (Test-Header $Name) { $result.ok = $true; $result.via = 'list-click-after-scroll' }
      }
    }
  }
}

if (-not $result.ok) {
  # Last resort: keyboard search. Ctrl+F focuses WeChat's search box, we paste the
  # exact name with the private-clipboard helper, press Enter and Esc. This is
  # deterministic and does not depend on the list being scrolled to the right spot
  # (2026-10-31: a scrolled list left the target row above the visible area and the
  # bot stopped switching chats entirely).
  try {
    # 2026-10-31 rewrite of the last-resort search:
    #  * no child processes at all (each one compiled C# and stole the foreground)
    #  * never type unless this window is really the foreground window
    #  * Ctrl+A + Delete first, so a leftover query cannot turn into "猪葛凉猪葛凉"
    #  * one single attempt, no retry loop - a failed search must not chew on the
    #    client (that is what froze WeChat 4.2 tonight)
    Add-Type -AssemblyName System.Windows.Forms
    $fg = [WxFc]::GetForegroundWindow()
    if ($fg -ne $h) {
      [void][WxFc]::SetForegroundWindow($h)
      Start-Sleep -Milliseconds 250
      if ([WxFc]::GetForegroundWindow() -ne $h) {
        $result.matched = 'keyboard-skipped: window is not in the foreground'
        throw 'skip-search'
      }
    }
    [void][WxFc]::SetCursorPos([int]($left + 0.5 * $w), [int]($top + 0.5 * $h))
    Start-Sleep -Milliseconds 120
    # Ctrl+F
    [WxFc]::keybd_event(0x11, 0x1D, 0, [IntPtr]::Zero)
    [WxFc]::keybd_event(0x46, 0x21, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 50
    [WxFc]::keybd_event(0x46, 0x21, 2, [IntPtr]::Zero)
    [WxFc]::keybd_event(0x11, 0x1D, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 350
    # clear whatever the box already had
    [WxFc]::keybd_event(0x11, 0x1D, 0, [IntPtr]::Zero)
    [WxFc]::keybd_event(0x41, 0x1E, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 50
    [WxFc]::keybd_event(0x41, 0x1E, 2, [IntPtr]::Zero)
    [WxFc]::keybd_event(0x11, 0x1D, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [WxFc]::keybd_event(0x2E, 0x53, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 50
    [WxFc]::keybd_event(0x2E, 0x53, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.Clipboard]::SetText($Name)
    Start-Sleep -Milliseconds 120
    # Ctrl+V
    [WxFc]::keybd_event(0x11, 0x1D, 0, [IntPtr]::Zero)
    [WxFc]::keybd_event(0x56, 0x2F, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 70
    [WxFc]::keybd_event(0x56, 0x2F, 2, [IntPtr]::Zero)
    [WxFc]::keybd_event(0x11, 0x1D, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 600
    [WxFc]::keybd_event(0x0D, 0x1C, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [WxFc]::keybd_event(0x0D, 0x1C, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 900
    try { [System.Windows.Forms.Clipboard]::Clear() } catch { }
    # Only trust the keyboard path when the header really shows the target. Pressing
    # Enter on a search box that never received the text opens whichever row is
    # selected - that is how every reply ended up in the private chat.
    if (Test-Header $Name) {
      $result.ok = $true
      $result.via = 'search-enter'
      $result.matched = 'keyboard'
    } else {
      $result.matched = 'search-enter-unverified'
      [WxFc]::keybd_event(0x1B, 0x01, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 60
      [WxFc]::keybd_event(0x1B, 0x01, 2, [IntPtr]::Zero)
    }
  } catch {
    $result.matched = 'keyboard-failed: ' + $_.Exception.Message
  }
}

if ($result.ok) {
  try { [System.IO.File]::WriteAllText($cacheFile, ($Name + [Environment]::NewLine + ([string]$hwnd) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

if ($Json) {
  $result | ConvertTo-Json -Compress
} elseif ($result.ok -and $result.via -eq 'already-there') {
  "find-chat: already on '$Name'"
} elseif ($result.ok -and $result.via -eq 'search-enter') {
  "find-chat: opened '$Name' by Ctrl+F search + Enter"
} elseif ($result.ok) {
  "find-chat: opened '$Name' by click at $($result.click -join ',') (matched: $($result.matched))"
} else {
  $rows = if ($sc -and $sc.ok) { ($sc.lines | ForEach-Object { $_.text }) -join ' | ' } else { 'no ocr' }
  "find-chat: FAILED to open '$Name' (list seen: $rows)"
}

if ($result.ok) { exit 0 } else { exit 1 }
