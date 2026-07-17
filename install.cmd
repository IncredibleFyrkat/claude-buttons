@echo off
REM Double-click entry point. Runs the PowerShell installer from this folder.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
