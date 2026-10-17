$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'node-time.ps1')
foreach ($file in @('vultr-node.ps1', 'vultr-node-gui.ps1')) {
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
  if ($errors.Count) { throw "Cannot parse $file" }
  foreach ($definition in $ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
  }
}
function Assert-Task([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message } }
$fixedNow=[DateTimeOffset]::Parse('2026-10-17T01:02:03Z')
$utcTiming=Get-InstanceTiming '2026-10-16T00:00:00Z' $fixedNow
$offsetTiming=Get-InstanceTiming '2026-10-16T08:00:00+08:00' $fixedNow
$implicitUtcTiming=Get-InstanceTiming '2026-10-16T00:00:00' $fixedNow
Assert-Task ($utcTiming.ageSeconds -eq 90123 -and $offsetTiming.createdAtUtc -eq $utcTiming.createdAtUtc -and $implicitUtcTiming.ageSeconds -eq 90123) 'Creation time timezone conversion failed'
Assert-Task ((Format-NodeAge $utcTiming.ageSeconds) -eq '1天 01小时 02分 03秒') 'Multi-day lifetime display failed'
Assert-Task ((Format-NodeAge 0) -eq '00小时 00分 00秒') 'New instance lifetime display failed'
foreach ($invalidDate in @('', 'invalid', '2027-01-01T00:00:00Z')) {
  $invalidTiming=Get-InstanceTiming $invalidDate $fixedNow
  Assert-Task ($null -eq $invalidTiming.createdAtUtc -and $null -eq $invalidTiming.ageSeconds) 'Invalid/future date produced a misleading lifetime'
}
Write-Host 'PASS: lifetime calculation handles UTC, timezone offsets, day boundaries and invalid timestamps'
$Config=Get-Content -LiteralPath (Join-Path $root 'nodes.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Current=$Config.nodes[0]; $script:selectedNode=$Current
$Base='https://api.example.invalid/v2'; $Headers=@{Authorization='Bearer fake-test-key'}
$script:requests=[Collections.Generic.List[object]]::new()
$script:lines=[Collections.Generic.List[string]]::new()
$script:mode='empty'; $script:apiCalls=0
$script:expectedTls=[Net.SecurityProtocolType]::Tls12
$script:accountFailure=$false
$script:transientFailures=0; $script:failMethod=''
$script:accountPayload=[pscustomobject]@{balance=-25;pending_charges=[decimal]'1.25';name='private-name-fixture';email='private@example.invalid'}
$fixture=[pscustomobject]@{id='tokyo-test';label=$Current.label;region='nrt';main_ip='192.0.2.1';status='active';power_status='running';date_created=([DateTimeOffset]::UtcNow.AddHours(-25)).ToString('o')}
function Write-Host {
  param([Parameter(Position=0,ValueFromRemainingArguments=$true)]$Object, $ForegroundColor)
  $script:lines.Add(($Object -join ' '))
}
function Test-Port443 { param($Ip) return $true }
# Every HTTP request is intercepted, including DoH. No live credentials or networking.
function Invoke-RestMethod {
  param($Uri, $Method, $Headers, $TimeoutSec, $ContentType, $Body, $ErrorAction, [switch]$DisableKeepAlive)
  Assert-Task $DisableKeepAlive 'Management request can reuse a stale connection'
  $proxy=[Net.WebRequest]::DefaultWebProxy
  Assert-Task ($null -eq $proxy -or $proxy.IsBypassed([uri]$Uri)) 'Management request still uses a proxy'
  Assert-Task ([Net.ServicePointManager]::SecurityProtocol -eq $script:expectedTls) 'Unexpected request TLS settings'
  $script:requests.Add([pscustomobject]@{Uri=$Uri;Method=$Method;Body=$Body})
  if ($script:transientFailures -gt 0 -and (-not $script:failMethod -or $Method -eq $script:failMethod)) {
    $script:transientFailures--
    throw [Net.WebException]::new('Simulated send failure', $null, [Net.WebExceptionStatus]::SendFailure, $null)
  }
  if ($Uri -like 'https://223.5.5.5/*') { return [pscustomobject]@{Answer=@(@{type=1;data='192.0.2.1'})} }
  if ($Uri -eq "$Base/account") {
    if ($script:accountFailure) { throw [Net.WebException]::new('Simulated account permission denied') }
    return [pscustomobject]@{account=$script:accountPayload}
  }
  $script:apiCalls++
  switch ($script:mode) {
    'error' { throw [Net.WebException]::new('Simulated disconnected upstream proxy') }
    'forbidden' { throw [Net.WebException]::new('Simulated HTTP 403: source IP denied') }
    'malformed' { return [pscustomobject]@{unexpected='not an instance list'} }
    'null-list' { return [pscustomobject]@{instances=$null;meta=@{links=@{next=''}}} }
    'no-pagination' { return [pscustomobject]@{instances=@();meta=@{}} }
    'second-page-error' {
      if ($script:apiCalls -eq 1) { return [pscustomobject]@{instances=@();meta=@{links=@{next='page-2'}}} }
      throw [Net.WebException]::new('Simulated second page failure')
    }
    'present' { return [pscustomobject]@{instances=@($fixture);meta=@{links=@{next=''}}} }
    default { return [pscustomobject]@{instances=@();meta=@{links=@{next=''}}} }
  }
}
$originalProxy=[Net.WebRequest]::DefaultWebProxy
$originalTls=[Net.ServicePointManager]::SecurityProtocol
try {
  # A dead inherited proxy and explicit legacy TLS must not affect management.
  $deadProxy=[Net.WebProxy]::new('http://127.0.0.1:1')
  [Net.WebRequest]::DefaultWebProxy=$deadProxy
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls
  foreach ($method in @('Get','Post','Delete')) {
    $script:mode='empty'; $script:requests.Clear()
    $body=if ($method -eq 'Post') { @{region='nrt';label='fixture'} } else { $null }
    $null=Invoke-Api '/instances' $method $body
    Assert-Task ($script:requests.Count -eq 1 -and $script:requests[0].Method -eq $method) 'Request duplicated or method changed'
    if ($body) { Assert-Task (($script:requests[0].Body | ConvertFrom-Json).region -eq 'nrt') 'Create body lost' }
    Assert-Task ([object]::ReferenceEquals([Net.WebRequest]::DefaultWebProxy,$deadProxy)) 'Proxy not restored'
    Assert-Task ([Net.ServicePointManager]::SecurityProtocol -eq [Net.SecurityProtocolType]::Tls) 'TLS not restored'
  }
  Microsoft.PowerShell.Utility\Write-Host 'PASS: management requests bypass inherited proxy, upgrade legacy TLS, preserve methods and restore settings'

  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::SystemDefault
  $script:expectedTls=[Net.SecurityProtocolType]::SystemDefault
  $null=Invoke-Api '/instances'
  Assert-Task ([Net.ServicePointManager]::SecurityProtocol -eq [Net.SecurityProtocolType]::SystemDefault) 'OS TLS defaults not preserved'
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls
  $script:expectedTls=[Net.SecurityProtocolType]::Tls12
  Microsoft.PowerShell.Utility\Write-Host 'PASS: modern OS TLS defaults remain unchanged'

  # Polling sees current cloud state even if deletion was done elsewhere.
  $MachineStatus=$true; $script:mode='present'; $script:lines.Clear()
  Write-Status *> $null
  $present=($script:lines | Where-Object { $_ -like '@@NODE_STATUS@@*' } | Select-Object -Last 1).Substring(15) | ConvertFrom-Json
  Assert-Task ($present.exists -and $present.dnsMatches -and $present.port443) 'Present node or direct DoH status lost'
  Assert-Task ($present.createdAtUtc -and $present.ageSeconds -ge 90000 -and $present.ageSeconds -lt 90120) 'Cloud creation timestamp not included in status'
  $script:mode='empty'; $script:lines.Clear()
  Write-Status *> $null
  $absent=($script:lines | Where-Object { $_ -like '@@NODE_STATUS@@*' } | Select-Object -Last 1).Substring(15) | ConvertFrom-Json
  Assert-Task (-not $absent.exists -and $absent.status -eq 'absent') 'Remote deletion not reflected on refresh'
  Assert-Task ($null -eq $absent.createdAtUtc -and $null -eq $absent.ageSeconds) 'Destroyed node retained lifetime metadata'
  Microsoft.PowerShell.Utility\Write-Host 'PASS: live cloud state transitions from present to absent without a local stop operation'

  foreach ($mode in @('error','forbidden','malformed','null-list','no-pagination','second-page-error')) {
    $script:mode=$mode; $script:lines.Clear(); $script:apiCalls=0; $failed=$false
    try { Write-Status *> $null } catch { $failed=$true }
    Assert-Task $failed "Failed or incomplete API request treated as success: $mode"
    Assert-Task (@($script:lines | Where-Object { $_ -like '@@NODE_STATUS@@*' }).Count -eq 0) "False stopped marker: $mode"
    Assert-Task ([object]::ReferenceEquals([Net.WebRequest]::DefaultWebProxy,$deadProxy)) 'Proxy not restored on error'
    Assert-Task ([Net.ServicePointManager]::SecurityProtocol -eq [Net.SecurityProtocolType]::Tls) 'TLS not restored on error'
  }
  Microsoft.PowerShell.Utility\Write-Host 'PASS: network, authorization, incomplete payload and later-page failures never report absent'

  # Render status using label doubles; loading Windows Forms is unnecessary.
  $colWarn='warning'; $colOff='off'; $colOk='ok'
  $banner=[pscustomobject]@{Text='';BackColor=''}
  $lblId=[pscustomobject]@{Text='';ForeColor=''}
  $lblIp=[pscustomobject]@{Text='';ForeColor=''}
  $lblDns=[pscustomobject]@{Text='';ForeColor=''}
  $lblPort=[pscustomobject]@{Text='';ForeColor=''}
  $lblCreated=[pscustomobject]@{Text='';ForeColor=''}
  $lblAge=[pscustomobject]@{Text='';ForeColor=''}
  Update-Card ('@@NODE_STATUS@@'+($present | ConvertTo-Json -Compress))
  Assert-Task ($banner.BackColor -eq $colOk) 'Running status display regressed'
  Assert-Task ($lblAge.Text -like '1天 01小时*' -and $lblCreated.Text -ne '—') 'Instance lifetime not displayed'
  $expectedLocalTime=([DateTimeOffset]::Parse($present.createdAtUtc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
  Assert-Task ($lblCreated.Text -eq $expectedLocalTime) 'Creation time not displayed in the local timezone'
  $script:createdAtUtc=([DateTimeOffset]::UtcNow.AddHours(-26)).ToString('o')
  Update-NodeAge
  Assert-Task ($lblAge.Text -like '1天 02小时*') 'Local clock does not recalculate lifetime'
  Update-Card ('@@NODE_STATUS@@'+($absent | ConvertTo-Json -Compress))
  Assert-Task ($banner.Text -like '*已销毁*' -and $banner.BackColor -eq $colOff) 'Confirmed absence not shown as destroyed'
  Update-NodeAge
  Assert-Task ($lblCreated.Text -eq '—' -and $lblAge.Text -eq '—') 'Destroyed node kept ticking'
  $script:createdAtUtc=$present.createdAtUtc; Update-NodeAge
  Update-Card 'Simulated failed child: no status marker'
  Assert-Task ($banner.Text -like '*未确认云端状态*' -and $banner.BackColor -eq $colWarn -and $lblIp.Text -eq '—') 'Failed refresh falsely shown as stopped or retains stale IP'
  Update-NodeAge
  Assert-Task ($lblCreated.Text -eq '—' -and $lblAge.Text -eq '—') 'Failed query retained stale lifetime'
  $present.createdAtUtc=$null
  Update-Card ('@@NODE_STATUS@@'+($present | ConvertTo-Json -Compress))
  Assert-Task ($banner.BackColor -eq $colOk -and $lblAge.Text -eq '—') 'Missing creation time broke otherwise valid node status'
  Microsoft.PowerShell.Utility\Write-Host 'PASS: lifetime ticks locally and clears on deletion, failed refresh or missing creation timestamp'
  Microsoft.PowerShell.Utility\Write-Host 'PASS: GUI distinguishes confirmed deletion from unknown status after query failure'

  # Ledger credit is negative; pending usage is not yet deducted. Never use abs().
  foreach ($case in @(@(-25,1.25,23.75),@(0,0,0),@(2,0.5,-2.5),@(-1,1.5,-0.5))) {
    $script:accountPayload.balance=$case[0]; $script:accountPayload.pending_charges=$case[1]
    $balance=Get-AccountBalance
    Assert-Task ($balance.estimatedRemainingUSD -eq [decimal]$case[2]) 'Prepaid credit, pending charges or debt sign is wrong'
  }
  foreach ($badAccount in @([pscustomobject]@{},[pscustomobject]@{balance=$null;pending_charges=0},[pscustomobject]@{balance='invalid';pending_charges=0},[pscustomobject]@{balance=-10;pending_charges=-1})) {
    $script:accountPayload=$badAccount; $rejected=$false
    try { $null=Get-AccountBalance } catch { $rejected=$true }
    Assert-Task $rejected 'Incomplete or invalid account balance treated as zero'
  }
  Microsoft.PowerShell.Utility\Write-Host 'PASS: estimated credit subtracts pending charges, preserves debt and rejects incomplete amounts'

  $script:accountPayload=[pscustomobject]@{balance=-25;pending_charges=[decimal]'1.25';name='private-name-fixture';email='private@example.invalid'}
  $script:lines.Clear(); Write-AccountStatus
  $accountMarker=$script:lines | Where-Object {$_ -like '@@ACCOUNT_STATUS@@*'} | Select-Object -Last 1
  Assert-Task ($accountMarker -and $accountMarker -notmatch 'private-name-fixture|private@example.invalid') 'Account output leaks personal fields'
  $lblBalance=[pscustomobject]@{Text='';ForeColor=''}
  $lblBalanceDetail=[pscustomobject]@{Text=''}
  $lblBalanceUpdated=[pscustomobject]@{Text=''}
  Update-AccountCard $accountMarker
  Assert-Task ($lblBalance.Text -eq 'US$ 23.75' -and $lblBalanceDetail.Text -like '*25.00*1.25*' -and $lblBalanceUpdated.Text -like '*更新于*') 'Account card does not show remaining credit, pending usage and update time'
  $script:mode='present'; $script:accountFailure=$true; $script:lines.Clear()
  Write-RefreshStatus *> $null
  Assert-Task (@($script:lines | Where-Object {$_ -like '@@NODE_STATUS@@*'}).Count -eq 1) 'Account failure hid successful node status'
  Update-AccountCard ($script:lines -join "`n")
  Assert-Task ($lblBalance.Text -eq '—' -and $lblBalanceDetail.Text -like '*查询失败*') 'Account failure shows stale balance or zero'
  $script:accountFailure=$false; $script:mode='error'; $script:lines.Clear(); $failed=$false
  try { Write-RefreshStatus *> $null } catch {$failed=$true}
  Assert-Task ($failed -and @($script:lines | Where-Object {$_ -like '@@ACCOUNT_STATUS@@*'}).Count -eq 1) 'Node query failure blocked independent account refresh'
  Microsoft.PowerShell.Utility\Write-Host 'PASS: account card refreshes independently, clears stale balances and excludes personal account fields'

  # Retry only safe reads. A write may have reached the server before disconnect.
  $script:mode='empty'; $script:failMethod='Get'; $script:transientFailures=1; $script:requests.Clear()
  $null=Invoke-Api '/instances?per_page=100'
  Assert-Task ($script:requests.Count -eq 2) 'Transient read failure was not retried once'
  foreach ($method in @('Post','Delete')) {
    $script:failMethod=$method; $script:transientFailures=1; $script:requests.Clear(); $failed=$false
    try {$null=Invoke-Api '/instances/fixture' $method} catch {$failed=$true}
    Assert-Task ($failed -and $script:requests.Count -eq 1) 'An uncertain write was automatically repeated'
  }
  $script:transientFailures=0; $script:failMethod=''
  Microsoft.PowerShell.Utility\Write-Host 'PASS: transient GET failure retries once; POST and DELETE never retry automatically'

  # Confirmation reads must not wait for stale proxy-port, DNS or account checks.
  $ConfirmDeletion=$true; $script:mode='present'; $script:requests.Clear(); $script:lines.Clear()
  Write-RefreshStatus *> $null
  Assert-Task ($script:requests.Count -eq 1 -and $script:requests[0].Uri -like '*/instances?*') 'Deletion confirmation waited for unrelated checks'
  Assert-Task (@($script:lines | Where-Object {$_ -like '@@ACCOUNT_STATUS@@*'}).Count -eq 0) 'Fast confirmation queried the account'
  $ConfirmDeletion=$false

  $script:lines.Clear(); Stop-Node *> $null
  $receiptMarker=$script:lines | Where-Object {$_ -like '@@NODE_STOP@@*'} | Select-Object -Last 1
  Assert-Task ($receiptMarker -and $receiptMarker -like '*submitted*') 'Accepted DELETE did not produce a receipt'
  $script:pendingDeletes=@{}; $colBusy='busy'
  Update-StopReceipt $receiptMarker
  Assert-Task ((Get-PendingDeletion).id -eq $fixture.id -and $banner.Text -like '*已受理*') 'GUI did not retain the accepted delete request'
  Update-Card 'Connection interrupted after accepted delete'
  Assert-Task ($banner.Text -like '*已受理*' -and $banner.Text -notlike '*查询失败*' -and $banner.Text -notlike '*已销毁*') 'Transient confirmation failure erased progress or falsely confirmed deletion'
  Update-Card ('@@NODE_STATUS@@'+($present | ConvertTo-Json -Compress))
  Assert-Task ($banner.Text -like '*正在销毁*' -and $lblAge.Text -eq '—') 'Provider still listing the old instance was shown as running'
  foreach ($controlName in @('btnStart','btnStop','btnRefresh','btnClear','btnExport','nodeSelector','progress')) {
    Set-Variable -Name $controlName -Value ([pscustomobject]@{Enabled=$false;Visible=$false}) -Scope Script
  }
  Set-Busy $false
  Assert-Task (-not $btnStart.Enabled -and -not $btnStop.Enabled -and $btnRefresh.Enabled) 'Pending deletion allowed conflicting create/delete actions'

  # A streamed node result must update now, before the account child finishes.
  $script:buf=New-Object Text.StringBuilder; $script:cur='status'
  $log=[pscustomobject]@{TextLength=0;SelectionStart=0;Messages=[Collections.Generic.List[string]]::new()}
  $log | Add-Member -MemberType ScriptMethod -Name AppendText -Value {param($text) $this.Messages.Add($text)}
  $log | Add-Member -MemberType ScriptMethod -Name ScrollToCaret -Value {}
  Append-Log ('@@NODE_STATUS@@'+($absent | ConvertTo-Json -Compress)+"`n")
  Assert-Task ($null -eq (Get-PendingDeletion) -and $banner.Text -like '*已销毁*') 'Streamed deletion result waited for the account request'
  Update-Card ('@@NODE_STATUS@@'+($absent | ConvertTo-Json -Compress))
  Assert-Task ($banner.Text -eq ($Current.name+' · 已销毁')) 'Completion replay erased a confirmed deletion status'
  Assert-Task (($log.Messages -join '') -notmatch '@@NODE_STATUS@@') 'Machine status markers leaked into visible logs'
  Set-Busy $false
  Assert-Task ($btnStart.Enabled -and $btnStop.Enabled) 'Confirmed deletion kept node actions disabled'

  Update-StopReceipt $receiptMarker
  $newInstance=$present | ConvertTo-Json -Compress | ConvertFrom-Json
  $newInstance.id='recreated-by-another-machine'
  Update-Card ('@@NODE_STATUS@@'+($newInstance | ConvertTo-Json -Compress))
  Assert-Task ($null -eq (Get-PendingDeletion) -and $lblId.Text -eq $newInstance.id) 'Pending deletion incorrectly hid a newly recreated instance'
  Update-StopReceipt $receiptMarker
  $script:selectedNode=$Config.nodes[1]
  Assert-Task ($null -eq (Get-PendingDeletion) -and $script:pendingDeletes.ContainsKey($Current.id)) 'Pending deletion leaked across regions'
  $script:selectedNode=$Current
  $script:pendingDeletes=@{}; $script:lines.Clear(); $script:mode='present'; $script:failMethod='Delete'; $script:transientFailures=1
  $failed=$false
  try {Stop-Node *> $null} catch {$failed=$true}
  Assert-Task ($failed -and @($script:lines | Where-Object {$_ -like '@@NODE_STOP@@*'}).Count -eq 0) 'Failed DELETE fabricated an accepted receipt'
  $script:transientFailures=0; $script:failMethod=''
  Microsoft.PowerShell.Utility\Write-Host 'PASS: accepted deletion survives outages, confirms from streaming results, isolates regions and respects recreation'

  $OutputPath=Join-Path ([IO.Path]::GetTempPath()) ('vultr-routes-fixture-'+[guid]::NewGuid().ToString('N')+'.yaml')
  try {
    Write-ClientYaml
    $exported=[IO.File]::ReadAllText($OutputPath)
    Assert-Task ($exported.Contains('DOMAIN,api.vultr.com,DIRECT') -and $exported.IndexOf('DOMAIN,api.vultr.com,DIRECT') -lt $exported.IndexOf('MATCH,PROXY') -and $exported.Contains('IP-CIDR,223.5.5.5/32,DIRECT,no-resolve')) 'Exported profile can send management requests through the managed node'
  } finally {Remove-Item -LiteralPath $OutputPath -ErrorAction SilentlyContinue}
  Microsoft.PowerShell.Utility\Write-Host 'PASS: exported profiles route management API and DNS directly before proxy fallback'
} finally {
  [Net.WebRequest]::DefaultWebProxy=$originalProxy
  [Net.ServicePointManager]::SecurityProtocol=$originalTls
}
