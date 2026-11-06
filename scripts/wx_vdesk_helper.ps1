param(
  [string]$Desktop = 'dshv-wx',
  [int]$Port = 47660,
  [int]$IdleMinutes = 0,      # 0 = never exit on idle
  [int]$RequestTimeoutSeconds = 45,
  [string]$LogFile = (Join-Path $PSScriptRoot 'vdesk_helper.log')
)

# Plan A helper: lives ON the virtual desktop (see wx_vdesk_launch.ps1).
#
# Rules learned the hard way:
#  1. ONE request at a time is fine, but every child process must be time-boxed,
#     otherwise a stuck child blocks the loop forever ("port listens, never answers").
#  2. Child PowerShell calls go through Start-Process + Wait-Process -Timeout and get
#     killed on timeout, so the loop always comes back.
#  3. Never use $args as a variable (automatic variable, clashes with splatting).
#
# Protocol: TCP 127.0.0.1:<Port>, one JSON line request, one JSON line reply.
#   {"action":"ping"} | "send"{chat,text,verifyChat} | "shot"{out} |
#   "exec"{script,args[]} | "spawn"{script,args[]} | "windows" | "start"{exe} |
#   "stop" (reply first, then exit)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxEnter {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint fl, IntPtr ex);

  public static bool Raise(IntPtr h) {
    if (!IsWindow(h)) return false;
    keybd_event(0x12, 0x38, 0, IntPtr.Zero); keybd_event(0x12, 0x38, 2, IntPtr.Zero);
    IntPtr fg = GetForegroundWindow();
    uint fpid = 0; uint ftid = GetWindowThreadProcessId(fg, out fpid);
    uint mytid = GetCurrentThreadId();
    bool att = (ftid != 0 && ftid != mytid) && AttachThreadInput(mytid, ftid, true);
    ShowWindow(h, 9); BringWindowToTop(h); SetForegroundWindow(h);
    if (att) AttachThreadInput(mytid, ftid, false);
    return true;
  }
}
"@

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxDeskHelper {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SwitchDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr h, int index, System.Text.StringBuilder info, int len, out int needed);
  public static string NameOf(IntPtr h) {
    var sb = new System.Text.StringBuilder(256); int need;
    if (!GetUserObjectInformation(h, 2, sb, sb.Capacity, out need)) return "?";
    return sb.ToString();
  }
}
"@

$PS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$HelperDir = Split-Path -Parent $PSCommandPath
$Send = (Join-Path $PSScriptRoot 'wx_send.ps1')

function Write-Log([string]$line) {
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  try { Add-Content -Path $LogFile -Value ("[" + $ts + "] " + $line) -Encoding UTF8 } catch { }
}

function Get-InputDesktopName {
  $h = [WxDeskHelper]::OpenInputDesktop(0, $false, 0x0100)
  if ($h -eq [IntPtr]::Zero) { return '?' }
  $n = [WxDeskHelper]::NameOf($h)
  [void][WxDeskHelper]::CloseDesktop($h)
  return $n
}

function Switch-To([string]$name) {
  $h = [WxDeskHelper]::OpenDesktop($name, 0, $false, 0x0100 -bor 0x0001 -bor 0x0080)
  if ($h -eq [IntPtr]::Zero) { throw ("cannot open desktop '" + $name + "'") }
  if (-not [WxDeskHelper]::SwitchDesktop($h)) {
    [void][WxDeskHelper]::CloseDesktop($h)
    throw ("SwitchDesktop('" + $name + "') failed")
  }
  return $h
}

# Run a child powershell script with a hard timeout. Returns @{code;out}.
function Invoke-TimedScript([string]$script, [string[]]$scriptArgs, [int]$timeoutSec) {
  $psi = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $scriptArgs
  $p = Start-Process -FilePath $PS -ArgumentList $psi -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput ($LogFile + '.out.tmp') -RedirectStandardError ($LogFile + '.err.tmp')
  $finished = $true
  try { Wait-Process -Id $p.Id -Timeout $timeoutSec -ErrorAction Stop } catch { $finished = $false }
  if (-not $finished) {
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
    return @{ code = 124; out = ('timed out after ' + $timeoutSec + 's: ' + (Split-Path -Leaf $script)) }
  }
  $out = ''
  try { $out = (Get-Content ($LogFile + '.out.tmp') -Raw -Encoding UTF8) } catch { }
  try { $out = $out + (Get-Content ($LogFile + '.err.tmp') -Raw -Encoding UTF8) } catch { }
  return @{ code = $p.ExitCode; out = ([string]$out).Trim() }
}

function With-Desktop([scriptblock]$body) {
  $prev = Get-InputDesktopName
  $h = $null
  try {
    $h = Switch-To $Desktop
    Start-Sleep -Milliseconds 300
    return (& $body)
  }
  finally {
    try { if ($prev -ne '' -and $prev -ne '?') { $d = Switch-To $prev; [void][WxDeskHelper]::CloseDesktop($d) } }
    catch { Write-Log ("switch back failed: " + $_.Exception.Message) }
    if ($null -ne $h) { [void][WxDeskHelper]::CloseDesktop($h) }
  }
}

function Handle-Send($req) {
  $chat = [string]$req.chat
  $text = [string]$req.text
  $verify = [string]$req.verifyChat
  if ($chat -eq '' -or $text -eq '') { throw 'send needs chat + text' }
  $scriptArgs = @('-Chat', $chat, '-Text', $text)
  if ($verify -ne '') { $scriptArgs += @('-VerifyChat', $verify) }
  $r = With-Desktop { Invoke-TimedScript $Send $scriptArgs $RequestTimeoutSeconds }
  Write-Log ("send chat=" + $chat + " code=" + $r.code + " out=" + (($r.out -replace "`r?`n", ' | ')))
  return @{ ok = ($r.code -eq 0); code = $r.code; out = $r.out }
}

function Handle-Exec($req) {
  $script = [string]$req.script
  if ($script -eq '') { throw 'exec needs script' }
  $scriptArgs = @()
  if ($req.args) { foreach ($a in $req.args) { $scriptArgs += [string]$a } }
  $r = With-Desktop { Invoke-TimedScript $script $scriptArgs $RequestTimeoutSeconds }
  Write-Log ("exec " + (Split-Path -Leaf $script) + " code=" + $r.code)
  return @{ ok = ($r.code -eq 0); code = $r.code; out = $r.out }
}

function Handle-Spawn($req) {
  $script = [string]$req.script
  if ($script -eq '') { throw 'spawn needs script' }
  $scriptArgs = @()
  if ($req.args) { foreach ($a in $req.args) { $scriptArgs += [string]$a } }
  $psi = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $script) + $scriptArgs
  Start-Process -FilePath $PS -ArgumentList $psi -WindowStyle Hidden | Out-Null
  Write-Log ("spawn " + (Split-Path -Leaf $script) + " args=" + ($scriptArgs -join ' '))
  return @{ ok = $true; code = 0; out = ('spawned ' + $script) }
}

function Handle-Shot($req) {
  $out = [string]$req.out
  if ($out -eq '') { throw 'shot needs out' }
  $r = With-Desktop {
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap ([int]$b.Width), ([int]$b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    'saved ' + $out
  }
  return @{ ok = $true; code = 0; out = $r }
}

function Handle-Windows {
  $items = @()
  foreach ($p in Get-Process) {
    try {
      if ($p.MainWindowHandle -ne 0 -and $p.MainWindowTitle -ne '') {
        $items += [pscustomobject]@{ pid = $p.Id; title = $p.MainWindowTitle }
      }
    } catch { }
  }
  return @{ ok = $true; code = 0; count = $items.Count; windows = $items }
}

function Handle-Start($req) {
  $exe = [string]$req.exe
  if ($exe -eq '') { throw 'start needs exe' }
  Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) | Out-Null
  Write-Log ("start " + $exe + " on " + $Desktop)
  return @{ ok = $true; code = 0; out = ('started ' + $exe) }
}

# --- fast enter -------------------------------------------------------------
# The user asked for this to be quick: locate the WeChat window ONCE per launch,
# cache its hwnd, and on later launches just raise the cached hwnd (a single
# IsWindow check) instead of scanning every time. No polling loops.
$CacheFile = Join-Path $HelperDir 'vdesk-wechat.json'

function Read-Cache {
  try {
    if (Test-Path $CacheFile) { return (Get-Content $CacheFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
  } catch { }
  return $null
}
function Write-Cache([int64]$hwnd, [int]$procPid, $rect) {
  try {
    @{ hwnd = $hwnd; pid = $procPid; rect = $rect; at = (Get-Date).ToString('s') } |
      ConvertTo-Json -Compress | ForEach-Object { [System.IO.File]::WriteAllText($CacheFile, $_, (New-Object System.Text.UTF8Encoding($false))) }
  } catch { }
}

function Find-WeChatWindow {
  # One pass, no waiting: any process with a main window whose title looks like WeChat.
  foreach ($p in Get-Process) {
    try {
      if ($p.MainWindowHandle -ne 0 -and $p.MainWindowTitle -match '微信|WeChat|Weixin') {
        return @{ hwnd = $p.MainWindowHandle; pid = $p.Id }
      }
    } catch { }
  }
  return $null
}

function Handle-Enter($req) {
  $exe = [string]$req.exe
  $autoBack = 0
  if ($null -ne $req.autoBackSeconds) { $autoBack = [int]$req.autoBackSeconds }
  $started = $false
  $t0 = Get-Date

  $hit = $null
  $cache = Read-Cache
  if ($null -ne $cache -and [int64]$cache.hwnd -ne 0) {
    $h = [IntPtr][int64]$cache.hwnd
    if ([WxEnter]::IsWindow($h)) { $hit = @{ hwnd = $h; pid = [int]$cache.pid; fromCache = $true } }
  }
  if ($null -eq $hit) {
    $hit = Find-WeChatWindow
    if ($null -ne $hit) {
      $r = New-Object WxEnter+RECT
      [void][WxEnter]::GetWindowRect([IntPtr][int64]$hit.hwnd, [ref]$r)
      Write-Cache ([int64]$hit.hwnd) ([int]$hit.pid) @{ left = $r.Left; top = $r.Top; right = $r.Right; bottom = $r.Bottom }
      Write-Log ("enter: located wechat hwnd=" + $hit.hwnd + " pid=" + $hit.pid)
    }
  }

  if ($null -eq $hit) {
    if ($exe -ne '') {
      Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) | Out-Null
      $started = $true
      Write-Log ("enter: no wechat window; started " + $exe)
    }
  }
  else {
    [void][WxEnter]::Raise([IntPtr][int64]$hit.hwnd)
    # centre it only if it is off-screen or tiny (login window is 294x387 by default)
    $r = New-Object WxEnter+RECT
    [void][WxEnter]::GetWindowRect([IntPtr][int64]$hit.hwnd, [ref]$r)
    $w = $r.Right - $r.Left; $h2 = $r.Bottom - $r.Top
    if ($r.Left -lt 0 -or $r.Top -lt 0 -or $w -lt 200 -or $h2 -lt 200) {
      [void][WxEnter]::SetWindowPos([IntPtr][int64]$hit.hwnd, [IntPtr]::Zero, 600, 200, [Math]::Max($w, 420), [Math]::Max($h2, 560), 0x0040)
    }
  }

  $script:autoBackAt = if ($autoBack -gt 0) { (Get-Date).AddSeconds($autoBack) } else { $null }
  if ($autoBack -gt 0) {
    $esc = Join-Path $HelperDir 'wx_vdesk_escape.ps1'
    if (Test-Path $esc) {
      Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $esc, '-TimeoutSeconds', [string]$autoBack) -WindowStyle Hidden | Out-Null
    }
  }

  $prev = Get-InputDesktopName
  $dh = $null
  try {
    if ($prev -ne $Desktop) { $dh = Switch-To $Desktop }
  }
  finally {
    if ($null -ne $dh) { [void][WxDeskHelper]::CloseDesktop($dh) }
  }

  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  Write-Log ("enter done in " + $ms + "ms started=" + $started)
  return @{
    ok = $true; code = 0; started = $started; ms = $ms
    fromCache = [bool]($null -ne $hit -and $hit.ContainsKey('fromCache') -and $hit.fromCache)
    hwnd = $(if ($null -ne $hit) { [int64]$hit.hwnd } else { 0 })
    out = ('enter in ' + $ms + 'ms' + $(if ($started) { ' (wechat starting)' } else { '' }))
  }
}

# --- server loop -----------------------------------------------------------
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Log ("helper listening on 127.0.0.1:" + $Port + " desktop=" + $Desktop + " input=" + (Get-InputDesktopName) + " pid=" + $PID)

$stop = $false
$lastSeen = Get-Date

while (-not $stop) {
  if (-not $listener.Pending()) {
    Start-Sleep -Milliseconds 200
    if ($null -ne $script:autoBackAt -and (Get-Date) -ge $script:autoBackAt) {
      $script:autoBackAt = $null
      try {
        $dd = [WxDeskHelper]::OpenDesktop('Default', 0, $false, 0x000F01FF)
        if ($dd -ne [IntPtr]::Zero) {
          if ([WxDeskHelper]::SwitchDesktop($dd)) { Write-Log 'auto-back -> Default (nobody clicked)' }
          [void][WxDeskHelper]::CloseDesktop($dd)
        }
      } catch { Write-Log ('auto-back failed: ' + $_.Exception.Message) }
    }
    if ($IdleMinutes -gt 0 -and ((Get-Date) - $lastSeen).TotalMinutes -ge $IdleMinutes) {
      Write-Log ("idle for " + $IdleMinutes + " min; exiting")
      break
    }
    continue
  }

  $client = $null
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $client = $listener.AcceptTcpClient()
    $client.ReceiveTimeout = 15000
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true

    $line = $reader.ReadLine()
    $reply = $null
    if ([string]::IsNullOrWhiteSpace($line)) {
      $reply = @{ ok = $false; code = 2; out = 'empty request' }
    }
    else {
      try {
        $req = $line | ConvertFrom-Json
        switch ([string]$req.action) {
          'ping'    { $reply = @{ ok = $true; code = 0; out = ('pong input=' + (Get-InputDesktopName) + ' pid=' + $PID) } }
          'enter'   { $reply = Handle-Enter $req }
          'send'    { $reply = Handle-Send $req }
          'shot'    { $reply = Handle-Shot $req }
          'exec'    { $reply = Handle-Exec $req }
          'spawn'   { $reply = Handle-Spawn $req }
          'windows' { $reply = Handle-Windows }
          'start'   { $reply = Handle-Start $req }
          'stop'    { $reply = @{ ok = $true; code = 0; out = 'stopping' }; $stop = $true }
          default   { $reply = @{ ok = $false; code = 2; out = ('unknown action: ' + [string]$req.action) } }
        }
      }
      catch {
        $reply = @{ ok = $false; code = 1; out = $_.Exception.Message }
        Write-Log ("error: " + $_.Exception.Message)
      }
    }
    $writer.WriteLine(($reply | ConvertTo-Json -Compress -Depth 5))
    $writer.Flush()
    $lastSeen = Get-Date
  }
  catch {
    Write-Log ("connection error: " + $_.Exception.Message)
  }
  finally {
    try { if ($null -ne $client) { $client.Close() } } catch { }
    Write-Log ("handled in " + [int]$sw.Elapsed.TotalMilliseconds + "ms")
  }
}

try { $listener.Stop() } catch { }
Write-Log "helper exited"
