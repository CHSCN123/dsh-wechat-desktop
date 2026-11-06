# Daily Moments poster for the bot account.
# ASCII-only comments: PowerShell 5.1 mis-parses mojibake in a BOM-less script.
#
# 1. Take the next caption from moments-queue.txt (one caption per line, UTF-8).
# 2. Pick a random picture from the generated-image folder (never a screenshot).
# 3. Drive the WeChat UI through wx_moments.ps1 and log the outcome.

param(
  [string]$QueueFile = (Join-Path $PSScriptRoot 'moments-queue.txt'),
  [string]$ImageDir = 'E:\DSH\SCDTP',
  [string]$LogFile = (Join-Path $PSScriptRoot 'moments.log'),
  [switch]$NoPublish
)

$ErrorActionPreference = 'Stop'
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

function WriteLog([string]$line) {
  $entry = $stamp + '  ' + $line
  Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8
  $entry
}

# --- caption ---------------------------------------------------------
$defaults = @(
  '今天的进度：饭吃了两顿，鱼摸了三条，Token 烧了一把。我宣布今天算赢，明天继续躺。',
  '有人问我为什么老在吃，因为我是鲸鱼啊，鲸鱼不吃怎么游得动。',
  '今天也很努力地活着（指躺着）。',
  '外卖到了就没烦恼，烦恼等吃完再说。',
  '别催，在摸鱼。摸完这条就去干活，真的。'
)
$caption = ''
if (Test-Path -LiteralPath $QueueFile) {
  $lines = @(Get-Content -LiteralPath $QueueFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' -and -not $_.StartsWith('#') })
  if ($lines.Count -gt 0) {
    $caption = $lines[0].Trim()
    $rest = @()
    if ($lines.Count -gt 1) { $rest = $lines[1..($lines.Count - 1)] }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($QueueFile, (($rest -join "`r`n") + "`r`n"), $utf8)
  }
}
if ($caption -eq '') {
  $idx = ((Get-Date).DayOfYear - 1) % $defaults.Count
  $caption = $defaults[$idx]
  WriteLog 'queue empty, using a default caption'
}

# --- picture ---------------------------------------------------------
$image = ''
if (Test-Path -LiteralPath $ImageDir) {
  $cand = @(Get-ChildItem -LiteralPath $ImageDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(png|jpg|jpeg)$' })
  if ($cand.Count -gt 0) {
    $image = ($cand | Get-Random).FullName
  }
}

$psArgs = @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass',
  '-File', (Join-Path $PSScriptRoot 'wx_moments.ps1'),
  '-Text', $caption
)
if ($image -ne '') { $psArgs += @('-Image', $image) }
if ($NoPublish) { $psArgs += '-NoPublish' }

try {
  $out = & powershell.exe @psArgs 2>&1
  $outText = ($out | Out-String).Trim()
  WriteLog ('caption=' + $caption)
  if ($image -ne '') { WriteLog ('image=' + $image) }
  WriteLog ('result: ' + $outText)
} catch {
  WriteLog ('ERROR: ' + $_.Exception.Message)
  exit 1
}
