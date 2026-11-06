param([string]$Desktop = 'dshv-wx', [int]$AutoBackSeconds = 60)
# Toggle the visible input desktop. Safety: after switching INTO the virtual
# desktop, a detached watchdog brings you back after AutoBackSeconds unless you
# already left by yourself. That way a black/empty desktop can never strand you.

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WxToggle {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SwitchDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder info, int len, out int needed);
  public static string NameOf(IntPtr h) {
    var sb = new StringBuilder(256); int need;
    if (!GetUserObjectInformation(h, 2, sb, sb.Capacity, out need)) return "?";
    return sb.ToString();
  }
  public static string Current() {
    IntPtr h = OpenInputDesktop(0, false, 0x0100);
    if (h == IntPtr.Zero) return "?";
    string n = NameOf(h);
    CloseDesktop(h);
    return n;
  }
  public static bool Go(string name) {
    IntPtr h = OpenDesktop(name, 0, false, 0x0100 | 0x0001);
    if (h == IntPtr.Zero) return false;
    bool ok = SwitchDesktop(h);
    CloseDesktop(h);
    return ok;
  }
}
"@

$now = [WxToggle]::Current()
if ($now -eq $Desktop) {
  if ([WxToggle]::Go('Default')) { "back on Default" } else { "cannot switch back to Default"; exit 1 }
  exit 0
}

if (-not [WxToggle]::Go($Desktop)) {
  "cannot switch to " + $Desktop + " (does it exist? the vdesktop sidecar must have created it)"
  exit 1
}
"switched to " + $Desktop + "; auto-return in " + $AutoBackSeconds + "s"

# detached watchdog: if we are still on the virtual desktop after the timeout,
# switch back to Default (the normal desktop).
$ps = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$guard = 'Start-Sleep -Seconds ' + $AutoBackSeconds + '; ' +
  'Add-Type -TypeDefinition ''using System; using System.Runtime.InteropServices; public class WxGuard { ' +
  '[DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint f, bool i, uint a); ' +
  '[DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h); ' +
  '[DllImport("user32.dll")] public static extern IntPtr OpenDesktop(string n, uint f, bool i, uint a); ' +
  '[DllImport("user32.dll")] public static extern bool SwitchDesktop(IntPtr h); }''; ' +
  '$cur = [WxGuard]::OpenInputDesktop(0,$false,0x0100); if($cur -ne [IntPtr]::Zero){ $n = "?" ; [void][WxGuard]::CloseDesktop($cur) }; ' +
  '$h = [WxGuard]::OpenDesktop(''' + $Desktop + ''',0,$false,0x0100); if($h -ne [IntPtr]::Zero){ ' +
  '$d = [WxGuard]::OpenDesktop(''Default'',0,$false,0x0100); if($d -ne [IntPtr]::Zero){ [void][WxGuard]::SwitchDesktop($d); [void][WxGuard]::CloseDesktop($d) }; [void][WxGuard]::CloseDesktop($h) }'
Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-Command',$guard) -WindowStyle Hidden | Out-Null