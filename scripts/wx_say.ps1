<#
wx_say.ps1 - "look, confirm, then talk" sender.

New flow (replaces the old click-the-list-every-time approach, which made the
window flash and sometimes typed into the wrong chat):

  1. put the window on the script grid ONCE (0,0 1500x830) - skipped when it is
     already there, so a normal send does not move any window at all
  2. screenshot + OCR the chat title and print it ("current chat: <...>")
  3. compare with -Chat; if it is a different conversation, switch once with
     wx_find_chat.ps1 (the only step that touches the list)
  4. paste the text (Ctrl+V) and press Enter 500 ms later

  wx_say.ps1 -Chat "猪葛凉" -Text "hello"
  wx_say.ps1 -Chat "黑暗四天王" -TextFile msg.txt -ShotDir "E:\DSH\GZJT GC"
#>
param(
  [Parameter(Mandatory = $true)][string]$Chat,
  [string]$Text = '',
  [string]$TextFile = '',
  [string]$NotContains = '',
  [string]$ShotDir = 'E:\DSH\GZJT GC',
  [int]$PasteDelayMs = 600,
    [int]$SubmitDelayMs = 500,
    [int]$SendX = 1430,
    [int]$SendY = 773,
  [switch]$NoSubmit
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$here = $PSScriptRoot
$vision = Join-Path $here 'wx_vision.ps1'
$finder = Join-Path $here 'wx_find_chat.ps1'
if ($TextFile -ne '') { $Text = [System.IO.File]::ReadAllText($TextFile, [System.Text.Encoding]::UTF8) }
if ($Text.Trim() -eq '') { throw 'wx_say: empty text' }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxSay {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint fl, IntPtr ex);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
[void][WxSay]::SetProcessDpiAwarenessContext([IntPtr](-4))

# ---------------------------------------------------------------- the window
$proc = Get-Process Weixin -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -eq '微信' } |
        Select-Object -First 1
if (-not $proc) { throw 'wx_say: no WeChat main window; is the bot client logged in?' }
$h = [IntPtr]$proc.MainWindowHandle
# 2026-11-01: park the window on the script grid and PROVE it took. A window
# hidden in the tray reports (-32000,-32000), and ShowWindow does not always
# bring it back; the old code printed "parked" and then typed into nothing.
function Get-SayRect {
  $r = New-Object WxSay+RECT
  [void][WxSay]::GetWindowRect($h, [ref]$r)
  return $r
}
function Test-SayGrid($r) {
  $gw = $r.Right - $r.Left
  $gh = $r.Bottom - $r.Top
  return ($r.Left -eq 0 -and $r.Top -eq 0 -and $gw -ge 1200 -and $gh -ge 700)
}
$rect = Get-SayRect
$wasLeft = $rect.Left; $wasTop = $rect.Top
$wasW = $rect.Right - $rect.Left; $wasH = $rect.Bottom - $rect.Top
if (-not (Test-SayGrid $rect)) {
  for ($parkTry = 1; $parkTry -le 3; $parkTry++) {
    [void][WxSay]::ShowWindow($h, 9)
    Start-Sleep -Milliseconds 150
    [void][WxSay]::ShowWindow($h, 5)
    [void][WxSay]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1500, 830, 0x0040)
    [void][WxSay]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 450
    $rect = Get-SayRect
    if (Test-SayGrid $rect) { break }
    Write-Output ("wx_say: park try {0} left the window at {1},{2} {3}x{4}" -f $parkTry, $rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
  }
  Write-Output ("wx_say: window parked to {0},{1} {2}x{3} (was {4},{5} {6}x{7})" -f $rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top), $wasLeft, $wasTop, $wasW, $wasH)
  if (-not (Test-SayGrid $rect)) {
    throw ("wx_say: cannot park the window on the script grid (still {0},{1} {2}x{3}); refusing to type into a window I cannot see" -f $rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
  }
}

# ------------------------------------------------------- who are we talking to
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$shot = Join-Path $ShotDir ('say-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.png')
$bmp = New-Object System.Drawing.Bitmap 1500, 830
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
[string]$header = ''
try {
  $gfx.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
  $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
  $json = Join-Path $here 'say-title.json'
  function NormT([string]$x) { ($x -replace '[\s、，,]', '') -replace '[（(]\d+[)）]', '' }
  $regions = @('380,52,300,50', '380,45,420,70', '360,40,360,60')
  $best = ''
  foreach ($pass in 1..2) {
    foreach ($rg in $regions) {
      try {
        & $vision -Action text -Region $rg -OutJson $json | Out-Null
        if (Test-Path $json) {
          $data = [System.IO.File]::ReadAllText($json, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
          $cand = (($data.lines | ForEach-Object { $_.text }) -join ' ').Trim()
          if ($cand.Length -gt $best.Length) { $best = $cand }
          if ($cand -and ((NormT $cand) -eq (NormT $Chat))) { $best = $cand; break }
        }
      } catch { }
    }
    if ($best -and ((NormT $best) -eq (NormT $Chat))) { break }
    if ($pass -eq 1) { Start-Sleep -Milliseconds 500 }
  }
  $header = $best
} catch {
  Write-Output ("wx_say: could not read the title ({0})" -f $_.Exception.Message)
} finally {
  $gfx.Dispose(); $bmp.Dispose()
}
Write-Output ("wx_say: screenshot {0}" -f $shot)
Write-Output ("wx_say: current chat = '{0}'  target = '{1}'" -f $header, $Chat)

$same = (NormT $header) -eq (NormT $Chat)
if ($same -and $NotContains -ne '' -and $header.Contains($NotContains)) { $same = $false }
if (-not $same) {
  Write-Output ("wx_say: switching from '{0}' to '{1}'" -f $header, $Chat)
  & $finder -Name $Chat | ForEach-Object { Write-Output ("wx_say: " + $_) }
  if ($LASTEXITCODE -ne 0) { throw "wx_say: could not switch to '$Chat'" }
  Start-Sleep -Milliseconds 600
  [void][WxSay]::GetWindowRect($h, [ref]$rect)
}

# ------------------------------------------------------------------- the send
if (-not [WxSay]::GetForegroundWindow().Equals($h)) {
  [WxSay]::keybd_event(0x12, 0x38, 0, [IntPtr]::Zero)
  [WxSay]::keybd_event(0x12, 0x38, 2, [IntPtr]::Zero)
  [void][WxSay]::BringWindowToTop($h)
  [void][WxSay]::SetForegroundWindow($h)
  Start-Sleep -Milliseconds 400
}
# input box centre: WeChat is DPI-unaware, so the painted window is 1334x739 on
# a 125% display even though GetWindowRect reports 1500x830.
$inputX = 640
$inputY = 640
[void][WxSay]::SetCursorPos($inputX, $inputY)
Start-Sleep -Milliseconds 250
[WxSay]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 60
[WxSay]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds $PasteDelayMs

# 只有输入框里真的已经有字才清（Ctrl+A 在微信里遇到长会话会卡一下，空框就没必要按）
function Test-InputHasText {
  try {
    $b = New-Object System.Drawing.Bitmap 1040, 70
    $g2 = [System.Drawing.Graphics]::FromImage($b)
    $g2.CopyFromScreen(370, 620, 0, 0, $b.Size)
    $g2.Dispose()
    $dark = 0
    for ($y = 0; $y -lt 70; $y += 3) {
      for ($x = 0; $x -lt 1040; $x += 3) {
        $c = $b.GetPixel($x, $y)
        if ($c.R -lt 170 -and $c.G -lt 170 -and $c.B -lt 170) { $dark++ }
      }
    }
    $b.Dispose()
    return ($dark -gt 12)
  } catch { return $true }
}
if (Test-InputHasText) {
  [WxSay]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)
  [WxSay]::keybd_event(0x41, 0x1E, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [WxSay]::keybd_event(0x41, 0x1E, 2, [IntPtr]::Zero)
  [WxSay]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  [WxSay]::keybd_event(0x2E, 0x53, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [WxSay]::keybd_event(0x2E, 0x53, 2, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 200
} else {
  Write-Output 'wx_say: input box already empty, skipping Ctrl+A'
}

# 2026-11-01: snapshot the chat area before typing, so a send that silently
# does nothing (window covered / keystrokes lost) can be detected afterwards.
$preBox = New-Object System.Drawing.Bitmap 1120, 480
$preG = [System.Drawing.Graphics]::FromImage($preBox)
$preG.CopyFromScreen(370, 100, 0, 0, $preBox.Size)
$preG.Dispose()
$clipOk = $false
for ($ct = 1; $ct -le 4; $ct++) {
  try { Set-Clipboard -Value $Text; $clipOk = $true; break } catch { Start-Sleep -Milliseconds 250 }
}
if (-not $clipOk) { throw 'wx_say: could not put the text on the clipboard (another program is holding it)' }
Start-Sleep -Milliseconds 250
[WxSay]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 150
[WxSay]::keybd_event(0x56, 0x2F, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 150
[WxSay]::keybd_event(0x56, 0x2F, 2, [IntPtr]::Zero)
Start-Sleep -Milliseconds 100
[WxSay]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)
Start-Sleep -Milliseconds $SubmitDelayMs

if (-not $NoSubmit) {
  # 提交顺序（2026-10-31 用户定）：优先回车；回车没发出去再点「发送」按钮；还不行再点一次。
  $submitted = $false
  [WxSay]::keybd_event(0x0D, 0x1C, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [WxSay]::keybd_event(0x0D, 0x1C, 2, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 600
  if (-not (Test-InputHasText)) {
    $submitted = $true
    Write-Output 'wx_say: submitted by Enter'
  } else {
    Write-Output 'wx_say: Enter did not submit; trying the send button'
  }
  for ($try = 1; $try -le 2 -and (-not $submitted); $try++) {
    [void][WxSay]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 200
    [void][WxSay]::SetCursorPos($SendX, $SendY)
    Start-Sleep -Milliseconds 180
    [WxSay]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [WxSay]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    if (-not (Test-InputHasText)) {
      $submitted = $true
      Write-Output ("wx_say: submitted by clicking the send button (try {0} at {1},{2})" -f $try, $SendX, $SendY)
    } else {
      Write-Output ("wx_say: send button try {0} at {1},{2} did not clear the input box" -f $try, $SendX, $SendY)
    }
  }
  if (-not $submitted) {
    Write-Output ("wx_say: WARN could not submit; input box still has text. Send-button coords are {0},{1} - run wx_wherem.ps1 with the mouse on the button to calibrate." -f $SendX, $SendY)
  }
  Start-Sleep -Milliseconds 400
}
Start-Sleep -Milliseconds 900
if (-not $NoSubmit) {
  $postBox = New-Object System.Drawing.Bitmap 1120, 480
  $postG = [System.Drawing.Graphics]::FromImage($postBox)
  $postG.CopyFromScreen(370, 100, 0, 0, $postBox.Size)
  $postG.Dispose()
  $changed = 0
  for ($yy = 0; $yy -lt 480; $yy += 4) {
    for ($xx = 0; $xx -lt 1120; $xx += 4) {
      $ca = $preBox.GetPixel($xx, $yy); $cb = $postBox.GetPixel($xx, $yy)
      if (([math]::Abs($ca.R - $cb.R) + [math]::Abs($ca.G - $cb.G) + [math]::Abs($ca.B - $cb.B)) -gt 30) { $changed++ }
    }
  }
  $preBox.Dispose(); $postBox.Dispose()
  Write-Output ("wx_say: chat-area changed pixels={0}" -f $changed)
  if ($changed -lt 40) {
    throw 'wx_say: the chat area did not change after submitting; the reply probably never left the input box'
  }
}
try { [System.Windows.Forms.Clipboard]::Clear() } catch { }
Write-Output ("wx_say: sent {0} chars to '{1}'" -f $Text.Length, $Chat)





