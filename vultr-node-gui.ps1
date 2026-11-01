<#
  Vultr 多地区节点图形界面。
  地区配置来自 nodes.json；子进程调用 vultr-node.ps1，状态以 JSON 标记传递。
  双击 节点管理.vbs 启动；-SelfTest -Node los-angeles 只读检查子进程链路。
#>
[CmdletBinding()]
param([switch]$SelfTest, [string]$Node = 'tokyo', [switch]$Panel, [object]$Shared)

$ErrorActionPreference = 'Stop'

$Dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Dir 'node-time.ps1')
$NodeScript = Join-Path $Dir 'vultr-node.ps1'
$NodeConfig = Get-Content -LiteralPath (Join-Path $Dir 'nodes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:selectedNode = @($NodeConfig.nodes | Where-Object { $_.id -eq $Node })[0]
if (-not $script:selectedNode) { throw "找不到节点配置：$Node" }
$script:pendingDeletes = @{}
$script:confirmedDeletes = @{}

function Get-PendingDeletion {
  if ($null -ne $script:pendingDeletes -and $script:pendingDeletes.ContainsKey([string]$script:selectedNode.id)) {
    return $script:pendingDeletes[[string]$script:selectedNode.id]
  }
  return $null
}

# ==================== 子进程调用 / 输出实时读取 ====================

function Start-NodeAction {
  param([Parameter(Mandatory = $true)][string]$Action)

  $outFile = Join-Path $env:TEMP ("vultr-node-{0}.out" -f ([guid]::NewGuid().ToString('N')))
  $errFile = "$outFile.err"

  # 子进程强制 UTF-8 输出（否则中文会按 GBK 写出乱码）；
  # 用 -EncodedCommand 传递命令，规避路径/参数里的空格与引号问题。
  $escapedScript = $NodeScript.Replace("'", "''")
  $escapedNode = ([string]$script:selectedNode.id).Replace("'", "''")
  $cmd = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false); " +
         "`$OutputEncoding=[Text.UTF8Encoding]::new(`$false); " +
         "& '$escapedScript' '$Action' -Node '$escapedNode' -MachineStatus"
  $confirmDeletion = $Action -eq 'status' -and $null -ne (Get-PendingDeletion)
  if ($confirmDeletion) { $cmd += ' -ConfirmDeletion' }
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))

  $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$enc `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError  $errFile `
            -WindowStyle Hidden -PassThru

  # 保留句柄，确保 Windows PowerShell 能读取已退出的子进程退出码。
  $null = $proc.Handle

  [pscustomobject]@{ Process = $proc; OutFile = $outFile; ErrFile = $errFile; ConfirmDeletion = $confirmDeletion }
}

function Read-NewText {
  # 只返回“完整的行”，避免把还没写完的多字节汉字截断
  param([string]$Path, [ref]$Offset)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $fs = $null
  try { $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite) }
  catch { return '' }
  try {
    if ($fs.Length -le $Offset.Value) { return '' }
    $n = [int]($fs.Length - $Offset.Value)
    [void]$fs.Seek([long]$Offset.Value, [IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] $n
    $read = $fs.Read($buf, 0, $n)
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
    $cut = $text.LastIndexOf("`n")
    if ($cut -lt 0) { return '' }
    $ok = $text.Substring(0, $cut + 1)
    $Offset.Value = [long]$Offset.Value + [Text.Encoding]::UTF8.GetByteCount($ok)
    return $ok
  } finally { $fs.Dispose() }
}

function Read-Rest {
  param([string]$Path, [ref]$Offset)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $fs = $null
  try { $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite) }
  catch { return '' }
  try {
    if ($fs.Length -le $Offset.Value) { return '' }
    $n = [int]($fs.Length - $Offset.Value)
    [void]$fs.Seek([long]$Offset.Value, [IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] $n
    $read = $fs.Read($buf, 0, $n)
    $Offset.Value = [long]$Offset.Value + $read
    return [Text.Encoding]::UTF8.GetString($buf, 0, $read)
  } finally { $fs.Dispose() }
}

function Format-ChildStderr {
  # 子进程的报错会被 PowerShell 包成 CLIXML，这里只挑出真正的错误文字
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
  if ($Raw -notmatch '#< CLIXML') { return $Raw }
  $sb = New-Object Text.StringBuilder
  foreach ($m in [regex]::Matches($Raw, '<S[^>]*S="Error"[^>]*>(.*?)</S>', 'Singleline')) {
    $t = $m.Groups[1].Value -replace '_x000D_', '' -replace '_x000A_', "`r`n"
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    [void]$sb.Append($t)
  }
  return $sb.ToString()
}

# ==================== 自检模式（不开窗口，验证链路是否通）====================
if ($SelfTest) {
  if (-not (Test-Path -LiteralPath $NodeScript)) { Write-Host "找不到 $NodeScript"; exit 1 }
  Write-Host '[SelfTest] 调用 status ...'
  $job = Start-NodeAction -Action 'status'
  $o = [long]0; $e = [long]0
  $errAll = New-Object Text.StringBuilder
  while (-not $job.Process.HasExited) {
    $t = Read-NewText -Path $job.OutFile -Offset ([ref]$o); if ($t) { Write-Host -NoNewline $t }
    $te = Read-NewText -Path $job.ErrFile -Offset ([ref]$e); if ($te) { [void]$errAll.Append($te) }
    Start-Sleep -Milliseconds 120
  }
  $t = Read-NewText -Path $job.OutFile -Offset ([ref]$o); if ($t) { Write-Host -NoNewline $t }
  [void]$errAll.Append((Read-Rest -Path $job.ErrFile -Offset ([ref]$e)))
  $errTxt = Format-ChildStderr $errAll.ToString()
  if ($errTxt.Trim()) { Write-Host "`n[stderr] $errTxt" }
  $job.Process.WaitForExit()
  $childExitCode = $job.Process.ExitCode
  Write-Host "`n[SelfTest] 完成，退出码：$childExitCode"
  Remove-Item $job.OutFile, $job.ErrFile -ErrorAction SilentlyContinue
  exit $childExitCode
}

# ==================== 界面 ====================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $Dir 'node-dashboard.ps1')
if (-not $Panel) { Show-NodeDashboard; return }
. Initialize-NodeRow
# ==================== 运行状态 ====================
$script:busy   = $false
$script:job    = $null
$script:outOff = [long]0
$script:errOff = [long]0
$script:buf    = New-Object Text.StringBuilder   # 当前动作的输出（用于解析状态）
$script:errBuf = New-Object Text.StringBuilder
$script:cur    = ''
$script:after  = $null

function Append-Log([string]$text) {
  if (-not $text) { return }
  # 子进程的行尾混用 CRLF / 孤立 LF，统一成 CRLF，否则文本框偶尔不换行
  $norm = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
  [void]$script:buf.Append($norm)
  $visibleText = [regex]::Replace($norm, '(?m)^@@(?:NODE_STATUS|ACCOUNT_STATUS|NODE_STOP)@@[^\r\n]*(?:\r?\n)?', '')
  $log.AppendText($visibleText)
  $log.SelectionStart = $log.TextLength
  $log.ScrollToCaret()
  # Apply complete markers as they arrive, before slower account requests finish.
  if ($script:cur -eq 'status') {
    if ($norm -match '(?m)^@@NODE_STATUS@@') { Update-Card $script:buf.ToString() }
    if ($norm -match '(?m)^@@ACCOUNT_STATUS@@') { Update-AccountCard $script:buf.ToString() }
  } elseif ($script:cur -eq 'stop' -and $norm -match '(?m)^@@NODE_STOP@@') {
    Update-StopReceipt $script:buf.ToString()
  }
}

function Set-Busy([bool]$b) {
  $pending = $null -ne (Get-PendingDeletion)
  $btnStart.Enabled   = -not $b -and -not $pending
  $btnStop.Enabled    = -not $b -and -not $pending
  $btnRefresh.Enabled = -not $b
  $btnClear.Enabled   = -not $b
  $btnExport.Enabled  = -not $b
  $progress.Visible   = $b
}

function Update-NodeAge {
  $timing = Get-InstanceTiming $script:createdAtUtc
  $lblAge.Text = if ($null -ne $timing.ageSeconds) { Format-NodeAge $timing.ageSeconds } else { '—' }
}

function Show-PendingDeletion([string]$Message) {
  $lblId.Text='—'; $lblIp.Text='—'; $lblDns.Text='—'; $lblPort.Text='—'
  $lblCreated.Text='—'; $lblAge.Text='—'; $script:createdAtUtc=$null
  $banner.Text="$($script:selectedNode.name) · $Message"; $banner.BackColor=$colBusy
}

function Update-StopReceipt([string]$Text) {
  $markers=[regex]::Matches($Text, '(?m)^@@NODE_STOP@@([^\r\n]+)')
  if ($markers.Count -eq 0) { return }
  try { $receipt=$markers[$markers.Count-1].Groups[1].Value | ConvertFrom-Json } catch { return }
  if ($receipt.node -ne $script:selectedNode.id) { return }
  if ($receipt.state -eq 'absent') {
    [void]$script:pendingDeletes.Remove([string]$receipt.node)
    Show-PendingDeletion '未创建 / 已销毁'; $banner.BackColor=$colOff
    $script:after=$null
  } elseif ($receipt.state -eq 'submitted' -and -not [string]::IsNullOrWhiteSpace([string]$receipt.id)) {
    if ($null -ne $script:confirmedDeletes) { [void]$script:confirmedDeletes.Remove([string]$receipt.node) }
    $script:pendingDeletes[[string]$receipt.node]=[pscustomobject]@{id=$receipt.id;attempts=0}
    Show-PendingDeletion '销毁请求已受理，正在确认'
  }
}

function Format-UsdAmount([decimal]$Amount) {
  return 'US$ ' + $Amount.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
}

function Update-AccountCard([string]$Text) {
  $lblBalance.Text='—'; $lblBalance.ForeColor=$colWarn
  $lblBalanceDetail.Text='账户余额查询失败'; $lblBalanceUpdated.Text='点击刷新状态重试'
  $markers=[regex]::Matches($Text, '(?m)^@@ACCOUNT_STATUS@@([^\r\n]+)')
  if ($markers.Count -eq 0) { return }
  try {
    $data=$markers[$markers.Count-1].Groups[1].Value | ConvertFrom-Json
    if (-not $data.available) { return }
    foreach ($field in @('creditUSD','pendingChargesUSD','estimatedRemainingUSD')) {
      if ($null -eq $data.$field) { return }
    }
    $amount=[decimal]$data.estimatedRemainingUSD
    $credit=[decimal]$data.creditUSD; $pending=[decimal]$data.pendingChargesUSD
    $updated=([DateTimeOffset]::Parse($data.checkedAtUtc)).ToLocalTime().ToString('HH:mm:ss')
    $lblBalance.Text=Format-UsdAmount $amount
    $lblBalance.ForeColor=if ($amount -gt 0) { $colOk } else { $colWarn }
    $lblBalanceDetail.Text='预存 '+(Format-UsdAmount $credit)+' · 待结算 '+(Format-UsdAmount $pending)
    $lblBalanceUpdated.Text='账户全部地区合计 · 更新于 '+$updated
  } catch { return }
}

function Update-Card([string]$t) {
  $markers = [regex]::Matches($t, '(?m)^@@NODE_STATUS@@([^\r\n]+)')
  $lblId.Text='—'; $lblIp.Text='—'; $lblDns.Text='—'; $lblPort.Text='—'
  $lblCreated.Text='—'; $lblAge.Text='—'; $script:createdAtUtc=$null
  if ($markers.Count -eq 0) {
    if ($null -ne (Get-PendingDeletion)) { Show-PendingDeletion '销毁请求已受理，等待网络恢复后确认'; return }
    $banner.Text = "$($script:selectedNode.name) · 查询失败，未确认云端状态"
    $banner.BackColor = $colWarn; return
  }
  try { $data = $markers[$markers.Count-1].Groups[1].Value | ConvertFrom-Json }
  catch { $banner.Text='状态数据无法解析'; $banner.BackColor=$colWarn; return }
  if ($data.node -ne $script:selectedNode.id) { $banner.Text='地区状态不匹配，请刷新'; $banner.BackColor=$colWarn; return }
  if (-not $data.exists) {
    $wasPending=$null -ne (Get-PendingDeletion)
    if ($wasPending) {
      [void]$script:pendingDeletes.Remove([string]$data.node)
      if ($null -eq $script:confirmedDeletes) { $script:confirmedDeletes=@{} }
      $script:confirmedDeletes[[string]$data.node]=$true
    }
    $confirmed=$null -ne $script:confirmedDeletes -and $script:confirmedDeletes.ContainsKey([string]$data.node)
    $banner.Text = if ($confirmed) { "$($data.name) · 已销毁" } else { "$($data.name) · 未创建 / 已销毁" }
    $banner.BackColor = $colOff; return
  }
  if ($null -ne $script:confirmedDeletes) { [void]$script:confirmedDeletes.Remove([string]$data.node) }
  $pending = Get-PendingDeletion
  if ($null -ne $pending) {
    if ($pending.id -eq $data.id) { Show-PendingDeletion '云端正在销毁，稍后自动确认'; return }
    # Another machine may already have recreated this region. Never act on its ID.
    [void]$script:pendingDeletes.Remove([string]$data.node)
  }
  $lblId.Text = $data.id; $lblIp.Text = $data.ip
  $timing = Get-InstanceTiming ([string]$data.createdAtUtc)
  if ($null -ne $timing.createdAtUtc) {
    $script:createdAtUtc = $timing.createdAtUtc
    $lblCreated.Text = ([DateTimeOffset]::Parse($timing.createdAtUtc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
    Update-NodeAge
  }
  $lblDns.Text = "$($data.domain) → $($data.dnsIp)"
  $lblDns.ForeColor = if ($data.dnsMatches) { $colOk } else { $colWarn }
  $lblPort.Text = if ($data.port443) { 'TCP 可达（未验证完整代理）' } else { 'TCP 不可达' }
  $lblPort.ForeColor = if ($data.port443) { $colOk } else { $colWarn }
  if ($data.status -eq 'active' -and $data.powerStatus -eq 'running' -and $data.port443 -and $data.dnsMatches) {
    $banner.Text = "$($data.name) · 运行中，基础检查通过"; $banner.BackColor=$colOk
  } else {
    $banner.Text = "$($data.name) · 实例存在，需检查（$($data.status) / $($data.powerStatus)）"
    $banner.BackColor=$colWarn
  }
}

function Invoke-Action([string]$action) {
  if ($script:busy) { return }
  if (-not (Test-Path -LiteralPath $NodeScript)) {
    [void][Windows.Forms.MessageBox]::Show("找不到调用脚本：`n$NodeScript", '错误')
    return
  }
  $names = @{ start = '开节点'; stop = '关节点'; status = '刷新状态'; export = '导出全部节点配置' }

  $script:busy  = $true
  $script:cur   = $action
  $script:after = if ($action -in @('start','stop')) { 'status' } else { $null }
  $pending = Get-PendingDeletion
  if ($action -eq 'status' -and $null -ne $pending) { $pending.attempts++ }
  [void]$script:buf.Clear()
  [void]$script:errBuf.Clear()
  $script:outOff = [long]0
  $script:errOff = [long]0

  Append-Log ("`r`n===== {0}  ·  {1} · {2} =====`r`n" -f (Get-Date -Format 'HH:mm:ss'), $script:selectedNode.name, $names[$action])
  Set-Busy $true
  $statusLabel.Text = "正在 $($names[$action]) ..."
  if ($action -eq 'status' -and $null -ne $pending) { Show-PendingDeletion '正在确认销毁结果' }
  elseif ($action -ne 'export') { $banner.Text = "$($script:selectedNode.name) · 正在$($names[$action])"; $banner.BackColor = $colBusy }

  try {
    $script:job = Start-NodeAction -Action $action
  } catch {
    Set-Busy $false
    $script:busy = $false
    Append-Log "启动失败: $($_.Exception.Message)`r`n"
    $statusLabel.Text = '就绪'
    return
  }
  $timer.Start()
}

function Complete-Action {
  $timer.Stop()
  $rest = Read-Rest -Path $script:job.OutFile -Offset ([ref]$script:outOff)
  if ($rest) { Append-Log $rest }
  [void]$script:errBuf.Append((Read-Rest -Path $script:job.ErrFile -Offset ([ref]$script:errOff)))
  $errTxt = Format-ChildStderr $script:errBuf.ToString()
  if ($errTxt.Trim()) { Append-Log ("[错误输出]`r`n" + $errTxt.TrimEnd() + "`r`n") }
  $script:job.Process.WaitForExit()
  $exitCode = $script:job.Process.ExitCode
  if ($exitCode -ne 0) {
    if ($null -ne $Shared -and $script:cur -in @('start','stop','export')) {
      $Shared.selectedId=[string]$script:selectedNode.id; $Shared.expanded=$true
    }
    if ($script:job.ConfirmDeletion -and $null -ne (Get-PendingDeletion)) {
      Append-Log "销毁请求已受理；本次云端确认暂不可用，保留进度并稍后重试。`r`n"
    } else { Append-Log "操作未成功（退出码 $exitCode），请查看上方日志。`r`n" }
  }
  Remove-Item -LiteralPath $script:job.OutFile, $script:job.ErrFile -ErrorAction SilentlyContinue

  $cur = $script:cur
  $confirmDeletion = $script:job.ConfirmDeletion
  $script:job   = $null
  $script:busy  = $false
  Set-Busy $false
  $statusLabel.Text = '就绪'
  if ($cur -eq 'status') {
    Update-Card $script:buf.ToString()
    if (-not $confirmDeletion) { Update-AccountCard $script:buf.ToString() }
    Set-Busy $false
    $pending = Get-PendingDeletion
    if ($null -ne $pending) {
      $statusLabel.Text = if ($pending.attempts -lt 3) { '销毁请求已受理，4 秒后自动确认' } else { '暂未确认销毁结果；网络恢复后点击刷新状态' }
      if ($pending.attempts -lt 3) { $deletionTimer.Stop(); $deletionTimer.Start() }
    }
  }

  if ($script:after -eq 'status') { $script:after = $null; Invoke-Action 'status' }
}

# ==================== 定时器：实时搬运子进程输出 ====================
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
  if (-not $script:job) { $timer.Stop(); return }
  $t = Read-NewText -Path $script:job.OutFile -Offset ([ref]$script:outOff)
  if ($t) { Append-Log $t }
  $te = Read-NewText -Path $script:job.ErrFile -Offset ([ref]$script:errOff)
  if ($te) { [void]$script:errBuf.Append($te) }
  if ($script:job.Process.HasExited) { Complete-Action }
})

# This clock only updates the displayed lifetime; cloud status still needs refresh.
$ageTimer = New-Object Windows.Forms.Timer
$ageTimer.Interval = 1000
$ageTimer.Add_Tick({ Update-NodeAge })
$deletionTimer = New-Object Windows.Forms.Timer
$deletionTimer.Interval = 4000
$deletionTimer.Add_Tick({
  $pending = Get-PendingDeletion
  if (-not $script:busy -and $null -ne $pending -and $pending.attempts -lt 3) { Invoke-Action 'status' }
})

# ==================== 事件绑定 ====================
$btnStart.Add_Click({ Invoke-Action 'start' })
$btnRefresh.Add_Click({ $pending=Get-PendingDeletion; if ($null -ne $pending) { $pending.attempts=0 }; Invoke-Action 'status' })
$btnExport.Add_Click({ Invoke-Action 'export' })
$btnClear.Add_Click({
  $log.Clear()
  [void]$script:buf.Clear()
})
$btnStop.Add_Click({
  $r = [Windows.Forms.MessageBox]::Show(
    "确定要销毁「$($script:selectedNode.name)」节点吗？`n区域：$($script:selectedNode.region)`n标签：$($script:selectedNode.label)`n`n只销毁这个地区的实例，数据会永久删除。下次使用需要重新创建。",
    '关节点确认',
    [Windows.Forms.MessageBoxButtons]::YesNo,
    [Windows.Forms.MessageBoxIcon]::Warning)
  if ($r -eq [Windows.Forms.DialogResult]::Yes) { Invoke-Action 'stop' }
})

# Long IPv6 addresses and timestamps remain readable even on narrower cards.
$toolTip=New-Object Windows.Forms.ToolTip
foreach ($label in @($banner,$lblId,$lblIp,$lblDns,$lblPort)+$ageLabels+$balanceLabels) {
  $label.Add_MouseEnter({ $toolTip.SetToolTip($this,$this.Text) })
}

function Get-NodePanel { return $form }
function Get-NodeBusy { return $script:busy }
function Initialize-NodePanel {
  $ageTimer.Start(); $deletionTimer.Start(); Invoke-Action 'status'
}
function Close-NodePanel {
  $deletionTimer.Dispose(); $ageTimer.Dispose(); $timer.Dispose(); $toolTip.Dispose()
  if ($null -ne $script:job) {
    # Do not kill a child that may have already submitted a cloud operation.
    if ($script:job.Process.HasExited) {
      Remove-Item -LiteralPath $script:job.OutFile,$script:job.ErrFile -ErrorAction SilentlyContinue
    }
    $script:job.Process.Dispose()
  }
  $log.Dispose(); $form.Dispose()
}
