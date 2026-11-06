# Adds (or with -Remove, removes) a Startup shortcut that runs AppleMusicRPC.ps1 hidden at login.
param([switch]$Remove)
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'AppleMusicRPC.lnk'
if ($Remove) { Remove-Item $lnk -ErrorAction SilentlyContinue; "Removed $lnk"; return }
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\AppleMusicRPC.ps1`""
$s.WorkingDirectory = $PSScriptRoot
$s.Save()
"Created $lnk - it will start at your next login. Start it now with:"
"  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\AppleMusicRPC.ps1`"'"
