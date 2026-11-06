$p = 'E:\DSH\dsh-wx-desktop\setup.ps1'
$text = [System.IO.File]::ReadAllText($p)

$oldHere = @'
if ($text.Contains($markerBegin) -and $text.Contains($markerEnd)) {
  $pattern = [regex]::Escape($markerBegin) + '[\s\S]*?' + [regex]::Escape($markerEnd)
  $text = [regex]::Replace($text, $pattern, $block.Replace('$', '$$'))
  Write-Ok '已更新已有的配置块'
} else {
  $text = $text.TrimEnd("`r", "`n") + "`r`n`r`n" + $block + "`r`n"
  Write-Ok '已追加配置块'
}
'@

$newHere = @'
$linesAll = $text -split "`r?`n"
$beginAt = -1; $endAt = -1
for ($i = 0; $i -lt $linesAll.Count; $i++) {
  if ($linesAll[$i].Trim() -eq $markerBegin) { $beginAt = $i }
  elseif ($linesAll[$i].Trim() -eq $markerEnd -and $beginAt -ge 0) { $endAt = $i; break }
}
if ($beginAt -ge 0 -and $endAt -ge 0) {
  $before = if ($beginAt -gt 0) { $linesAll[0..($beginAt - 1)] } else { @() }
  $after = if ($endAt + 1 -lt $linesAll.Count) { $linesAll[($endAt + 1)..($linesAll.Count - 1)] } else { @() }
  $text = (($before + ($block -split "`r?`n") + $after) -join "`r`n")
  Write-Ok '已更新已有的配置块（带标记）'
} else {
  # 老版本装法：没有标记，靠 `- id: dsh-wx-desktop` 定位整块（到下一个顶格 `- ` 为止）
  $startAt = -1
  for ($i = 0; $i -lt $linesAll.Count; $i++) {
    if ($linesAll[$i] -match '^-\s+id:\s*dsh-wx-desktop\s*$') { $startAt = $i; break }
  }
  if ($startAt -ge 0) {
    $stopAt = $linesAll.Count - 1
    for ($i = $startAt + 1; $i -lt $linesAll.Count; $i++) {
      if ($linesAll[$i] -match '^-(\s|$)') { $stopAt = $i - 1; break }
    }
    $before = if ($startAt -gt 0) { $linesAll[0..($startAt - 1)] } else { @() }
    $after = if ($stopAt + 1 -lt $linesAll.Count) { $linesAll[($stopAt + 1)..($linesAll.Count - 1)] } else { @() }
    $text = (($before + ($block -split "`r?`n") + $after) -join "`r`n")
    Write-Ok '已替换已有的旧配置块（无标记）'
  } else {
    $text = $text.TrimEnd("`r", "`n") + "`r`n`r`n" + $block + "`r`n"
    Write-Ok '已追加配置块'
  }
}
'@

if (-not $text.Contains($oldHere)) { 'ANCHOR MISS'; exit 1 }
$text = $text.Replace($oldHere, $newHere)
[System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($true)))
$err = $null
[System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$err) | Out-Null
if ($err -and $err.Count) { $err | ForEach-Object { $_.Message } } else { 'PARSE OK' }
