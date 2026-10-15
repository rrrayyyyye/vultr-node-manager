$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($file in @('vultr-node.ps1', 'vultr-node-gui.ps1')) {
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
  if ($errors.Count) { throw "Cannot parse $file" }
  foreach ($definition in $ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
  }
}
function Assert-Task([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message } }
$Config=Get-Content -LiteralPath (Join-Path $root 'nodes.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Current=$Config.nodes[0]; $script:selectedNode=$Current
$Base='https://api.example.invalid/v2'; $Headers=@{Authorization='Bearer fake-test-key'}
$script:requests=[Collections.Generic.List[object]]::new()
$script:lines=[Collections.Generic.List[string]]::new()
$script:mode='empty'; $script:apiCalls=0
$script:expectedTls=[Net.SecurityProtocolType]::Tls12
$fixture=[pscustomobject]@{id='tokyo-test';label=$Current.label;region='nrt';main_ip='192.0.2.1';status='active';power_status='running'}
function Write-Host {
  param([Parameter(Position=0,ValueFromRemainingArguments=$true)]$Object, $ForegroundColor)
  $script:lines.Add(($Object -join ' '))
}
function Test-Port443 { param($Ip) return $true }
# Every HTTP request is intercepted, including DoH. No live credentials or networking.
function Invoke-RestMethod {
  param($Uri, $Method, $Headers, $TimeoutSec, $ContentType, $Body, $ErrorAction)
  $proxy=[Net.WebRequest]::DefaultWebProxy
  Assert-Task ($null -eq $proxy -or $proxy.IsBypassed([uri]$Uri)) 'Management request still uses a proxy'
  Assert-Task ([Net.ServicePointManager]::SecurityProtocol -eq $script:expectedTls) 'Unexpected request TLS settings'
  $script:requests.Add([pscustomobject]@{Uri=$Uri;Method=$Method;Body=$Body})
  if ($Uri -like 'https://223.5.5.5/*') { return [pscustomobject]@{Answer=@(@{type=1;data='192.0.2.1'})} }
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
  $script:mode='empty'; $script:lines.Clear()
  Write-Status *> $null
  $absent=($script:lines | Where-Object { $_ -like '@@NODE_STATUS@@*' } | Select-Object -Last 1).Substring(15) | ConvertFrom-Json
  Assert-Task (-not $absent.exists -and $absent.status -eq 'absent') 'Remote deletion not reflected on refresh'
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
  Update-Card ('@@NODE_STATUS@@'+($present | ConvertTo-Json -Compress))
  Assert-Task ($banner.BackColor -eq $colOk) 'Running status display regressed'
  Update-Card ('@@NODE_STATUS@@'+($absent | ConvertTo-Json -Compress))
  Assert-Task ($banner.Text -like '*已销毁*' -and $banner.BackColor -eq $colOff) 'Confirmed absence not shown as destroyed'
  Update-Card 'Simulated failed child: no status marker'
  Assert-Task ($banner.Text -like '*未确认云端状态*' -and $banner.BackColor -eq $colWarn -and $lblIp.Text -eq '—') 'Failed refresh falsely shown as stopped or retains stale IP'
  Microsoft.PowerShell.Utility\Write-Host 'PASS: GUI distinguishes confirmed deletion from unknown status after query failure'
} finally {
  [Net.WebRequest]::DefaultWebProxy=$originalProxy
  [Net.ServicePointManager]::SecurityProtocol=$originalTls
}
