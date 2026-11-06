# 微信桌面桥 / WeChat Desk Bridge —— 一行安装引导
#
# 用法（PowerShell，一行粘进去）：
#   &([scriptblock]::Create((irm https://raw.githubusercontent.com/CHSCN123/dsh-wechat-desktop/main/bootstrap.ps1)))
#
# 它会：把仓库下载到临时目录 → 跑仓库里的 install.ps1 → 装插件 + 写配置。
# 需要先装好 DSH Desktop；会问你小号的微信数据目录和 wxid（也可以提前用 -DbDir/-ChatUser 传）。

param(
  [string]$Ref      = 'main',
  [string]$WorkDir  = '',
  [string]$Profile  = '',
  [string]$DbDir    = '',
  [string]$ChatUser = '',
  [string]$PeerName = '',
  [int]$PanelPort   = 47180,
  [switch]$SkipConfig
)

$ErrorActionPreference = 'Stop'
function Say($m) { Write-Host ('[bootstrap] ' + $m) }

$zip = "https://codeload.github.com/CHSCN123/dsh-wechat-desktop/zip/refs/heads/$Ref"
if ([string]::IsNullOrWhiteSpace($WorkDir)) {
  $WorkDir = Join-Path $env:TEMP 'dsh-wx-desktop-src'
}

$fresh = $false
$pkgJson = Join-Path $WorkDir 'package.json'
if (Test-Path $pkgJson) {
  try {
    $pkg = Get-Content $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($pkg.name -eq 'dsh-wx-desktop') {
      Say "已有下载好的源码：$WorkDir（想强制重下就删掉它，或加 -WorkDir）"
    } else { $fresh = $true }
  } catch { $fresh = $true }
} else { $fresh = $true }

if ($fresh) {
  Say "下载仓库源码（$Ref）…"
  $tmpZip = Join-Path $env:TEMP ('wxdesk-' + [guid]::NewGuid().ToString('N') + '.zip')
  Invoke-WebRequest -Uri $zip -OutFile $tmpZip -UseBasicParsing
  $extract = Join-Path $env:TEMP ('wxdesk-' + [guid]::NewGuid().ToString('N'))
  Expand-Archive -Path $tmpZip -DestinationPath $extract -Force
  Remove-Item $tmpZip -Force
  $inner = Get-ChildItem $extract -Directory | Select-Object -First 1
  if (-not $inner) { throw '[bootstrap] 解压后没找到目录，下载可能失败了。' }
  if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
  Move-Item $inner.FullName $WorkDir
  Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
  Say "源码就位：$WorkDir"
}

$installer = Join-Path $WorkDir 'install.ps1'
if (-not (Test-Path $installer)) { throw "[bootstrap] 没找到 install.ps1：$installer" }

$fwd = @()
if ($Profile)  { $fwd += @('-Profile', $Profile) }
if ($DbDir)    { $fwd += @('-DbDir', $DbDir) }
if ($ChatUser) { $fwd += @('-ChatUser', $ChatUser) }
if ($PeerName) { $fwd += @('-PeerName', $PeerName) }
if ($PanelPort) { $fwd += @('-PanelPort', $PanelPort) }
if ($SkipConfig) { $fwd += @('-SkipConfig') }

Say '开始安装…'
& powershell -NoProfile -ExecutionPolicy Bypass -File $installer @fwd
exit $LASTEXITCODE
