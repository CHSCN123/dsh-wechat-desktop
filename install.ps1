# 微信桌面桥 / WeChat Desk Bridge —— 一键安装
#
# 用法（在解压/克隆出来的目录里）：
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -DbDir "D:\WeChat\xwechat_files\wxid_xxx\db_storage" -ChatUser wxid_xxx -PeerName "张三"
#
# 它做两件事：
#   1) 把插件装进 DSH 的 profile（走 dsh plugin add，等价于 pnpm add）
#   2) 调用 setup.ps1 写配置块（可以 -SkipConfig 跳过，之后自己跑 setup.ps1）
#
# 装完要重启一次 DSH Desktop 才会加载。

param(
  [string]$Profile   = 'web',
  [string]$DshHome   = '',
  [string]$RepoUrl   = 'https://github.com/CHSCN123/dsh-wechat-desktop.git',
  [string]$LocalPath = '',
  [switch]$SkipConfig,
  [string]$DbDir     = '',
  [string]$ChatUser  = '',
  [string]$PeerName  = '',
  [int]$PanelPort    = 47180
)

$ErrorActionPreference = 'Stop'
function Say($msg) { Write-Host ("[install] " + $msg) }

# ---------- 1. 找 DSH ----------
if ([string]::IsNullOrWhiteSpace($DshHome)) {
  if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME }
  elseif ($env:APPDATA) { $DshHome = Join-Path $env:APPDATA 'dsh-desktop\harness' }
}

$nodeCandidates = @(
  (Join-Path $DshHome '.desktop-bin\node.cmd'),
  (Join-Path $DshHome '.desktop-bin\node.exe')
)
$nodeExe = $nodeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

$binCandidates = @(
  (Join-Path (Split-Path (Split-Path $DshHome -Parent) -Parent) 'resources\app.asar\node_modules\@deepseek-ai\dsh\lib\bin.js'),
  (Join-Path $DshHome '..\..\..\resources\app.asar\node_modules\@deepseek-ai\dsh\lib\bin.js')
)
$dshBin = $binCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not (Test-Path $DshHome)) {
  throw "[install] 找不到 DSH 数据目录：$DshHome。请先安装 DSH Desktop，或用 -DshHome 指定。"
}
if (-not $nodeExe) {
  throw "[install] 找不到 node：$($nodeCandidates -join ' / ')。"
}
if (-not $dshBin) {
  throw "[install] 找不到 dsh 的 bin.js。请确认 DSH Desktop 已安装，或改用：dsh plugin --profile $Profile add <包>"
}
Say "DSH_HOME = $DshHome"
Say "node      = $nodeExe"
Say "dsh bin   = $dshBin"

# ---------- 2. 决定安装来源 ----------
if ([string]::IsNullOrWhiteSpace($LocalPath)) {
  $LocalPath = $PSScriptRoot
}
$hasPackage = Test-Path (Join-Path $LocalPath 'package.json')
if ($hasPackage) {
  Say "从本地目录安装：$LocalPath"
  $spec = $LocalPath
}
else {
  Say "从仓库安装：$RepoUrl"
  $spec = $RepoUrl
}

# ---------- 3. 装进 profile ----------
$env:DSH_HOME = $DshHome
& $nodeExe $dshBin plugin --profile $Profile add $spec
if ($LASTEXITCODE -ne 0) { throw "[install] dsh plugin add 失败（exit $LASTEXITCODE）。" }
Say "插件已加入 profile '$Profile'。"

# 确认 profile 的 bundles 里有它（有的 DSH 版本不会自动加）
$profileDir = Join-Path $DshHome ("profiles\" + $Profile)
$pkgPath = Join-Path $profileDir 'package.json'
if (Test-Path $pkgPath) {
  $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $bundles = @($pkg.dsh.profile.bundles)
  if ($bundles -notcontains 'dsh-wx-desktop') {
    $bundles += 'dsh-wx-desktop'
    $pkg.dsh.profile.bundles = $bundles
    $json = $pkg | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($pkgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Say "已把 dsh-wx-desktop 追加到 dsh.profile.bundles。"
  }
  else {
    Say "dsh.profile.bundles 已包含 dsh-wx-desktop。"
  }
}

# ---------- 4. 配置 ----------
if ($SkipConfig) {
  Say "跳过配置。之后手动跑：.\setup.ps1 -DbDir ... -ChatUser ... -PeerName ..."
}
else {
  if ([string]::IsNullOrWhiteSpace($DbDir) -or [string]::IsNullOrWhiteSpace($ChatUser)) {
    Say "缺少 -DbDir / -ChatUser，跳过配置。稍后手动跑 setup.ps1（见 README）。"
  }
  else {
    $setup = Join-Path $PSScriptRoot 'setup.ps1'
    if (-not (Test-Path $setup)) { throw "[install] 找不到 setup.ps1：$setup" }
    $setupArgs = @('-DbDir', $DbDir, '-ChatUser', $ChatUser, '-PanelPort', $PanelPort)
    if ($PeerName) { $setupArgs += @('-PeerName', $PeerName) }
    if ($DshHome) { $setupArgs += @('-DshHome', $DshHome) }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $setup @setupArgs
    if ($LASTEXITCODE -ne 0) { throw "[install] setup.ps1 失败（exit $LASTEXITCODE）。" }
  }
}

Say "完成。重启 DSH Desktop 后：设置 → 微信桌面桥；或在微信里发 /doctor 自检。"
exit 0
