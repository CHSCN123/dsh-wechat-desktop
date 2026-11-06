# wx_check_scripts.ps1 - sanity check for every .ps1 helper in this folder.
#
# Why this exists: PowerShell 5.1 parses BOM-less UTF-8 files as ANSI, so a
# Chinese comment or string silently turns into mojibake and the parser starts
# failing with messages like "string is missing the terminator". That happened
# on 2026-10-25 after two agents edited the same scripts, and every send broke
# until the BOM was put back.
#
# Run it after touching any script here:
#   powershell -NoProfile -ExecutionPolicy Bypass -File wx_check_scripts.ps1
param([switch]$FixBom)

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$bad = 0
Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
  $name = $_.Name
  $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $notes = @()
  if (-not $hasBom) {
    if ($FixBom) {
      $text = [System.Text.Encoding]::UTF8.GetString($bytes)
      [System.IO.File]::WriteAllText($_.FullName, $text, $utf8Bom)
      $notes += 'BOM added'
    } else {
      $notes += 'NO BOM'
    }
  }
  $err = $null
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$err) | Out-Null
  if ($err -and $err.Count -gt 0) {
    $notes += ('parse errors: ' + $err.Count + ' | first: ' + $err[0].Message)
  }
  if ($notes.Count -gt 0) {
    $bad++
    Write-Output ($name + ' -> ' + ($notes -join '; '))
  }
}
if ($bad -eq 0) {
  Write-Output 'all scripts ok (BOM + syntax)'
} else {
  Write-Output ('' + $bad + ' script(s) need attention')
}
