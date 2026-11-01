<# Local first-run setup. Does not call any cloud API. #>
[CmdletBinding()]
param([string]$SettingsSource, [switch]$InitializeOnly, [switch]$SkipShortcut)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$settingsPath = Join-Path $root 'nodes.json'
$keyPath = Join-Path $root 'vultr-api.key'

if ($SettingsSource) {
  # Validate the complete source pair before copying either file.
  foreach ($name in @('nodes.json', 'vultr-api.key')) {
    $sourceFile = Join-Path $SettingsSource $name
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { throw "配置来源缺少 $name" }
    $destination = Join-Path $root $name
    if (Test-Path -LiteralPath $destination) {
      if ((Get-FileHash -LiteralPath $sourceFile).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
        throw "本地 $name 已存在且与来源不同。请先备份并核对配置，本次不覆盖。"
      }
    }
  }
  foreach ($name in @('nodes.json', 'vultr-api.key')) {
    $destination = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $destination)) { Copy-Item -LiteralPath (Join-Path $SettingsSource $name) -Destination $destination }
  }
} else {
  if (-not (Test-Path -LiteralPath $settingsPath)) { Copy-Item -LiteralPath (Join-Path $root 'nodes.example.json') -Destination $settingsPath }
  if (-not (Test-Path -LiteralPath $keyPath)) { [IO.File]::WriteAllText($keyPath, '', [Text.UTF8Encoding]::new($false)) }
}

if ($InitializeOnly) {
  Write-Host '本地模板已准备。请填写 nodes.json 和 vultr-api.key，再运行 setup.ps1。'
  return
}

$rawSettings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
if ($rawSettings -match 'YOUR_') { throw '配置仍有 YOUR_* 占位值。请导入旧主机的两个配置文件，或填好模板。' }
$config = $rawSettings | ConvertFrom-Json
if ($config.version -ne 1 -or @($config.nodes).Count -eq 0) { throw 'nodes.json 版本错误或没有节点。' }
$ids=@{}; $labels=@{}; $domains=@{}
foreach ($entry in $config.nodes) {
  if ($entry.ipVersion -and $entry.ipVersion -notin @('ipv4','ipv6')) { throw 'ipVersion 只能为 ipv4 或 ipv6。' }
  if ($entry.plan -like '*-v6' -and $entry.ipVersion -and $entry.ipVersion -ne 'ipv6') { throw 'IPv6-only 套餐必须使用 ipv6。' }
  foreach ($field in @('id','name','linkName','region','label','domain','plan','osId','startupScriptId','uuid','publicKey','shortId','sni')) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.$field)) { throw "节点配置缺少 $field" }
  }
  if ($entry.id -notmatch '^[a-z0-9-]+$') { throw '节点 id 只能使用小写英文字母、数字和连字符。' }
  foreach ($pair in @(@($ids,$entry.id),@($labels,$entry.label),@($domains,$entry.domain))) {
    if ($pair[0].ContainsKey([string]$pair[1])) { throw '节点 id、标签和域名必须分别唯一。' }
    $pair[0][[string]$pair[1]]=$true
  }
  $parsedGuid=[guid]::Empty
  if (-not [guid]::TryParse([string]$entry.uuid,[ref]$parsedGuid)) { throw 'VLESS UUID 格式不正确。' }
  if (-not [guid]::TryParse([string]$entry.startupScriptId,[ref]$parsedGuid)) { throw 'Vultr 开机脚本 ID 格式不正确。' }
  if ($entry.publicKey -notmatch '^[A-Za-z0-9_-]{43}$') { throw 'REALITY 公钥格式不正确。' }
  if ($entry.shortId -notmatch '^[0-9a-fA-F]{2,16}$' -or $entry.shortId.Length % 2 -ne 0) { throw 'REALITY short ID 格式不正确。' }
}
$apiKey=([string](Get-Content -LiteralPath $keyPath -Raw)).Trim()
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw '请在 vultr-api.key 中填写 Vultr API 密钥。' }
Write-Host "本地配置检查通过，共 $(@($config.nodes).Count) 个地区。未创建云端资源。"
if (-not $SkipShortcut) { & (Join-Path $root '_install-shortcut.ps1') }
