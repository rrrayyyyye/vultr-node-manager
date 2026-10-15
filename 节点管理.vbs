' Vultr node manager - portable launcher. No install needed.
Option Explicit

Dim fso, sh, here, ps1
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = fso.BuildPath(here, "vultr-node-gui.ps1")

If Not fso.FileExists(ps1) Then
  MsgBox "Cannot find vultr-node-gui.ps1 next to this launcher:" & vbCrLf & ps1, 16, "Vultr Node Manager"
  WScript.Quit 1
End If

If Not fso.FileExists(fso.BuildPath(here, "nodes.json")) Or Not fso.FileExists(fso.BuildPath(here, "vultr-api.key")) Then
  MsgBox "Local settings are missing. Run setup.ps1 first. See README.md for migration instructions.", 48, "Vultr Node Manager"
  WScript.Quit 1
End If

sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
