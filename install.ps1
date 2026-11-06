# 微信桌面桥 / WeChat Desk Bridge —— 一键安装
#
# 用法（在克隆出来的目录里）：
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -DbDir "D:\WeChat\...\db_storage" -ChatUser wxid_xxx -PeerName "张三"
#
# 做两件事：
#   1) 把插件装进 DSH 的 profile（dsh plugin add，等价于 pnpm add）
#   2) 调 setup.ps1 写配置块（可用 -SkipConfig 跳过）
#
# 装完重启一次 DSH Desktop 才会加载。

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
function Say($m) { Write-Host ('[install] ' + $m) }

# ---------- 1. 找 DSH_HOME ----------
if ([string]::IsNullOrWhiteSpace($DshHome)) {
  if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME }
  elseif ($env:APPDATA) { $DshHome = Join-Path $env:APPDATA 'dsh-desktop\harness' }
}
if (-not (Test-Path $DshHome)) {
  throw "[install] 找不到 DSH 数据目录：$DshHome。请先安装 DSH Desktop，或用 -DshHome 指定。"
}
$env:DSH_HOME = $DshHome
Say "DSH_HOME = $DshHome"

# ---------- 2. 找 node ----------
$nodeExe = $null
foreach ($c in @((Join-Path $DshHome '.desktop-bin\node.exe'), (Join-Path $DshHome '.desktop-bin\node.cmd'))) {
  if (Test-Path $c) { $nodeExe = $c; break }
}
if (-not $nodeExe) {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { $nodeExe = $cmd.Source }
}
if (-not $nodeExe) { throw '[install] 找不到 node。请装 Node 22+ 或 DSH Desktop。' }
Say "node      = $nodeExe"

# ---------- 3. 找 dsh 入口 ----------
# 优先：正在运行的 DSH Desktop.exe 旁边的 asar；其次：常见安装位置；最后：PATH 里的 dsh
$dshBin = $null
$exeDirs = @()
$proc = Get-Process -Name 'DSH Desktop' -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
if ($proc) { $exeDirs += (Split-Path $proc.Path -Parent) }
foreach ($guess in @(
  (Join-Path $env:LOCALAPPDATA 'Programs\DSH Desktop'),
  (Join-Path $env:ProgramFiles 'DSH Desktop'),
  'E:\DSH\DSH Desktop',
  'D:\DSH\DSH Desktop'
)) { if ($guess) { $exeDirs += $guess } }

foreach ($dir in $exeDirs) {
  $res = Join-Path $dir 'resources'
  $inner = 'node_modules\@deepseek-ai\dsh\lib\bin.js'
  # app.asar 是压缩包：Test-Path 看不到里面的文件，只能判断 asar 本身在不在
  if (Test-Path (Join-Path $res 'app.asar')) {
    $dshBin = Join-Path $res ('app.asar\' + $inner)
    break
  }
  if (Test-Path (Join-Path $res ('app\' + $inner))) {
    $dshBin = Join-Path $res ('app\' + $inner)
    break
  }
}

$dshCmd = $null
if (-not $dshBin) {
  $found = Get-Command dsh -ErrorAction SilentlyContinue
  if ($found) { $dshCmd = $found.Source }
}

if ($dshBin) { Say "dsh bin   = $dshBin" }
elseif ($dshCmd) { Say "dsh       = $dshCmd（走 PATH）" }
else {
  throw '[install] 找不到 DSH 的 dsh 入口：没找到 DSH Desktop 安装目录，PATH 里也没有 dsh。请先打开一次 DSH Desktop，或用 -DshHome，或手动 dsh plugin 安装。'
}

# ---------- 4. 决定安装来源 ----------
if ([string]::IsNullOrWhiteSpace($LocalPath)) { $LocalPath = $PSScriptRoot }
if (Test-Path (Join-Path $LocalPath 'package.json')) {
  Say "从本地目录安装：$LocalPath"
  $spec = $LocalPath
} else {
  Say "从仓库安装：$RepoUrl"
  $spec = $RepoUrl
}

# ---------- 5. 装进 profile ----------
if ($dshBin) { & $nodeExe $dshBin plugin --profile $Profile add $spec }
else { & $dshCmd plugin --profile $Profile add $spec }
if ($LASTEXITCODE -ne 0) { throw "[install] dsh plugin add 失败（exit $LASTEXITCODE）。" }
Say "插件已加入 profile '$Profile'。"

# 确保 bundles 里有它（部分 DSH 版本不会自动加）
$pkgPath = Join-Path $DshHome ("profiles\" + $Profile + '\package.json')
if (Test-Path $pkgPath) {
  $raw = [System.IO.File]::ReadAllText($pkgPath)
  $pkg = $raw | ConvertFrom-Json
  $bundles = @($pkg.dsh.profile.bundles)
  if ($bundles -notcontains 'dsh-wx-desktop') {
    $bundles += 'dsh-wx-desktop'
    $pkg.dsh.profile.bundles = $bundles
    $json = $pkg | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($pkgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Say '已把 dsh-wx-desktop 追加到 dsh.profile.bundles。'
  } else {
    Say 'dsh.profile.bundles 已包含 dsh-wx-desktop。'
  }
}

# 顺手确认会话桥依赖在不在（插件启动时会找它）
$bridgeGuess = Join-Path $DshHome ("profiles\" + $Profile + '\node_modules\dsh-plugin-weixin\src\agent-bridge.js')
if (-not (Test-Path $bridgeGuess)) {
  Say '提示：没找到会话桥（dsh-plugin-weixin）。需要时执行：'
  Say ("        dsh plugin --profile $Profile add dsh-plugin-weixin")
}

# ---------- 6. 写配置 ----------
if ($SkipConfig) {
  Say '跳过配置。之后手动跑：.\setup.ps1 -DbDir ... -ChatUser ... -PeerName ...'
} elseif ([string]::IsNullOrWhiteSpace($DbDir) -or [string]::IsNullOrWhiteSpace($ChatUser)) {
  Say '缺少 -DbDir / -ChatUser，跳过配置。稍后手动跑 setup.ps1（见 README）。'
} else {
  $setup = Join-Path $PSScriptRoot 'setup.ps1'
  if (-not (Test-Path $setup)) { throw "[install] 找不到 setup.ps1：$setup" }
  $args2 = @('-DbDir', $DbDir, '-ChatUser', $ChatUser, '-PanelPort', $PanelPort)
  if ($PeerName) { $args2 += @('-PeerName', $PeerName) }
  if ($DshHome) { $args2 += @('-DshHome', $DshHome) }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $setup @args2
  if ($LASTEXITCODE -ne 0) { throw "[install] setup.ps1 失败（exit $LASTEXITCODE）。" }
}

Say '完成。重启 DSH Desktop 后：设置 → 微信桌面桥；或在微信里发 /doctor 自检。'
exit 0
