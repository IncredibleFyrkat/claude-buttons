' Launches the panel without a console window.
' Uses the built-in Windows PowerShell 5.1 (powershell.exe), NOT pwsh 7.
Set sh = CreateObject("WScript.Shell")
scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "claude-buttons.ps1""", 0, False
