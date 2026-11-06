<#
wx_open_chat.ps1 - thin wrapper kept for the plugin's older default.
It delegates to wx_find_chat.ps1 (look at the chat list, click the row,
verify the header) so every caller gets the same "look before you send" path.
#>
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [int]$Hwnd = 0,
  # 插件有的版本按 -ExpectNotContains / -NotContains 传，都接住，免得报「找不到参数」
  [string]$NotContains = '',
  [string]$ExpectNotContains = '',
  [string]$ExpectChat = ''
)
if (-not $NotContains -and $ExpectNotContains) { $NotContains = $ExpectNotContains }
if ($ExpectChat) { $Name = $ExpectChat }
$finder = Join-Path $PSScriptRoot 'wx_find_chat.ps1'
$fArgs = @('-Name', $Name)
$listFile = Join-Path $PSScriptRoot 'watched-chats.txt'
$chatId = ''
if (Test-Path $listFile) {
  foreach ($ln in (Get-Content $listFile -Encoding UTF8)) {
    $ln = $ln.Trim()
    if ($ln -eq '' -or $ln.StartsWith('#')) { continue }
    $parts = $ln -split '\|'
    if ($parts.Count -ge 2 -and $parts[1].Trim() -eq $Name) { $chatId = $parts[0].Trim(); break }
  }
}
if (-not ($chatId -ne '' -and $chatId.EndsWith('@chatroom'))) { $fArgs += @('-NotContains', '、') }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $finder @fArgs
exit $LASTEXITCODE