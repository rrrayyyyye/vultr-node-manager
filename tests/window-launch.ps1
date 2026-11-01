$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('node-dashboard-smoke-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
foreach($file in @('节点管理.vbs','vultr-node-gui.ps1','node-time.ps1')) {
  Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $sandbox $file)
}
$config=Get-Content (Join-Path $root 'nodes.example.json') -Raw -Encoding UTF8|ConvertFrom-Json
[IO.File]::WriteAllText((Join-Path $sandbox 'nodes.json'),($config|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $sandbox 'vultr-api.key'),'fixture-not-a-real-key')
$core=@'
param($Action,$Node,[switch]$MachineStatus,[switch]$ConfirmDeletion)
if($Action -ne 'status'){throw 'Dashboard fixtures allow only status'}
$countPath=Join-Path $PSScriptRoot ($Node+'.count')
$count=0
if(Test-Path $countPath){$count=[int]([IO.File]::ReadAllText($countPath))}
[IO.File]::WriteAllText($countPath,[string]($count+1))
if($Node -eq 'tokyo'){Start-Sleep -Seconds 6}
elseif($Node -eq 'atlanta-v6' -and $count -gt 0){Write-Error 'fixture network failure';exit 7}
$result=@{node=$Node;name=$Node;exists=$true;id=('fixture-'+$Node);ip='192.0.2.1';domain='example.invalid';dnsIp='192.0.2.1';dnsMatches=$true;port443=$true;status='active';powerStatus='running';createdAtUtc='2026-10-01T00:00:00Z'}
Write-Host ('@@NODE_STATUS@@'+($result|ConvertTo-Json -Compress))
'@
[IO.File]::WriteAllText((Join-Path $sandbox 'vultr-node.ps1'),$core,[Text.UTF8Encoding]::new($true))
$path=Join-Path $sandbox 'vultr-node-gui.ps1'
$gui=[IO.File]::ReadAllText($path)
$probe=@'
$script:qaPhase=0
$script:qaDeadline=[DateTime]::UtcNow.AddSeconds(22)
$qaTimer=New-Object Windows.Forms.Timer
$qaTimer.Interval=100
$qaTimer.Add_Tick({
  try {
    if([DateTime]::UtcNow -gt $script:qaDeadline){throw ('Timed out in phase '+$script:qaPhase)}
    if($modules.Count -ne 3 -or $cards.Controls.Count -ne 3){throw 'Missing node cards'}
    if($cards.Width -lt $scroll.ClientSize.Width -or $cards.Height -lt $scroll.ClientSize.Height){throw 'Node cards did not fill the dashboard'}
    if([Windows.Forms.Application]::OpenForms.Count -ne 1 -or -not $dashboard.Visible -or $dashboard.Handle -eq [IntPtr]::Zero){throw 'Expected exactly one visible top-level window'}
    for($index=0;$index -lt 3;$index++){
      $module=$modules[$index]
      $expected=$NodeConfig.nodes[$index].id
      $identity=& $module { $script:selectedNode.id }
      if($identity -ne $expected -or $cards.Controls[$index].Name -ne $expected -or -not $cards.Controls[$index].Visible){throw 'Node card identity/visibility mismatch'}
      $clipped=& $module {
        @($btnStart,$btnStop,$btnRefresh,$btnClear,$btnExport) | Where-Object {
          $_.Right -gt $bar.ClientSize.Width -or $_.Bottom -gt $bar.ClientSize.Height
        }
      }
      if($clipped){throw 'Node action buttons are clipped'}
    }
    $tokyoBusy=& $modules[0] { Get-NodeBusy }
    $laxBusy=& $modules[1] { Get-NodeBusy }
    $atlBusy=& $modules[2] { Get-NodeBusy }
    if($script:qaPhase -eq 0 -and $tokyoBusy -and -not $laxBusy -and -not $atlBusy){
      foreach($index in @(1,2)){
        $expected='fixture-'+$NodeConfig.nodes[$index].id
        $actual=& $modules[$index] {$lblId.Text}
        if($actual -ne $expected){throw 'Fast node result was lost or assigned to another card'}
      }
      & $modules[1] {
        if(-not $btnRefresh.Enabled){throw 'Other node refresh is blocked'}
        $btnRefresh.PerformClick()
        if(-not $script:busy){throw 'Refresh button did not start its own node'}
      }
      $script:qaPhase=1
    }
    elseif($script:qaPhase -eq 1 -and -not $laxBusy){
      if(-not $tokyoBusy){throw 'Slow refresh did not overlap the other node operation'}
      & $modules[2] {$btnRefresh.PerformClick()}
      $script:qaPhase=2
    }
    elseif($script:qaPhase -eq 2 -and -not $atlBusy){
      $failed=& $modules[2] {$banner.Text -like '*查询失败*' -and $log.Text -match '退出码 [1-9][0-9]*'}
      if(-not $failed){
        $details=& $modules[2] {$banner.Text+"`n"+$log.Text}
        throw ('Failed child did not produce its own failure status: '+$details)
      }
      $laxId=& $modules[1] {$lblId.Text}
      if($laxId -ne 'fixture-los-angeles'){throw 'One node failure overwrote another node'}
      $script:qaPhase=3
    }
    elseif($script:qaPhase -eq 3 -and -not $tokyoBusy){
      $tokyoId=& $modules[0] {$lblId.Text}
      if($tokyoId -ne 'fixture-tokyo'){throw 'Slow result went to the wrong card'}
      foreach($module in $modules){
        & $module {
          foreach($other in $NodeConfig.nodes){
            if($other.id -ne $script:selectedNode.id -and $log.Text.Contains('fixture-'+$other.id)){throw 'Logs leaked across cards'}
          }
        }
      }
      $dashboard.ClientSize=New-Object Drawing.Size(900,610)
      $dashboard.PerformLayout(); $scroll.PerformLayout(); $cards.PerformLayout()
      $script:qaPhase=4
    }
    elseif($script:qaPhase -eq 4){
      if(-not $scroll.HorizontalScroll.Visible -or $cards.Width -lt 1080){throw 'Narrow window cannot scroll to all node cards'}
      foreach($module in $modules){
        & $module {
          if($log.Height -lt 50){throw 'Narrow window lost the node log area'}
        }
      }
      [IO.File]::WriteAllText((Join-Path $Dir 'result.json'),' {"ok":true}')
      $qaTimer.Stop(); $dashboard.Close()
    }
  } catch {
    $result=@{ok=$false;error=$_.Exception.Message;trace=$_.ScriptStackTrace}|ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $Dir 'result.json'),$result)
    $qaTimer.Stop()
    foreach($module in $modules){& $module {$script:busy=$false}}
    $dashboard.Close()
  }
})
$qaTimer.Start()
try { [void]$dashboard.ShowDialog() } finally { $qaTimer.Dispose() }
'@
if(-not $gui.Contains('[void]$dashboard.ShowDialog()')){throw 'Dashboard test hook missing'}
$gui=$gui.Replace('[void]$dashboard.ShowDialog()',$probe)
# Construction failures must also reach the launcher test rather than a hidden console.
$gui=$gui.Replace('if (-not $Panel) { Show-NodeDashboard; return }',@'
if (-not $Panel) {
  try { Show-NodeDashboard } catch {
    [IO.File]::WriteAllText((Join-Path $Dir 'result.json'),(@{ok=$false;error=$_.Exception.Message;trace=$_.ScriptStackTrace}|ConvertTo-Json -Compress))
  }
  return
}
'@)
[IO.File]::WriteAllText($path,$gui,[Text.UTF8Encoding]::new($true))
# The real portable launcher opens a single dashboard. Only the core is mocked.
& wscript.exe (Join-Path $sandbox '节点管理.vbs')
$deadline=[DateTime]::UtcNow.AddSeconds(30)
$resultPath=Join-Path $sandbox 'result.json'
while(-not (Test-Path $resultPath) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 150}
if(-not (Test-Path $resultPath)){throw "Dashboard launcher produced no test result. Fixture: $sandbox"}
$result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
if(-not $result.ok){throw ($result.error+"`n"+$result.trace+"`nFixture: "+$sandbox)}
Write-Host 'PASS: one visible dashboard, three visible cards, concurrent refresh, isolated results/logs, and nonzero child failure (mock core only)'
