@echo off
rem Rolled back 2026-10-31: slower step-by-step enter (was: direct fast client call).
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$PSScriptRoot\wx_vdesk_enter.ps1" -AutoBackSeconds 60
