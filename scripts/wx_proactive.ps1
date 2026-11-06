# wx_proactive.ps1 - send a message nobody asked for, with a hard daily budget.
# Usage:
#   wx_proactive.ps1 -Chat "猪葛凉" -Text "在干嘛呀" [-Limit 2]
# Behaviour:
#   * counts today's `proactive` rows in activity.jsonl for the same chat
#   * refuses (exit 3) once the budget is used up
#   * opens the chat, sends the text, then logs a `proactive` row
# ASCII-only comments: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
param(
  [Parameter(Mandatory=$true)][string]$Chat,
  [Parameter(Mandatory=$true)][string]$Text,
  [int]$Limit = 2,
  [string]$Ledger = "C:\Users\LX\.dsh\weixin\wcdb\activity.jsonl",
  [string]$OpenScript = "C:\Users\LX\.dsh\weixin\wcdb\wx_open_chat.ps1",
  [string]$SendScript = "C:\Users\LX\.dsh\weixin\wcdb\wx_send.ps1",
  [string]$Activity = "C:\Users\LX\.dsh\weixin\wcdb\wx_activity.ps1"
)

$ErrorActionPreference = "Stop"
$today = (Get-Date).ToString("yyyy-MM-dd")

$used = 0
if (Test-Path $Ledger) {
  foreach ($line in [System.IO.File]::ReadAllLines($Ledger, [System.Text.Encoding]::UTF8)) {
    if ($line.Trim() -eq "") { continue }
    try { $row = $line | ConvertFrom-Json } catch { continue }
    if ($row.kind -ne "proactive") { continue }
    if ($row.chat -ne $Chat) { continue }
    if (([string]$row.ts).StartsWith($today)) { $used++ }
  }
}

if ($used -ge $Limit) {
  "refused: proactive budget for '$Chat' used up today ($used/$Limit)"
  exit 3
}

& $OpenScript -Name $Chat | Out-Null
& $SendScript -Text $Text -Actor "proactive" | Select-Object -Last 2

try {
  & $Activity -Add -Kind proactive -Actor proactive -Text $Text -Sender $Chat | Out-Null
} catch { }

"proactive sent ($($used + 1)/$Limit today) to $Chat"
