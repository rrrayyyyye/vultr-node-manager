' Vultr node manager - portable launcher. No install needed.
Option Explicit

Dim fso, sh, here, ps1, node, pattern, command
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

node = "tokyo"
If WScript.Arguments.Count > 0 Then node = WScript.Arguments(0)
Set pattern = New RegExp
pattern.Pattern = "^[a-z0-9-]+$"
If Not pattern.Test(node) Then
  MsgBox "Invalid node ID.", 16, "Vultr Node Manager"
  WScript.Quit 1
End If
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """ -Node " & node
sh.Run command, 0, False
