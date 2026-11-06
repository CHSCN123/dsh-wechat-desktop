# wx_ocr.ps1 - OCR the screen (or a crop) with the Windows built-in engine.
# Why: pure coordinate clicking kept missing (search box, verify button).
# With OCR we can *look* first: find the anchor text, click its center, then
# verify the thing we expected is actually there.
#
# Output: one JSON object on stdout, UTF-8:
#   { "ok": true, "text": "...", "lines": [ { "text": "...", "x":1,"y":2,"w":3,"h":4 } ] }
# Coordinates are absolute physical screen pixels (DPI aware).
#
# ASCII-only comments: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
param(
  [string]$ImagePath = "",
  [int]$X = -1, [int]$Y = -1, [int]$W = -1, [int]$H = -1,
  [string]$OutJson = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class WxDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
}
"@
[void][WxDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))

# 1) capture
if ($ImagePath -ne "") {
  $bmp = [System.Drawing.Bitmap]::FromFile($ImagePath)
  $originX = 0; $originY = 0
} else {
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  if ($X -lt 0) { $X = $vs.X; $Y = $vs.Y; $W = $vs.Width; $H = $vs.Height }
  $bmpFull = New-Object System.Drawing.Bitmap ([int]$vs.Width), ([int]$vs.Height)
  $gFull = [System.Drawing.Graphics]::FromImage($bmpFull)
  $gFull.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmpFull.Size)
  $gFull.Dispose()
  $rect = New-Object System.Drawing.Rectangle $X, $Y, $W, $H
  $bmp = $bmpFull.Clone($rect, $bmpFull.PixelFormat)
  $bmpFull.Dispose()
  $originX = $X; $originY = $Y
}

# 2) OCR through WinRT
$tmp = Join-Path $env:TEMP ("wxocr-" + [guid]::NewGuid().ToString("N") + ".png")
$bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
$bmpW = $bmp.Width; $bmpH = $bmp.Height
$bmp.Dispose()

$lines = New-Object System.Collections.ArrayList
$text = ""

try {
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

  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $softwareBitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

  $engine = $null
  foreach ($tag in @("zh-Hans-CN", "zh-Hans", "zh-CN", "en-US")) {
    try {
      $lang = New-Object Windows.Globalization.Language $tag
      $candidate = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
      if ($candidate -ne $null) { $engine = $candidate; break }
    } catch { }
  }
  if ($engine -eq $null) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
  if ($engine -eq $null) { throw "no OCR engine available (no language pack?)" }

  $result = Await ($engine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
  $sb = New-Object System.Text.StringBuilder
  foreach ($line in $result.Lines) {
    $minX = [double]::MaxValue; $minY = [double]::MaxValue
    $maxX = 0.0; $maxY = 0.0
    foreach ($word in $line.Words) {
      $r = $word.BoundingRect
      if ($r.X -lt $minX) { $minX = $r.X }
      if ($r.Y -lt $minY) { $minY = $r.Y }
      if (($r.X + $r.Width) -gt $maxX) { $maxX = $r.X + $r.Width }
      if (($r.Y + $r.Height) -gt $maxY) { $maxY = $r.Y + $r.Height }
    }
    if ($minX -eq [double]::MaxValue) { continue }
    [void]$lines.Add([pscustomobject]@{
      text = $line.Text
      x = [int]($originX + $minX); y = [int]($originY + $minY)
      w = [int]($maxX - $minX);   h = [int]($maxY - $minY)
    })
    [void]$sb.AppendLine($line.Text)
  }
  $text = $sb.ToString().Trim()
} catch {
  $err = $_.Exception.Message
  Remove-Item $tmp -ErrorAction SilentlyContinue
  $payload = [pscustomobject]@{ ok = $false; error = $err; text = ""; lines = @() }
  $json = $payload | ConvertTo-Json -Depth 5 -Compress
  if ($OutJson -ne "") { [System.IO.File]::WriteAllText($OutJson, $json, (New-Object System.Text.UTF8Encoding($false))) }
  Write-Output $json
  exit 1
}

Remove-Item $tmp -ErrorAction SilentlyContinue

$out = [pscustomobject]@{
  ok    = $true
  width = $bmpW
  height = $bmpH
  text  = $text
  lines = @($lines)
}
$json = $out | ConvertTo-Json -Depth 6
if ($OutJson -ne "") { [System.IO.File]::WriteAllText($OutJson, $json, (New-Object System.Text.UTF8Encoding($false))) }
Write-Output $json
