<# Vultr 多地区节点。省略 -Node 时操作东京，兼容原来的 bat。 #>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('start', 'stop', 'status', 'export')][string]$Action,
  [string]$Node = 'tokyo', [switch]$MachineStatus, [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Dir 'node-time.ps1')
$Base = 'https://api.vultr.com/v2'
$Config = Get-Content -LiteralPath (Join-Path $Dir 'nodes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Selected = @($Config.nodes | Where-Object { $_.id -eq $Node })
if ($Selected.Count -ne 1) { throw "节点配置不存在或重复：$Node" }
$Current = $Selected[0]

function Invoke-ManagementRequest {
  param([hashtable]$Request)
  # Windows PowerShell 5.1 inherits the user's HTTP proxy. Management must
  # remain reachable after that proxy's selected node has been destroyed.
  # Scope these .NET settings to this synchronous request, never the OS.
  $previousProxy = [Net.WebRequest]::DefaultWebProxy
  $previousTls = [Net.ServicePointManager]::SecurityProtocol
  try {
    [Net.WebRequest]::DefaultWebProxy = [Net.WebProxy]::new()
    # Keep OS defaults on modern .NET; replace explicit legacy TLS settings.
    if ($previousTls -ne 0) {
      # TLS 1.2 / 1.3 mask; numeric TLS 1.3 supports older .NET enum definitions.
      $modernTls = [int]$previousTls -band (3072 -bor 12288)
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]($modernTls -bor 3072)
    }
    Invoke-RestMethod @Request -ErrorAction Stop
  } finally {
    [Net.WebRequest]::DefaultWebProxy = $previousProxy
    [Net.ServicePointManager]::SecurityProtocol = $previousTls
  }
}

function Invoke-Api {
  param([string]$Path, [string]$Method = 'Get', $Body = $null, [int]$TimeoutSec = 60)
  $apiArgs = @{ Uri = "$Base$Path"; Method = $Method; Headers = $Headers; TimeoutSec = $TimeoutSec }
  if ($null -ne $Body) { $apiArgs.ContentType = 'application/json'; $apiArgs.Body = ($Body | ConvertTo-Json -Depth 8) }
  try { Invoke-ManagementRequest $apiArgs }
  catch { throw "Vultr API 直连请求失败：$($_.Exception.Message) 请检查本机直连网络、TLS 和 API 来源 IP 限制；未确认云端操作结果。" }
}

function Get-AllInstances {
  $path = '/instances?per_page=100'; $seen = @{}
  do {
    $page = Invoke-Api $path
    $links = $page.meta.links
    $hasNext = if ($links -is [Collections.IDictionary]) { $links.Contains('next') }
               else { $null -ne $links -and $links.PSObject.Properties.Name -contains 'next' }
    if ($null -eq $page -or $page.instances -isnot [array] -or -not $hasNext) {
      throw 'Vultr 实例列表响应不完整，无法确认节点是否存在。'
    }
    @($page.instances) | Where-Object { $null -ne $_ }
    $next = $page.meta.links.next
    if ($next) {
      if ($seen.ContainsKey([string]$next)) { throw '实例列表分页游标重复，停止操作。' }
      $seen[[string]$next] = $true
      $path = '/instances?per_page=100&cursor=' + [uri]::EscapeDataString([string]$next)
    }
  } while ($next)
}

function Get-Node {
  $sameLabel = @(Get-AllInstances | Where-Object { $_.label -eq $Current.label })
  if (@($sameLabel | Where-Object { $_.region -ne $Current.region }).Count -gt 0) {
    throw "标签 $($Current.label) 出现在其他地区，请核对配置；本次未修改实例。"
  }
  if ($sameLabel.Count -gt 1) { throw '所选节点有多个同名实例，请在控制台核对；本次未修改实例。' }
  $sameLabel
}

function New-Link($Entry = $Current) {
  'vless://{0}@{1}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni={2}&fp=chrome&pbk={3}&sid={4}&type=tcp&headerType=none#{5}' -f `
    $Entry.uuid, $Entry.domain, $Entry.sni, $Entry.publicKey, $Entry.shortId, ([uri]::EscapeDataString($Entry.linkName))
}

function Write-ClientYaml {
  if (-not $OutputPath) { $script:OutputPath = Join-Path $Dir '客户端配置\vultr-multi-region.yaml' }
  $lines = [Collections.Generic.List[string]]::new()
  @('# Vultr 多地区节点；含连接凭据，请勿公开分享。',
    'mixed-port: 7890', 'allow-lan: false', 'mode: rule', 'log-level: info', 'ipv6: false',
    'dns:', '  enable: true', '  enhanced-mode: fake-ip', '  fake-ip-range: 198.18.0.1/16',
    '  nameserver:', '    - https://223.5.5.5/dns-query', '    - https://1.1.1.1/dns-query',
    '  proxy-server-nameserver:', '    - https://223.5.5.5/dns-query', '    - https://1.1.1.1/dns-query',
    'proxies:') | ForEach-Object { $lines.Add($_) }
  foreach ($entry in $Config.nodes) {
    $name = ConvertTo-Json -InputObject ([string]$entry.linkName) -Compress
    $domain = ConvertTo-Json -InputObject ([string]$entry.domain) -Compress
    @("  - name: $name", '    type: vless', "    server: $domain", '    port: 443',
      "    uuid: $($entry.uuid)", '    network: tcp', '    udp: true', '    tls: true',
      '    flow: xtls-rprx-vision', "    servername: $($entry.sni)", '    client-fingerprint: chrome',
      '    reality-opts:', "      public-key: $($entry.publicKey)", ('      short-id: "{0}"' -f $entry.shortId)) |
      ForEach-Object { $lines.Add($_) }
  }
  @('proxy-groups:', '  - name: PROXY', '    type: select', '    proxies:') | ForEach-Object { $lines.Add($_) }
  foreach ($entry in $Config.nodes) { $lines.Add('      - ' + (ConvertTo-Json -InputObject ([string]$entry.linkName) -Compress)) }
  @('rules:', '  - GEOIP,CN,DIRECT', '  - MATCH,PROXY') | ForEach-Object { $lines.Add($_) }
  $parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
  [void][IO.Directory]::CreateDirectory($parent)
  [IO.File]::WriteAllText($OutputPath, ($lines -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
  Write-Host "已导出全部节点配置：$OutputPath"
  Write-Host '在 FlClash 导入后，在 PROXY 中选择 Tokyo-REALITY 或 LosAngeles-REALITY。'
}

function Test-Port443([string]$Ip) {
  if (-not $Ip -or $Ip -eq '0.0.0.0') { return $false }
  $client = [Net.Sockets.TcpClient]::new()
  try { return ($client.ConnectAsync($Ip, 443).Wait(5000) -and $client.Connected) }
  catch { return $false }
  finally { $client.Dispose() }
}

function Get-DnsIp {
  try {
    $name = [uri]::EscapeDataString($Current.domain)
    $dns = Invoke-ManagementRequest @{ Uri="https://223.5.5.5/resolve?name=$name&type=A"; Headers=@{Accept='application/dns-json'}; TimeoutSec=10 }
    $answers = @($dns.Answer | Where-Object { $_.type -eq 1 })
    if ($answers.Count -gt 0) { return [string]$answers[0].data }
  } catch { }
  return $null
}

function Write-Status {
  $instances = @(Get-Node)
  $result = [ordered]@{ node=$Current.id; name=$Current.name; region=$Current.region; domain=$Current.domain;
    exists=$false; id=$null; ip=$null; status='absent'; powerStatus=$null; port443=$false; dnsIp=$null; dnsMatches=$false;
    createdAtUtc=$null; ageSeconds=$null }
  if ($instances.Count -eq 0) {
    Write-Host "$($Current.name)：当前没有此节点实例。" -ForegroundColor Yellow
  } else {
    $instance = $instances[0]
    $result.exists = $true; $result.id = $instance.id; $result.ip = $instance.main_ip
    $result.status = $instance.status; $result.powerStatus = $instance.power_status
    $result.port443 = Test-Port443 $instance.main_ip
    $result.dnsIp = Get-DnsIp
    $result.dnsMatches = [bool]($result.dnsIp -and $result.dnsIp -eq $instance.main_ip)
    $timing = Get-InstanceTiming ([string]$instance.date_created)
    $result.createdAtUtc = $timing.createdAtUtc; $result.ageSeconds = $timing.ageSeconds
    Write-Host "$($Current.name)：找到节点实例。" -ForegroundColor Cyan
    $instance | Select-Object id, label, region, plan, status, power_status, main_ip, date_created | Format-List | Out-Host
    if ($null -ne $result.ageSeconds) {
      Write-Host ('创建时间（本地）: ' + ([DateTimeOffset]::Parse($result.createdAtUtc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))
      Write-Host ('已开时长（自创建起）: ' + (Format-NodeAge $result.ageSeconds))
    } else { Write-Host '创建时间 / 已开时长: 无有效创建时间' }
    Write-Host "443 端口可达: $($result.port443)"
    Write-Host "域名 $($Current.domain) -> $($result.dnsIp)；与实例一致: $($result.dnsMatches)"
    Write-Host '以上是基础连通检查，不代表完整代理链路已经验证。'
  }
  if ($MachineStatus) { Write-Host ('@@NODE_STATUS@@' + ($result | ConvertTo-Json -Compress)) }
}

function Get-AccountBalance {
  $account = (Invoke-Api '/account' -TimeoutSec 15).account
  $amounts = @{}
  foreach ($field in @('balance', 'pending_charges')) {
    $number = [decimal]0
    $text = [Convert]::ToString($account.$field, [Globalization.CultureInfo]::InvariantCulture)
    if ([string]::IsNullOrWhiteSpace($text) -or -not [decimal]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
      throw '账户余额响应缺少有效金额。'
    }
    $amounts[$field] = $number
  }
  if ($amounts.pending_charges -lt 0) { throw '账户待结算费用异常。' }
  # Vultr's signed ledger: a negative balance is prepaid credit.
  # Pending charges have not yet been settled against that credit.
  [pscustomobject]@{ creditUSD=(-$amounts.balance); pendingChargesUSD=$amounts.pending_charges;
    estimatedRemainingUSD=(-$amounts.balance - $amounts.pending_charges) }
}

function Write-AccountStatus {
  $result = [ordered]@{ available=$false; creditUSD=$null; pendingChargesUSD=$null;
    estimatedRemainingUSD=$null; checkedAtUtc=[DateTimeOffset]::UtcNow.ToString('o') }
  try {
    $account = Get-AccountBalance
    $result.available=$true; $result.creditUSD=$account.creditUSD
    $result.pendingChargesUSD=$account.pendingChargesUSD; $result.estimatedRemainingUSD=$account.estimatedRemainingUSD
    Write-Host ('账户预计剩余（USD）: ' + $account.estimatedRemainingUSD.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture))
    Write-Host ('账户预存: ' + $account.creditUSD.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + '；待结算: ' + $account.pendingChargesUSD.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture))
  } catch { Write-Host ('账户余额查询失败：' + $_.Exception.Message) -ForegroundColor Yellow }
  if ($MachineStatus) { Write-Host ('@@ACCOUNT_STATUS@@' + ($result | ConvertTo-Json -Compress)) }
}

function Write-RefreshStatus {
  # Account permission/network failure must not hide a confirmed node state,
  # and a failed node query must still allow an independent account result.
  try { Write-Status } finally { Write-AccountStatus }
}

function Start-Node {
  $existing = @(Get-Node)
  if ($existing.Count -gt 0) {
    Write-Host "$($Current.name)实例已存在，不重复创建。IP: $($existing[0].main_ip)" -ForegroundColor Yellow
    Write-Host ('客户端链接：' + (New-Link)); return
  }
  if (-not $Current.startupScriptId) { throw '此地区尚未完成开机脚本配置，未创建服务器。' }
  $availability = Invoke-Api "/regions/$($Current.region)/availability"
  if ($Current.plan -notin @($availability.available_plans)) { throw '所选地区当前无此套餐库存，未创建服务器。' }
  $null = Invoke-Api "/startup-scripts/$($Current.startupScriptId)"
  Write-Host "正在创建 $($Current.name) 实例（$($Current.plan)）..." -ForegroundColor Cyan
  $created = Invoke-Api '/instances' 'Post' @{
    region=$Current.region; plan=$Current.plan; os_id=[int]$Current.osId;
    label=$Current.label; hostname=$Current.label; script_id=$Current.startupScriptId;
    backups='disabled'; enable_ipv6=$false
  }
  $instanceId = $created.instance.id
  if (-not $instanceId) { throw '创建响应未返回实例 ID，请在控制台核对后再操作。' }
  Write-Host "已提交，实例 ID: $instanceId。初始化失败也可能继续计费，可用此地区的「关节点」销毁。"
  $ip = $null
  for ($i=1; $i -le 40; $i++) {
    Start-Sleep -Seconds 6
    $state = Invoke-Api "/instances/$instanceId"
    if ($state.instance.status -eq 'active' -and $state.instance.main_ip -and $state.instance.main_ip -ne '0.0.0.0') {
      $ip = $state.instance.main_ip; break
    }
    Write-Host "等待实例激活... ($i/40)"
  }
  if (-not $ip) { throw "实例 $instanceId 激活等待超时；实例未自动删除，请刷新状态或到控制台核对。" }
  Write-Host "实例已激活，IP: $ip；等待代理安装和域名更新..."
  $ready=$false; $dnsOk=$false
  for ($i=1; $i -le 40; $i++) {
    $ready = Test-Port443 $ip; $dnsOk = ((Get-DnsIp) -eq $ip)
    if ($ready -and $dnsOk) { break }
    Write-Host "等待初始化 ($i/40)：443=$ready，域名=$dnsOk"
    Start-Sleep -Seconds 6
  }
  & ipconfig /flushdns | Out-Null
  if ($ready -and $dnsOk) { Write-Host '节点基础检查已通过。' -ForegroundColor Green }
  else { Write-Warning "实例已创建，初始化检查未全部通过：443=$ready，域名=$dnsOk。实例仍存在，请继续排查或关闭。" }
  Write-Host ('客户端链接：' + (New-Link))
  if (-not ($ready -and $dnsOk)) { throw '等待初始化超时；请查看上方实例 ID。' }
}

function Stop-Node {
  $instances = @(Get-Node)
  if ($instances.Count -eq 0) { Write-Host "$($Current.name)没有实例，无需操作。"; return }
  $instance = $instances[0]
  Write-Host "正在销毁 $($Current.name)：$($instance.id) ($($instance.main_ip)) ..."
  $null = Invoke-Api "/instances/$($instance.id)" 'Delete'
  Write-Host '已提交销毁请求，随后刷新状态确认。' -ForegroundColor Green
}

$mutex = $null; $locked = $false
try {
  if ($Action -eq 'export') { Write-ClientYaml; return }
  $Headers = @{Authorization='Bearer '+(Get-Content -LiteralPath (Join-Path $Dir 'vultr-api.key') -Raw).Trim()}
  if ($Action -in @('start','stop')) {
    $mutex = [Threading.Mutex]::new($false, ('Local\VultrNodeManager-' + $Current.id))
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw '此节点已有开关操作在进行，请等待完成。' }
  }
  switch ($Action) {
    'status' { Write-RefreshStatus }
    'start'  { Start-Node }
    'stop'   { Stop-Node }
  }
} catch { Write-Error -ErrorAction Continue $_.Exception.Message; exit 1 }
finally {
  if ($locked) { $mutex.ReleaseMutex() }
  if ($mutex) { $mutex.Dispose() }
}
