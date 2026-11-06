<#
.SYNOPSIS
  微信桌面桥 / dsh-wx-desktop 首次安装向导。

.DESCRIPTION
  做四件事：检查 Python / Node、把 scripts\ 复制到数据目录、把配置块写进 profile 的
  cordis.patch.yml（带标记；重复执行只更新，不会重复定义）、最后打印下一步。

.EXAMPLE
  .\setup.ps1 -DbDir 'D:\WeChat\xwechat_files\wxid_xxx\db_storage' -ChatUser 'wxid_xxx' -PeerName '张三'
#>
[CmdletBinding()]
param(
  [string]$DataDir = (Join-Path $env:USERPROFILE '.dsh\weixin'),
  [Parameter(Mandatory = $true)][string]$DbDir,
  [Parameter(Mandatory = $true)][string]$ChatUser,
  [string]$PeerName = '',
  [int]$PanelPort = 47180,
  [string]$ProfilePatch = (Join-Path $env:APPDATA 'dsh-desktop\harness\profiles\web\cordis.patch.yml'),
  [string]$PythonPath = '',
  [string]$NodePath = '',
  [switch]$SkipCopy
)

$ErrorActionPreference = 'Stop'
$markerBegin = '# >>> dsh-wx-desktop (managed by setup.ps1)'
$markerEnd = '# <<< dsh-wx-desktop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Note($msg) { Write-Host "    !!  $msg" -ForegroundColor Yellow }

# ---- 1. 环境检查 -----------------------------------------------------------
Write-Step '检查 Python 3.14+（需要 compression.zstd）'
$python = $PythonPath
if ($python -eq '') {
  foreach ($candidate in @('python', 'python3')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { $python = $cmd.Source; break }
  }
}
if ($python -eq '') {
  Write-Note '找不到 python，请安装 Python 3.14+ 后重跑（或用 -PythonPath 指定）'
} else {
  & $python -c 'import compression.zstd' 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Ok $python } else { Write-Note "$python 缺少 compression.zstd（版本低于 3.14）" }
}

Write-Step '检查 Node 24+（需要 node:sqlite）'
$node = $NodePath
if ($node -eq '') {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { $node = $cmd.Source }
}
if ($node -eq '') {
  Write-Note '找不到 node，表情包解析会用不了'
} else {
  $verText = (& $node --version 2>$null) -replace '^v', ''
  $major = 0
  if ($verText -match '^(\d+)\.') { $major = [int]$Matches[1] }
  if ($major -ge 24) { Write-Ok "$node (v$verText)" } else { Write-Note "$node 是 v$verText，需要 24+" }
}

# ---- 2. 复制脚本 -----------------------------------------------------------
$scriptRoot = Join-Path $PSScriptRoot 'scripts'
$wcdb = Join-Path $DataDir 'wcdb'
if ($SkipCopy) {
  Write-Step '跳过脚本复制（-SkipCopy）'
} elseif (-not (Test-Path $scriptRoot)) {
  Write-Note '仓库里没有 scripts\ 目录，跳过复制（从发布包安装时才会有）'
} else {
  Write-Step "复制脚本到 $wcdb"
  New-Item -ItemType Directory -Force -Path $wcdb | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $DataDir 'sessions') | Out-Null
  Get-ChildItem $scriptRoot -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $wcdb $_.Name) -Force }
  Write-Ok ("复制 " + (Get-ChildItem $wcdb -File).Count + " 个文件")
}

# ---- 3. 写配置 -------------------------------------------------------------
Write-Step "写配置到 $ProfilePatch"
if (-not (Test-Path $ProfilePatch)) {
  throw "找不到 profile 配置：$ProfilePatch（先启动一次 DSH，或用 -ProfilePatch 指定）"
}

function Quote([string]$value) { "'" + ($value -replace "'", "''") + "'" }

$blockLines = @(
  $markerBegin,
  '- id: dsh-wx-desktop',
  '  disabled: false',
  '  config:',
  ("    dataDir: " + (Quote $DataDir)),
  ("    dbDir: " + (Quote $DbDir)),
  ("    chatUser: " + (Quote $ChatUser))
)
if ($PeerName -ne '') { $blockLines += ("    peerName: " + (Quote $PeerName)) }
if ($PythonPath -ne '') { $blockLines += ("    pythonPath: " + (Quote $PythonPath)) }
if ($NodePath -ne '') { $blockLines += ("    nodePath: " + (Quote $NodePath)) }
if ($PanelPort -gt 0) { $blockLines += ("    panelPort: " + $PanelPort) }
$blockLines += $markerEnd

$utf8 = New-Object System.Text.UTF8Encoding($false)
$text = [System.IO.File]::ReadAllText($ProfilePatch, $utf8)
$all = $text -split "`r?`n"

$beginAt = -1
$endAt = -1
for ($i = 0; $i -lt $all.Count; $i++) {
  if ($all[$i].Trim() -eq $markerBegin) { $beginAt = $i }
  elseif ($all[$i].Trim() -eq $markerEnd -and $beginAt -ge 0) { $endAt = $i; break }
}

if ($beginAt -ge 0 -and $endAt -ge 0) {
  $before = if ($beginAt -gt 0) { $all[0..($beginAt - 1)] } else { @() }
  $after = if ($endAt + 1 -lt $all.Count) { $all[($endAt + 1)..($all.Count - 1)] } else { @() }
  $text = (($before + $blockLines + $after) -join "`r`n")
  Write-Ok '已更新已有的配置块（带标记）'
} else {
  $startAt = -1
  for ($i = 0; $i -lt $all.Count; $i++) {
    if ($all[$i] -match '^-\s+id:\s*dsh-wx-desktop\s*$') { $startAt = $i; break }
  }
  if ($startAt -ge 0) {
    $stopAt = $all.Count - 1
    for ($i = $startAt + 1; $i -lt $all.Count; $i++) {
      if ($all[$i] -match '^-(\s|$)') { $stopAt = $i - 1; break }
    }
    $before = if ($startAt -gt 0) { $all[0..($startAt - 1)] } else { @() }
    $after = if ($stopAt + 1 -lt $all.Count) { $all[($stopAt + 1)..($all.Count - 1)] } else { @() }
    $text = (($before + $blockLines + $after) -join "`r`n")
    Write-Ok '已替换已有的旧配置块（无标记）'
  } else {
    $text = $text.TrimEnd("`r", "`n") + "`r`n`r`n" + ($blockLines -join "`r`n") + "`r`n"
    Write-Ok '已追加配置块'
  }
}
[System.IO.File]::WriteAllText($ProfilePatch, $text, $utf8)

$yaml = Join-Path (Split-Path $ProfilePatch) 'node_modules\js-yaml'
if ($node -and (Test-Path $yaml)) {
  $script = 'const fs=require("fs");const y=require(process.argv[1]);try{y.load(fs.readFileSync(process.argv[2],"utf8"));console.log("ok")}catch(e){console.log("bad: "+e.message)}'
  $check = & $node -e $script $yaml $ProfilePatch
  if ($check -eq 'ok') { Write-Ok 'YAML 解析通过' } else { Write-Note "YAML 有问题：$check" }
}

# ---- 4. 下一步 -------------------------------------------------------------
Write-Step '下一步'
Write-Host ''
Write-Host '    1. 重启 DSH（配置要重启才加载）'
Write-Host '    2. 在微信里给这个号发一句 /doctor，应回一份自检'
Write-Host "    3. 浏览器打开 http://127.0.0.1:$PanelPort 看面板"
Write-Host ("    4. 回复发不出去时先看 " + (Join-Path $wcdb 'plugin.log'))
Write-Host ''

exit 0
