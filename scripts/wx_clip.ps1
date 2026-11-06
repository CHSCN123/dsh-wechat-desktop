# wx_clip.ps1 - put text on the clipboard WITHOUT leaving an entry in the Win+V
# clipboard history.
#
# Why: wx_send.ps1 pastes our reply into WeChat. A plain Set-Clipboard leaves the
# text in the shell's clipboard history (Win+V), which the user noticed and does
# not want. Windows lets an app opt out by setting the clipboard formats
# "CanIncludeInClipboardHistory" and "CanUploadToCloudClipboard" to 0.
#
# ASCII comments only (PS 5.1 reads BOM-less UTF-8 as ANSI).
#
# Usage:
#   wx_clip.ps1 -Text "hello"     # set clipboard, excluded from history
#   wx_clip.ps1 -Clear            # empty the clipboard
param(
  [string]$Text = '',
  [switch]$Clear
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WxClip {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool OpenClipboard(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool EmptyClipboard();
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetClipboardData(uint fmt, IntPtr mem);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseClipboard();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterClipboardFormatW(string name);
  [DllImport("kernel32.dll")] public static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
  [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr mem);
  [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr mem);

  const uint GMEM_MOVEABLE = 0x0002;

  static IntPtr Block(byte[] data) {
    IntPtr mem = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)data.Length);
    if (mem == IntPtr.Zero) return IntPtr.Zero;
    IntPtr p = GlobalLock(mem);
    Marshal.Copy(data, 0, p, data.Length);
    GlobalUnlock(mem);
    return mem;
  }

  public static bool Open() { return OpenClipboard(IntPtr.Zero); }

  public static void EmptyNow() {
    if (OpenClipboard(IntPtr.Zero)) { try { EmptyClipboard(); } finally { CloseClipboard(); } }
  }

  public static bool SetPrivateText(string text) {
    if (!OpenClipboard(IntPtr.Zero)) return false;
    try {
      EmptyClipboard();
      byte[] raw = System.Text.Encoding.Unicode.GetBytes(text + "\0");
      if (SetClipboardData(13, Block(raw)) == IntPtr.Zero) return false;
      uint noHist = RegisterClipboardFormatW("CanIncludeInClipboardHistory");
      uint noCloud = RegisterClipboardFormatW("CanUploadToCloudClipboard");
      byte[] zero = new byte[4];
      if (noHist != 0) SetClipboardData(noHist, Block(zero));
      if (noCloud != 0) SetClipboardData(noCloud, Block(zero));
      return true;
    } finally { CloseClipboard(); }
  }
}
"@

if ($Clear) {
  [WxClip]::EmptyNow()
  Write-Output 'clipboard emptied'
  exit 0
}
if ($Text -eq '') { throw 'wx_clip: pass -Text or -Clear' }
if ([WxClip]::SetPrivateText($Text)) {
  Write-Output ('clipboard set (history-excluded, ' + $Text.Length + ' chars)')
} else {
  Set-Clipboard -Value $Text
  Write-Output 'clipboard set via fallback (may appear in Win+V)'
}
