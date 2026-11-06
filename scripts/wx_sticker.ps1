param([switch]$DryRun,[int]$Row=-1,[int]$Col=-1,[int]$Seed=-1,[int]$Index=-1,[int]$Pages=4)
# 2026-10-24：旧版按固定比例坐标点，窗口尺寸一变就点飞，已弃用。
# 新版 wx_sticker.py：先截图认图标行 -> 认面板窗口 -> 认 tab 和格子 -> 再点，点完还要回读聊天区确认。
# 2026-10-30：-Index N 按收藏序号发（下载好的 PNG 做图像匹配定位，不依赖行列映射）。
$py = $(if ($env:WX_PYTHON) { $env:WX_PYTHON } else { 'python' })
$script = (Join-Path $PSScriptRoot 'wx_sticker.py')
$argv = @($script)
if ($DryRun) { $argv += '--dry-run' }
if ($Row -ge 0 -and $Col -ge 0) { $argv += @('--row', "$Row", '--col', "$Col") }
if ($Seed -ge 0) { $argv += @('--seed', "$Seed") }
if ($Index -ge 0) { $argv += @('--index', "$Index", '--pages', "$Pages") }
& $py @argv
exit $LASTEXITCODE
