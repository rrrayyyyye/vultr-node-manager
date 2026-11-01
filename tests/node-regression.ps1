$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'node-time.ps1')
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'vultr-node.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw '核心脚本解析失败'}
foreach($definition in $ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
  . ([scriptblock]::Create($definition.Extent.Text))
}
$Config=Get-Content -LiteralPath (Join-Path $root 'nodes.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach($entry in $Config.nodes) {
  $entry.startupScriptId='11111111-1111-4111-8111-111111111111'
  $entry.uuid='22222222-2222-4222-8222-222222222222'
  $entry.publicKey='A'*43; $entry.shortId='0123456789abcdef'
  $entry.domain=$entry.id+'.example.invalid'
}
function Invoke-RestMethod { throw 'Tests must never call a real network API.' }
$realGetDnsIp = ${function:Get-DnsIp}
$Current=$Config.nodes | Where-Object id -eq 'los-angeles'
$tokyo=[pscustomobject]@{id='tokyo-test';label='tokyo-reality';region='nrt';main_ip='192.0.2.1';status='active'}
$lax=[pscustomobject]@{id='lax-test';label='lax-reality';region='lax';main_ip='192.0.2.2';status='active'}
$script:createdInstance=$lax
$script:dnsReply='192.0.2.2'
$script:calls=[Collections.Generic.List[object]]::new()
$script:instances=@($tokyo)
$script:paging=$false
function Invoke-Api {
  param([string]$Path,[string]$Method='Get',$Body=$null)
  $script:calls.Add([pscustomobject]@{Path=$Path;Method=$Method;Body=$Body})
  if($Path.StartsWith('/instances?')) {
    if($script:paging -and $Path -notlike '*cursor=*') {return [pscustomobject]@{instances=@($tokyo);meta=@{links=@{next='next-page'}}}}
    if($script:paging){return [pscustomobject]@{instances=@($lax);meta=@{links=@{next=''}}}}
    return [pscustomobject]@{instances=$script:instances;meta=@{links=@{next=''}}}
  }
  if($Path -like '/regions/*/availability'){return @{available_plans=@('vc2-1c-1gb','vc2-1c-0.5gb-v6')}}
  if($Path -like '/startup-scripts/*'){return @{startup_script=@{id='startup-test'}}}
  if($Path -eq '/instances' -and $Method -eq 'Post'){return @{instance=@{id=$script:createdInstance.id}}}
  if($Path -eq ('/instances/'+$script:createdInstance.id) -and $Method -eq 'Get'){return @{instance=$script:createdInstance}}
  if($Method -eq 'Delete'){return}
  throw "Unexpected mock API call: $Method $Path"
}
function Start-Sleep {param($Seconds)}
function Test-Port443 {param($Ip) return $true}
function Get-DnsIp {return $script:dnsReply}
function ipconfig {param($option)}
function Assert-Task([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message}}

# 东京存在时，仍可创建洛杉矶；请求只使用洛杉矶配置。
Start-Node *> $null
$posts=@($script:calls | Where-Object Method -eq 'Post')
Assert-Task ($posts.Count -eq 1 -and $posts[0].Body.region -eq 'lax' -and $posts[0].Body.label -eq 'lax-reality') '跨地区创建失败'
Write-Host 'PASS: 东京存在时可创建洛杉矶，且只发送一次正确的创建请求'

# 两地同时存在时，删除请求必须只指向所选地区。
$script:instances=@($tokyo,$lax); $script:calls.Clear()
Stop-Node *> $null
$deletes=@($script:calls | Where-Object Method -eq 'Delete')
Assert-Task ($deletes.Count -eq 1 -and $deletes[0].Path -eq '/instances/lax-test') '删除地区隔离失败'
Write-Host 'PASS: 关闭洛杉矶不会删除东京'

$script:calls.Clear(); Start-Node *> $null
Assert-Task (@($script:calls | Where-Object Method -eq 'Post').Count -eq 0) '重复创建保护失败'
Write-Host 'PASS: 已有节点不会重复创建'

foreach($badSet in @(@($lax,$lax),@([pscustomobject]@{id='wrong-region';label='lax-reality';region='nrt'}))) {
  $script:instances=$badSet; $script:calls.Clear(); $rejected=$false
  try {Stop-Node *> $null} catch {$rejected=$true}
  Assert-Task ($rejected -and @($script:calls | Where-Object Method -eq 'Delete').Count -eq 0) '异常标签保护失败'
}
Write-Host 'PASS: 重复标签、标签地区不符均拒绝删除'

$script:paging=$true; $script:calls.Clear()
$found=@(Get-Node)
Assert-Task ($found.Count -eq 1 -and $found[0].id -eq 'lax-test') '分页查询失败'
Write-Host 'PASS: 正确查询后续分页中的节点'

# IPv6-only instance has no main_ip. Existing IPv4 nodes remain isolated.
$Current=$Config.nodes | Where-Object id -eq 'atlanta-v6'
$atl=[pscustomobject]@{id='atl-v6-test';label='atl-v6-reality';region='atl';main_ip='0.0.0.0';v6_main_ip='2001:0db8:0000:0000:0000:0000:0000:0001';status='active';power_status='running'}
$script:createdInstance=$atl; $script:dnsReply='2001:db8::1'
$script:paging=$false; $script:instances=@($tokyo,$lax); $script:calls.Clear()
Start-Node *> $null
$posts=@($script:calls | Where-Object Method -eq 'Post')
Assert-Task ($posts.Count -eq 1 -and $posts[0].Body.region -eq 'atl' -and $posts[0].Body.plan -eq 'vc2-1c-0.5gb-v6' -and $posts[0].Body.enable_ipv6) 'IPv6 create parameters wrong'
Assert-Task ($posts[0].Body.os_id -eq 2136) '512MB node must use the Debian 12 image, not the Ubuntu 24.04 image requiring 1000MB'
Assert-Task ((Get-NodeIp $atl) -eq '2001:db8::1' -and (Test-SameIp $atl.v6_main_ip $script:dnsReply)) 'IPv6 normalization or equality failed'
$script:instances=@($tokyo,$lax,$atl); $script:calls.Clear()
Stop-Node *> $null
$deletes=@($script:calls | Where-Object Method -eq 'Delete')
Assert-Task ($deletes.Count -eq 1 -and $deletes[0].Path -eq '/instances/atl-v6-test') 'IPv6 stop touched another region'
$MachineStatus=$true
$statusLines=@(Write-Status 6>&1 | ForEach-Object ToString)
$marker=$statusLines | Where-Object {$_ -like '@@NODE_STATUS@@*'} | Select-Object -Last 1
$status=$marker.Substring(15) | ConvertFrom-Json
Assert-Task ($status.exists -and $status.ip -eq '2001:db8::1' -and $status.dnsMatches) 'IPv6 status rejected an equivalent AAAA address'
$script:instances=@($tokyo,$lax); $script:calls.Clear()
$atl.v6_main_ip=''; $failed=$false
try {Start-Node *> $null} catch {$failed=$true}
Assert-Task ($failed -and @($script:calls | Where-Object Method -eq 'Delete').Count -eq 0) 'Missing IPv6 was treated as ready or auto-deleted'
Write-Host 'PASS: IPv6 creation, normalized status, region-safe deletion and missing-address failure'

# Real DoH function, intercepted before any network. A record must not satisfy AAAA.
Set-Item Function:Get-DnsIp $realGetDnsIp
function Invoke-ManagementRequest {
  param($Request)
  Assert-Task ($Request.Uri -like '*type=AAAA') 'IPv6 node requested A instead of AAAA'
  return @{Answer=@(@{type=1;data='192.0.2.99'},@{type=28;data='2001:db8::1'})}
}
Assert-Task ((Get-DnsIp) -eq '2001:db8::1') 'DoH did not select AAAA'
$Current=$Config.nodes[0]
Assert-Task (-not (Test-IPv6Node) -and (Get-NodeIp $tokyo) -eq '192.0.2.1') 'Legacy IPv4 settings no longer work'

$OutputPath=Join-Path ([IO.Path]::GetTempPath()) ('vultr-ipv6-fixture-'+[guid]::NewGuid().ToString('N')+'.yaml')
try {
  Write-ClientYaml *> $null
  $yaml=[IO.File]::ReadAllText($OutputPath); $bytes=[IO.File]::ReadAllBytes($OutputPath)
  Assert-Task ($yaml.Contains('ipv6: true') -and $yaml.Contains('  ipv6: true') -and $yaml.Contains('    ip-version: ipv6') -and $yaml.Contains('Atlanta-IPv6-REALITY')) 'IPv6 export cannot resolve or select the new node'
  Assert-Task (@([regex]::Matches($yaml,'ip-version: ipv4')).Count -eq 2) 'Existing nodes lost IPv4 preference'
  Assert-Task (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'YAML must not contain a BOM'
  $Config.nodes=@($Config.nodes | Where-Object id -ne 'atlanta-v6')
  Write-ClientYaml *> $null
  Assert-Task ([IO.File]::ReadAllText($OutputPath).Contains('ipv6: false')) 'IPv4-only configuration changed globally'
} finally {Remove-Item -LiteralPath $OutputPath -ErrorAction SilentlyContinue}
Write-Host 'PASS: AAAA lookup, mixed IPv4/IPv6 export and backward compatibility (no network)'
Write-Host '全部回归检查通过（API 完全模拟，未创建或删除真实实例）。'
