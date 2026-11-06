# wx_vision.ps1 - "look before you click" helpers built on Windows OCR.
# Pure coordinates kept missing; this finds the anchor text on screen first.
#
# Actions:
#   -Action text  -Region "x,y,w,h"                     -> OCR a region, print JSON
#   -Action find  -Text "搜索" -Region "x,y,w,h"        -> locate a line containing Text
#   -Action click -Text "搜索" -Region "x,y,w,h" [-OffsetX n] [-OffsetY n]
#                                                      -> locate + click its center
#
# Output: one compressed JSON object on stdout (UTF-8), also written to -OutJson.
# Coordinates are absolute physical pixels (the caller is expected to have made
# its process DPI aware already; this script does it too).
#
# ASCII-only comments: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
param(
  [Parameter(Mandatory=$true)][ValidateSet("text", "find", "click")][string]$Action,
  [string]$Text = "",
  [string]$Region = "",
  [int]$OffsetX = 0,
  [int]$OffsetY = 0,
  [int]$Index = 0,
  [string]$OutJson = "",
  [int]$TimeoutMs = 0,
  [int]$Scale = 2,
  # Fuzzy matching: 1.0 = exact substring only. Below 1.0 the OCR text is
  # matched by LCS coverage of the needle (tolerates dropped glyphs).
  [double]$MinScore = 1.0
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class WxVDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
}
"@
[void][WxVDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))

function Emit($obj) {
  $json = $obj | ConvertTo-Json -Depth 6 -Compress
  if ($OutJson -ne "") {
    $pretty = $obj | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($OutJson, $pretty, (New-Object System.Text.UTF8Encoding($false)))
  }
  Write-Output $json
}

# Normalize: OCR inserts spaces between CJK glyphs, so compare without whitespace.
function Norm([string]$s) { if ($s -eq $null) { return "" } return ($s -replace '\s+', '').ToLowerInvariant() }

# Longest common subsequence length (classic O(n*m) DP, tiny inputs).
function Lcs-Len([string]$a, [string]$b) {
  if ($a.Length -eq 0 -or $b.Length -eq 0) { return 0 }
  $prev = New-Object int[] ($b.Length + 1)
  $cur = New-Object int[] ($b.Length + 1)
  for ($i = 1; $i -le $a.Length; $i++) {
    $cur[0] = 0
    for ($j = 1; $j -le $b.Length; $j++) {
      if ($a[$i - 1] -eq $b[$j - 1]) { $cur[$j] = $prev[$j - 1] + 1 }
      elseif ($prev[$j] -ge $cur[$j - 1]) { $cur[$j] = $prev[$j] }
      else { $cur[$j] = $cur[$j - 1] }
    }
    $tmp = $prev; $prev = $cur; $cur = $tmp
  }
  return $prev[$b.Length]
}

# Coverage of needle chars found (in order) inside haystack, 0..1.
function Match-Score([string]$hay, [string]$needle) {
  if ($needle -eq "") { return 0.0 }
  if ($hay.Contains($needle)) { return 1.0 }
  if ($needle.Length -lt 2) { return 0.0 }
  return ([double](Lcs-Len $hay $needle)) / $needle.Length
}

function CaptureRegion([string]$spec) {
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $x = $vs.X; $y = $vs.Y; $w = $vs.Width; $h = $vs.Height
  if ($spec -ne "") {
    $p = $spec.Split(",")
    $x = [int]$p[0]; $y = [int]$p[1]; $w = [int]$p[2]; $h = [int]$p[3]
  }
  $full = New-Object System.Drawing.Bitmap ([int]$vs.Width), ([int]$vs.Height)
  $g = [System.Drawing.Graphics]::FromImage($full)
  $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $full.Size)
  $g.Dispose()
  # $full is a snapshot of the whole virtual screen, so its own coordinate
  # space starts at (0,0). A caller passing a window rect can hand us numbers
  # outside that space (window minimised / hidden in the tray still reports
  # 1200x664@0,0 while the real window is 1500x830; a region computed from the
  # header can also poke past the right/bottom edge). Bitmap.Clone then throws
  # a bare ArgumentException ("parameter is not valid"), which used to abort
  # find_chat and silently drop the whole reply. Clip instead.
  $rect = New-Object System.Drawing.Rectangle ($x - $vs.X), ($y - $vs.Y), $w, $h
  $screenRect = New-Object System.Drawing.Rectangle 0, 0, $full.Width, $full.Height
  $rect.Intersect($screenRect)
  if ($rect.Width -lt 2 -or $rect.Height -lt 2) {
    $full.Dispose()
    throw "capture region '$spec' is entirely outside the screen ($($vs.Width)x$($vs.Height))"
  }
  $w = $rect.Width
  $h = $rect.Height
  $crop = $full.Clone($rect, $full.PixelFormat)
  $full.Dispose()
  # Upscale: the OCR engine reads small UI text much better at 2x.
  $sf = $Scale
  if ($sf -lt 1) { $sf = 1 }
  if ($sf -gt 1) {
    $big = New-Object System.Drawing.Bitmap ([int]($w * $sf)), ([int]($h * $sf))
    $gb = [System.Drawing.Graphics]::FromImage($big)
    $gb.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gb.DrawImage($crop, 0, 0, $big.Width, $big.Height)
    $gb.Dispose()
    $crop.Dispose()
    $crop = $big
  }
  return @{ bmp = $crop; x = $x; y = $y; w = $w; h = $h; s = $sf }
}

# --- OCR core (WinRT) -------------------------------------------------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq "IAsyncOperation``1"
})[0]
function Await($op, $resultType) {
  $task = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  return $task.Result
}
[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime] | Out-Null
[Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime] | Out-Null

$engine = $null
foreach ($tag in @("zh-Hans-CN", "zh-Hans", "zh-CN", "en-US")) {
  try {
    $lang = New-Object Windows.Globalization.Language $tag
    $candidate = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
    if ($candidate -ne $null) { $engine = $candidate; break }
  } catch { }
}
if ($engine -eq $null) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
if ($engine -eq $null) { Emit @{ ok = $false; error = "no OCR engine" }; exit 1 }

function OcrBitmap($bmp) {
  $tmp = Join-Path $env:TEMP ("wxv-" + [guid]::NewGuid().ToString("N") + ".png")
  $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $sb = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $result = Await ($engine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
  Remove-Item $tmp -ErrorAction SilentlyContinue
  return $result
}

$deadline = (Get-Date).AddMilliseconds($TimeoutMs)
while ($true) {
  $cap = CaptureRegion $Region
  $result = OcrBitmap $cap.bmp
  $rows = New-Object System.Collections.ArrayList
  foreach ($line in $result.Lines) {
    $minX = [double]::MaxValue; $minY = [double]::MaxValue; $maxX = 0.0; $maxY = 0.0
    foreach ($word in $line.Words) {
      $r = $word.BoundingRect
      if ($r.X -lt $minX) { $minX = $r.X }
      if ($r.Y -lt $minY) { $minY = $r.Y }
      if (($r.X + $r.Width) -gt $maxX) { $maxX = $r.X + $r.Width }
      if (($r.Y + $r.Height) -gt $maxY) { $maxY = $r.Y + $r.Height }
    }
    if ($minX -eq [double]::MaxValue) { continue }
    $s = $cap.s
    [void]$rows.Add([pscustomobject]@{
      text = $line.Text
      x = [int]($cap.x + ($minX / $s)); y = [int]($cap.y + ($minY / $s))
      w = [int](($maxX - $minX) / $s);  h = [int](($maxY - $minY) / $s)
    })
  }

  if ($Action -eq "text") {
    Emit @{ ok = $true; count = $rows.Count; lines = @($rows) }
    break
  }

  $needle = Norm $Text
  $hits = @()
  if ($needle -ne "") {
    foreach ($row in $rows) {
      $score = Match-Score (Norm $row.text) $needle
      if ($score -ge $MinScore -and $score -gt 0) {
        $hits += [pscustomobject]@{ text = $row.text; x = $row.x; y = $row.y; w = $row.w; h = $row.h; score = [Math]::Round($score, 3) }
      }
    }
    if ($hits.Count -gt 1) { $hits = @($hits | Sort-Object -Property @{ Expression = "score"; Descending = $true }, @{ Expression = "y"; Descending = $false }) }
  }

  if ($hits.Count -gt $Index) {
    $hit = $hits[$Index]
    $cx = [int]($hit.x + $hit.w / 2) + $OffsetX
    $cy = [int]($hit.y + $hit.h / 2) + $OffsetY
    if ($Action -eq "click") {
      [void][WxVDpi]::SetCursorPos($cx, $cy)
      Start-Sleep -Milliseconds 220
      [WxVDpi]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 70
      [WxVDpi]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 350
    }
    Emit @{ ok = $true; matched = $hit.text; score = $hit.score; click = @($cx, $cy); box = @($hit.x, $hit.y, $hit.w, $hit.h) }
    break
  }

  if ((Get-Date) -ge $deadline) {
    Emit @{ ok = $false; error = "not found"; needle = $Text; seen = @($rows | ForEach-Object { $_.text }) }
    exit 4
  }
  Start-Sleep -Milliseconds 300
}
