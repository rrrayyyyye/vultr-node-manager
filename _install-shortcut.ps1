$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs  = Join-Path $here '节点管理.vbs'
if (-not (Test-Path -LiteralPath $vbs)) { Write-Host "找不到启动器：$vbs"; exit 1 }

$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'Vultr节点管理.lnk'

$sh = New-Object -ComObject WScript.Shell
$sc = $sh.CreateShortcut($lnk)
$sc.TargetPath       = "$env:SystemRoot\System32\wscript.exe"
$sc.Arguments        = '"' + $vbs + '"'
$sc.WorkingDirectory = $here
$sc.Description      = 'Vultr 多地区节点管理（东京 / 洛杉矶）'
$sc.IconLocation     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
$sc.Save()

Write-Host "已创建桌面图标：$lnk"
