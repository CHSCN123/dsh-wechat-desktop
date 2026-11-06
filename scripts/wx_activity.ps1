# wx_activity.ps1 - shared activity ledger for BOTH agents that drive the bot client.
# ASCII comments only (PS 5.1 reads BOM-less UTF-8 as ANSI and mojibake in a
# comment can swallow the next line).
#
# Usage:
#   wx_activity.ps1 -Add -Kind text    -Actor textbot -Text "..." [-Sender peer|self]
#   wx_activity.ps1 -Add -Kind sticker -Actor stickerme -Text "cell=2,1"
#   wx_activity.ps1 -Tail 10
param(
  [switch]$Add,
  [switch]$Tail,
  [string]$Kind = 'text',
  [string]$Actor = 'unknown',
  [string]$Text = '',
  [string]$Sender = 'self',
  [int]$N = 10,
  [string]$Path = 'C:\Users\LX\.dsh\weixin\wcdb\activity.jsonl'
)
$ErrorActionPreference = 'Stop'
if ($Add) {
  $rec = [ordered]@{
    ts     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    actor  = $Actor
    kind   = $Kind
    sender = $Sender
    text   = $Text
  }
  $line = ($rec | ConvertTo-Json -Compress)
  Add-Content -Path $Path -Value $line -Encoding UTF8
  Write-Output ("logged " + $line)
  exit 0
}
if ($Tail) {
  if (-not (Test-Path $Path)) { Write-Output '(ledger empty)'; exit 0 }
  Get-Content -Path $Path -Encoding UTF8 -Tail $N | ForEach-Object {
    try {
      $o = $_ | ConvertFrom-Json
      ('{0}  {1,-9} {2,-7} {3}  {4}' -f $o.ts, $o.actor, $o.kind, $o.sender, $o.text)
    } catch { $_ }
  }
  exit 0
}
Write-Output 'nothing to do: pass -Add or -Tail'