param(
  [ValidateSet('status','switch','back','roundtrip','capture')]
  [string]$Action = 'status',
  [string]$Desktop = 'dshv-wx',
  [string]$Out = '',
  [int]$HoldMs = 800
)

# Switch the *input desktop* to a virtual desktop (created by the vdesktop
# plugin) and back. Windows only delivers SendInput to the active desktop, so
# this is the enabling trick for plan A: while switched, the normal scripts
# (SetCursorPos/mouse_event/keybd_event + GDI screenshots) behave exactly as
# they do on the main desktop.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxDesk {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SwitchDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetThreadDesktop(uint threadId);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr h, int index, System.Text.StringBuilder info, int len, out int needed);
  public static string NameOf(IntPtr h) {
    var sb = new System.Text.StringBuilder(256);
    int need;
    if (!GetUserObjectInformation(h, 2, sb, sb.Capacity, out need)) return "?";
    return sb.ToString();
  }
}
"@

function Open-Target([string]$name) {
  # 0x0100 = DESKTOP_SWITCHDESKTOP, 0x0001 = DESKTOP_READOBJECTS, 0x0080 = DESKTOP_WRITEOBJECTS
  $h = [WxDesk]::OpenDesktop($name, 0, $false, 0x0100 -bor 0x0001 -bor 0x0080)
  if ($h -eq [IntPtr]::Zero) { throw ("wx_vdesk: cannot open desktop '" + $name + "' (winerror=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error() + ")") }
  return $h
}
function Current-InputName {
  $h = [WxDesk]::OpenInputDesktop(0, $false, 0x0100)
  if ($h -eq [IntPtr]::Zero) { return '?' }
  $n = [WxDesk]::NameOf($h)
  [void][WxDesk]::CloseDesktop($h)
  return $n
}

switch ($Action) {
  'status' {
    "input desktop = " + (Current-InputName)
    try { $h = Open-Target $Desktop; "target '" + $Desktop + "' exists"; [void][WxDesk]::CloseDesktop($h) }
    catch { "target '" + $Desktop + "' missing: " + $_.Exception.Message }
  }
  'switch' {
    $h = Open-Target $Desktop
    if (-not [WxDesk]::SwitchDesktop($h)) { throw ("wx_vdesk: SwitchDesktop failed (winerror=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error() + ")") }
    Start-Sleep -Milliseconds 400
    "input desktop now = " + (Current-InputName)
    # keep handle open in $script: so a later 'back' in the same process can use it
    $script:deskHandle = $h
  }
  'back' {
    $def = [WxDesk]::OpenDesktop('Default', 0, $false, 0x0100 -bor 0x0001)
    if ($def -eq [IntPtr]::Zero) { throw 'wx_vdesk: cannot open Default desktop' }
    if (-not [WxDesk]::SwitchDesktop($def)) { throw ("wx_vdesk: switch back failed (winerror=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error() + ")") }
    [void][WxDesk]::CloseDesktop($def)
    Start-Sleep -Milliseconds 300
    "input desktop back to " + (Current-InputName)
  }
  'capture' {
    if ($Out -eq '') { throw 'wx_vdesk: -Action capture needs -Out <png>' }
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap ([int]$b.Width), ([int]$b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    "captured " + $Out
  }
  'roundtrip' {
    $before = Current-InputName
    $h = Open-Target $Desktop
    if (-not [WxDesk]::SwitchDesktop($h)) { throw 'wx_vdesk: SwitchDesktop failed' }
    Start-Sleep -Milliseconds 500
    $during = Current-InputName
    if ($Out -ne '') {
      Add-Type -AssemblyName System.Drawing, System.Windows.Forms
      $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
      $bmp = New-Object System.Drawing.Bitmap ([int]$b.Width), ([int]$b.Height)
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
      $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
      $g.Dispose(); $bmp.Dispose()
      "captured " + $Out
    }
    $def = [WxDesk]::OpenDesktop('Default', 0, $false, 0x0100 -bor 0x0001)
    if ($def -eq [IntPtr]::Zero) { throw 'wx_vdesk: cannot open Default desktop' }
    [void][WxDesk]::SwitchDesktop($def)
    [void][WxDesk]::CloseDesktop($def)
    [void][WxDesk]::CloseDesktop($h)
    Start-Sleep -Milliseconds 300
    "before=" + $before + " during=" + $during + " after=" + (Current-InputName)
  }
}
