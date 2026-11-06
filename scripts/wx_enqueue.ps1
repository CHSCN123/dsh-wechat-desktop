<#
wx_enqueue.ps1 - put one message into the desktop send queue (plan A).

Sessions must NOT call wx_send.ps1 directly any more. Drop a job here and
wx_worker.py sends it in order, one at a time, so two chats can never race
for the single WeChat window.

  wx_enqueue.ps1 -Chat "张三" -Text "hello"
  wx_enqueue.ps1 -Chat "黑暗四天王" -TextFile message.txt
  wx_enqueue.ps1 -List          # show what is waiting
#>
param(
  [string]$Chat = '',
  [string]$Text = '',
  [string]$TextFile = '',
  [string]$Actor = 'session',
  [switch]$List
)
$ErrorActionPreference = 'Stop'
$queue = Join-Path $PSScriptRoot 'send-queue'
if (-not (Test-Path $queue)) { New-Item -ItemType Directory -Path $queue | Out-Null }

if ($List) {
  Get-ChildItem $queue -Filter *.json | Sort-Object LastWriteTime |
    ForEach-Object { "{0}  {1}" -f $_.LastWriteTime.ToString('HH:mm:ss'), $_.Name }
  return
}

if ($TextFile -ne '') { $Text = [System.IO.File]::ReadAllText($TextFile, [System.Text.Encoding]::UTF8) }
if ($Chat -eq '' -or $Text.Trim() -eq '') { throw 'wx_enqueue: need -Chat and (-Text or -TextFile)' }

$job = [ordered]@{ chat = $Chat; text = $Text; actor = $Actor; queuedAt = (Get-Date).ToString('o') }
$name = ('{0}-{1}.json' -f (Get-Date).ToString('HHmmssfff'), ([guid]::NewGuid().ToString('N').Substring(0, 6)))
$path = Join-Path $queue $name
[System.IO.File]::WriteAllText($path, ($job | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
"queued $name for '$Chat' ($($Text.Length) chars)"