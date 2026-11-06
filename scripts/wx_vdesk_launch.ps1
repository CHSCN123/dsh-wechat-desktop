param(
  [string]$Desktop = 'dshv-wx',
  [int]$Port = 47660,
  [int]$IdleMinutes = 0,   # 0 = never exit. A desktop dies with its last process, and the WeChat living on it dies too, so the helper must not idle-exit while the bot account is expected to stay online.
  [switch]$Stop,
  [string]$StartExe = '',   # optional: start this program *on* the virtual desktop once the helper is up (e.g. the bot WeChat)
  [switch]$Status
)

# Plan A launcher: creates the helper process *on* the virtual desktop.
#
# A process started normally lives on "Default" and can neither screenshot nor
# inject input into another desktop. CreateProcessW with STARTUPINFO.lpDesktop
# puts the child on "winsta0\<Desktop>" instead, so all of its GDI / SendInput
# calls belong to that desktop.

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$HelperScript = Join-Path $Here 'wx_vdesk_helper.ps1'
$PidFile = Join-Path $Here 'vdesk_helper.pid'
$LogFile = Join-Path $Here 'vdesk_helper.log'
$PS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path $HelperScript)) { throw ("wx_vdesk_launch: missing " + $HelperScript) }

function Stop-Helper {
  if (Test-Path $PidFile) {
    $old = (Get-Content $PidFile -Raw).Trim()
    if ($old -match '^\d+$') {
      $p = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
      if ($p) { Stop-Process -Id $p.Id -Force; "stopped pid=" + $p.Id } else { "pid " + $old + " already gone" }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
  }
  else { "no pid file" }
  Kill-StaleHelpers
}

function Kill-StaleHelpers {
  # Kill every helper that belongs to this desktop, whether or not a pid file
  # survived. Needed when a helper is listening but no longer answering: the port
  # is taken, so starting a fresh one would fail with "address already in use".
  $killed = @()
  try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object { $_.CommandLine -like '*wx_vdesk_helper.ps1*' } |
      ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed += $_.ProcessId } catch { }
      }
  } catch { }
  if ($killed.Count -gt 0) { "killed stale helper pid=" + ($killed -join ',') }
}

function Test-Helper {
  # Must never block for long: a hung helper accepts the TCP connection and then
  # never replies, and a plain ReadLine() would wait ~4 minutes.
  $c = $null
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(1200)) { return $null }
    $c.EndConnect($iar)
    $c.ReceiveTimeout = 3000
    $s = $c.GetStream()
    $w = New-Object System.IO.StreamWriter($s, (New-Object System.Text.UTF8Encoding($false)))
    $w.AutoFlush = $true
    $w.WriteLine('{"action":"ping"}')
    $r = New-Object System.IO.StreamReader($s, [System.Text.Encoding]::UTF8)
    return $r.ReadLine()
  }
  catch { return $null }
  finally { try { if ($c) { $c.Close() } } catch { } }
}

if ($Stop) { Stop-Helper; exit 0 }
if ($Status) {
  $pong = Test-Helper
  if ($pong) { "helper alive: " + $pong } else { "helper not answering on port " + $Port }
  if (Test-Path $PidFile) { "pid file: " + (Get-Content $PidFile -Raw).Trim() }
  exit 0
}

# already running? (still allow -StartExe to launch something on the live desktop)
$pong = Test-Helper
$helperUp = [bool]$pong
if (-not $helperUp) {
  # Nothing answers. If something still holds the port it is a hung helper:
  # clear it first, then start a new one below.
  $busy = $false
  try { $busy = [bool](Test-NetConnection -ComputerName '127.0.0.1' -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue) } catch { }
  if ($busy) { "port " + $Port + " busy but no pong; clearing stale helpers"; Kill-StaleHelpers; Start-Sleep -Milliseconds 800 }
}
if ($helperUp -and $StartExe -eq '') { "helper already running: " + $pong; exit 0 }
if ($helperUp) { "helper already running: " + $pong + " (will still start " + $StartExe + ")" }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WxLauncher {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct STARTUPINFO {
    public int cb;
    public string lpReserved;
    public string lpDesktop;
    public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2;
    public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_INFORMATION {
    public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId;
  }
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool CreateProcess(string lpApplicationName, string lpCommandLine,
    IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags,
    IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool CloseHandle(IntPtr h);

  public static int Start(string exe, string cmdline, string desktop) {
    var si = new STARTUPINFO();
    si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
    si.lpDesktop = desktop;
    si.dwFlags = 0;
    PROCESS_INFORMATION pi;
    bool ok = CreateProcess(null, cmdline, IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, null, ref si, out pi);
    if (!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return pi.dwProcessId;
  }
}
"@

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxDeskCreate {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="CreateDesktopW")]
  public static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr devmode, uint flags, uint access, IntPtr sa);
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);
  public static bool Ensure(string name) {
    IntPtr h = OpenDesktop(name, 0, false, 0x0100 | 0x0001 | 0x0080);
    if (h != IntPtr.Zero) { CloseDesktop(h); return true; }
    IntPtr made = CreateDesktop(name, IntPtr.Zero, IntPtr.Zero, 0, 0x0100 | 0x0001 | 0x0080 | 0x0002 | 0x0004, IntPtr.Zero);
    if (made == IntPtr.Zero) return false;
    CloseDesktop(made);
    return true;
  }
}
"@

$deskPath = 'winsta0\' + $Desktop
if (-not $helperUp) {
  # Create the desktop ourselves when the vdesktop sidecar has not made it yet:
  # this removes the "open the tray panel first" bootstrap step.
  # IMPORTANT: keep the handle open for the whole launch. A freshly created
  # desktop is destroyed as soon as its last handle closes, and then the child we
  # start on it dies right after (that was the "helper starts, never answers" bug).
  $script:deskKeep = [WxDeskCreate]::OpenDesktop($Desktop, 0, $false, 0x000F01FF)
  if ($script:deskKeep -eq [IntPtr]::Zero) {
    $script:deskKeep = [WxDeskCreate]::CreateDesktop($Desktop, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x000F01FF, [IntPtr]::Zero)
  }
  if ($script:deskKeep -eq [IntPtr]::Zero) { throw ("wx_vdesk_launch: cannot create/open desktop '" + $Desktop + "'") }
  "desktop ready: " + $Desktop
  $cmdline = '"' + $PS + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $HelperScript + '" -Desktop "' + $Desktop + '" -Port ' + $Port + ' -IdleMinutes ' + $IdleMinutes
  $pid2 = [WxLauncher]::Start($PS, $cmdline, $deskPath)
  Set-Content -Path $PidFile -Value ([string]$pid2) -Encoding ASCII
  "started helper pid=" + $pid2 + " on " + $deskPath

  $deadline = (Get-Date).AddSeconds(20)
  $last = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 120
    $last = Test-Helper
    if ($last) { break }
  }
  if ($last) { "helper ready: " + $last } else { "helper did not answer within 25s (see " + $LogFile + ")"; exit 1 }
}

if ($StartExe -ne '') {
  if (-not (Test-Path $StartExe)) { "start-exe not found: " + $StartExe; exit 1 }
  $exePid = [WxLauncher]::Start($StartExe, ('"' + $StartExe + '"'), $deskPath)
  "started " + $StartExe + " pid=" + $exePid + " on " + $deskPath
}
