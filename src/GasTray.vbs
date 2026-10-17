' GasTray hidden launcher: starts GasTray.ps1 with no console window.
Option Explicit
Dim fso, sh, dir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "\GasTray.ps1"""
sh.Run cmd, 0, False
