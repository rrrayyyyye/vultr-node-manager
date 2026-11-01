$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('node-window-smoke-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
foreach($file in @('节点管理.vbs','vultr-node-gui.ps1','node-time.ps1')) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $sandbox $file) }
$config=Get-Content (Join-Path $root 'nodes.example.json') -Raw -Encoding UTF8|ConvertFrom-Json
$prefix='SMOKE-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'-'
foreach($entry in $config.nodes){$entry.name=$prefix+$entry.id}
[IO.File]::WriteAllText((Join-Path $sandbox 'nodes.json'),($config|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $sandbox 'vultr-api.key'),'fixture-not-a-real-key')
$core=@'
param($Action,$Node,[switch]$MachineStatus,[switch]$ConfirmDeletion)
if($Action -ne 'status'){throw 'Window fixtures allow only status'}
$result=@{node=$Node;exists=$false;status='absent'}
Write-Host ('@@NODE_STATUS@@'+($result|ConvertTo-Json -Compress))
'@
[IO.File]::WriteAllText((Join-Path $sandbox 'vultr-node.ps1'),$core,[Text.UTF8Encoding]::new($true))
$path=Join-Path $sandbox 'vultr-node-gui.ps1'
$gui=[IO.File]::ReadAllText($path)
$autoClose=@'
$smokeTimer=New-Object Windows.Forms.Timer
$smokeTimer.Interval=20000
$smokeTimer.Add_Tick({if(-not $script:busy){$form.Close()}})
$smokeTimer.Start()
[void]$form.ShowDialog()
'@
$gui=$gui.Replace('[void]$form.ShowDialog()',$autoClose)
[IO.File]::WriteAllText($path,$gui,[Text.UTF8Encoding]::new($true))
# Exercise the actual launcher and WinForms visibility, with no network API.
foreach($entry in $config.nodes){& wscript.exe (Join-Path $sandbox '节点管理.vbs') $entry.id}
$deadline=[DateTime]::UtcNow.AddSeconds(15)
do {
  Start-Sleep -Milliseconds 400
  $windows=@(Get-Process powershell -ErrorAction SilentlyContinue|Where-Object{$_.MainWindowTitle -like "*$prefix*" -and $_.MainWindowHandle -ne 0})
} while($windows.Count -lt $config.nodes.Count -and [DateTime]::UtcNow -lt $deadline)
foreach($entry in $config.nodes){
  if(-not @($windows|Where-Object{$_.MainWindowTitle -like ('*'+$entry.name)}).Count){throw ('No visible window for '+$entry.id)}
}
Write-Host 'PASS: all three launcher arguments produce visible independent node windows (mock core only); fixtures close automatically'
