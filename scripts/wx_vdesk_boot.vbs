' Autostart at logon: bring up the hidden virtual desktop dshv-wx and its helper.
' The helper never idle-exits, so the desktop (and anything launched on it, such
' as the bot WeChat) stays alive until you stop it on purpose:
'   wx_vdesk_launch.ps1 -Stop
Set sh = CreateObject("WScript.Shell")
ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = ps & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\Users\LX\.dsh\weixin\wcdb\wx_vdesk_launch.ps1"" -Desktop dshv-wx"
sh.Run cmd, 0, False
