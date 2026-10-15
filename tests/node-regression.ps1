$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
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
$Current=$Config.nodes | Where-Object id -eq 'los-angeles'
$tokyo=[pscustomobject]@{id='tokyo-test';label='tokyo-reality';region='nrt';main_ip='192.0.2.1';status='active'}
$lax=[pscustomobject]@{id='lax-test';label='lax-reality';region='lax';main_ip='192.0.2.2';status='active'}
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
  if($Path -like '/regions/*/availability'){return @{available_plans=@('vc2-1c-1gb')}}
  if($Path -like '/startup-scripts/*'){return @{startup_script=@{id='startup-test'}}}
  if($Path -eq '/instances' -and $Method -eq 'Post'){return @{instance=@{id='lax-test'}}}
  if($Path -eq '/instances/lax-test' -and $Method -eq 'Get'){return @{instance=$lax}}
  if($Method -eq 'Delete'){return}
  throw "Unexpected mock API call: $Method $Path"
}
function Start-Sleep {param($Seconds)}
function Test-Port443 {param($Ip) return $true}
function Get-DnsIp {return '192.0.2.2'}
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
Write-Host '全部回归检查通过（API 完全模拟，未创建或删除真实实例）。'
