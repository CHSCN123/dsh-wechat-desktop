' Open the hidden desktop with the bot WeChat on it.
' If a WeChat window is already on that desktop, do NOT start another one -
' just bring the screen over so the existing login page can be scanned.
' The screen returns to the normal desktop by itself (2 minutes).
Set sh = CreateObject("WScript.Shell")
ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
show = ps & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$PSScriptRoot\wx_vdesk_show.ps1"" -Desktop dshv-wx -Exe ""C:\Program Files\Tencent\WeChat\Weixin.exe"" -AutoBackSeconds 120"
sh.Run show, 0, False