<#
  Vultr 多地区节点图形界面。
  地区配置来自 nodes.json；子进程调用 vultr-node.ps1，状态以 JSON 标记传递。
  双击 节点管理.vbs 启动；-SelfTest -Node los-angeles 只读检查子进程链路。
#>
[CmdletBinding()]
param([switch]$SelfTest, [string]$Node = 'tokyo', [switch]$Panel)

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

function Show-NodeDashboard {
  # Each card runs in its own module scope on the same UI thread. Event handlers,
  # timers and child-process state stay bound to that card, without extra windows.
  $dashboard = New-Object Windows.Forms.Form
  $dashboard.Text = 'Vultr 节点管理'
  $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $dashboard.ClientSize = New-Object Drawing.Size([Math]::Min(1280, $area.Width-60), [Math]::Min(820, $area.Height-70))
  $dashboard.MinimumSize = New-Object Drawing.Size(900, 650)
  $dashboard.StartPosition = 'CenterScreen'
  $dashboard.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
  $dashboard.BackColor = [Drawing.Color]::FromArgb(246,247,249)
  $layout = New-Object Windows.Forms.TableLayoutPanel
  $layout.Dock='Fill'; $layout.ColumnCount=1; $layout.RowCount=2
  [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',58)))
  [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
  $dashboard.Controls.Add($layout)
  $heading = New-Object Windows.Forms.Label
  $heading.Dock='Fill'; $heading.Padding=New-Object Windows.Forms.Padding(16,0,0,0)
  $heading.TextAlign='MiddleLeft'; $heading.Font=New-Object Drawing.Font('Microsoft YaHei UI',12)
  $heading.Text='全部节点  ·  状态、操作和日志各自独立'
  [void]$layout.Controls.Add($heading,0,0)
  $scroll = New-Object Windows.Forms.Panel
  $scroll.Dock='Fill'; $scroll.AutoScroll=$true
  [void]$layout.Controls.Add($scroll,0,1)
  $cards = New-Object Windows.Forms.TableLayoutPanel
  $cards.ColumnCount=@($NodeConfig.nodes).Count; $cards.RowCount=1
  $cards.MinimumSize=New-Object Drawing.Size((360*$cards.ColumnCount),560)
  $cards.Size=$cards.MinimumSize
  $scroll.AutoScrollMinSize=$cards.MinimumSize
  $scroll.Controls.Add($cards)
  $resizeCards = {
    $cards.Size=New-Object Drawing.Size([Math]::Max($cards.MinimumSize.Width,$scroll.ClientSize.Width),[Math]::Max($cards.MinimumSize.Height,$scroll.ClientSize.Height))
  }
  $scroll.Add_ClientSizeChanged({ & $resizeCards })
  $modules = @()
  try {
    foreach ($entry in $NodeConfig.nodes) {
      if (@($NodeConfig.nodes | Where-Object {$_.id -eq $entry.id}).Count -ne 1) { throw '节点 ID 重复。' }
      $module = New-Module -Name ('NodeCard-'+[guid]::NewGuid().ToString('N')) -ArgumentList $PSCommandPath,$entry.id -ScriptBlock {
        param($PanelPath,$NodeId)
        . $PanelPath -Panel -Node $NodeId
        Export-ModuleMember -Function Get-NodePanel,Initialize-NodePanel,Close-NodePanel,Get-NodeBusy
      }
      $modules += $module
      [void]$cards.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',(100.0/$cards.ColumnCount))))
      $card = & $module { Get-NodePanel }
      [void]$cards.Controls.Add($card,($modules.Count-1),0)
    }
    $dashboard.Add_Shown({ & $resizeCards; foreach ($module in $modules) { & $module { Initialize-NodePanel } } })
    $dashboard.Add_FormClosing({
      param($sender,$eventArgs)
      $working=@($modules | Where-Object { & $_ { Get-NodeBusy } })
      if ($working.Count) {
        $answer=[Windows.Forms.MessageBox]::Show($dashboard,'当前还有操作在进行中。关闭窗口不会取消已提交的云端操作，确定要关闭吗？','确认关闭','YesNo','Question')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { $eventArgs.Cancel=$true }
      }
    })
    [void]$dashboard.ShowDialog()
  } finally {
    foreach ($module in $modules) { & $module { Close-NodePanel }; Remove-Module $module -ErrorAction SilentlyContinue }
    $dashboard.Dispose()
  }
}

if (-not $Panel) { Show-NodeDashboard; return }

$colOk    = [Drawing.Color]::FromArgb(38, 160, 90)
$colOff   = [Drawing.Color]::FromArgb(120, 124, 132)
$colWarn  = [Drawing.Color]::FromArgb(200, 145, 20)
$colBusy  = [Drawing.Color]::FromArgb(30, 120, 200)
$colInk   = [Drawing.Color]::FromArgb(32, 34, 38)
$colFace  = [Drawing.Color]::FromArgb(246, 247, 249)
$colBtnPl = [Drawing.Color]::FromArgb(232, 234, 238)

$form = New-Object Windows.Forms.UserControl
$form.Name = [string]$script:selectedNode.id
$form.Dock = 'Fill'
$form.Margin = New-Object Windows.Forms.Padding(6,0,6,8)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = $colFace

$root = New-Object Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 7
[void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 70)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 114)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 36)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 144)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 86)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 36)))
$form.Controls.Add($root)

# ---- 顶部状态横幅 ----
$banner = New-Object Windows.Forms.Label
$banner.Dock = 'Fill'
$banner.Margin = New-Object Windows.Forms.Padding(0)
$banner.Text = '…  正在读取状态'
$banner.TextAlign = 'MiddleCenter'
$banner.Font = New-Object Drawing.Font('Microsoft YaHei UI', 11, [Drawing.FontStyle]::Bold)
$banner.Padding = New-Object Windows.Forms.Padding(8)
$banner.ForeColor = [Drawing.Color]::White
$banner.BackColor = $colOff
[void]$root.Controls.Add($banner, 0, 0)

# ---- 显眼的时长和账户余额；账户数据属于全部地区 ----
$metrics = New-Object Windows.Forms.TableLayoutPanel
$metrics.Dock = 'Fill'
$metrics.ColumnCount = 2; $metrics.RowCount = 1
$metrics.Padding = New-Object Windows.Forms.Padding(8, 6, 0, 0)
[void]$metrics.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 52)))
[void]$metrics.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 48)))
[void]$root.Controls.Add($metrics, 0, 1)

function New-MetricCard([string]$Title, [int]$Column, $Accent) {
  $card = New-Object Windows.Forms.TableLayoutPanel
  $card.Dock='Fill'; $card.ColumnCount=1; $card.RowCount=4
  $card.Padding=New-Object Windows.Forms.Padding(6, 2, 6, 2)
  $card.Margin=New-Object Windows.Forms.Padding(0, 0, 8, 0)
  $card.BackColor=[Drawing.Color]::White
  foreach ($height in @(20, 32, 22, 22)) { [void]$card.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, $height))) }
  $labels=@()
  for ($i=0; $i -lt 4; $i++) {
    $label=New-Object Windows.Forms.Label
    $label.Dock='Fill'; $label.TextAlign='MiddleLeft'; $label.AutoEllipsis=$true
    $label.Margin=New-Object Windows.Forms.Padding(0)
    $label.ForeColor=$colInk
    if ($i -eq 0) { $label.Text=$Title }
    elseif ($i -eq 1) { $label.Text='—'; $label.Font=New-Object Drawing.Font('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold); $label.ForeColor=$Accent }
    else { $label.Font=New-Object Drawing.Font('Microsoft YaHei UI', 8); $label.ForeColor=$colOff }
    [void]$card.Controls.Add($label, 0, $i)
    $labels+=$label
  }
  [void]$metrics.Controls.Add($card, $Column, 0)
  return ,$labels
}
$ageLabels=New-MetricCard '已开时长' 0 $colBusy
$lblAge=$ageLabels[1]; $lblCreated=$ageLabels[2]
$ageLabels[3].Text='自云端创建起算；其他设备销毁后请刷新'
$balanceLabels=New-MetricCard '账户预计剩余' 1 $colOk
$lblBalance=$balanceLabels[1]; $lblBalanceDetail=$balanceLabels[2]; $lblBalanceUpdated=$balanceLabels[3]
$lblBalanceDetail.Text='正在查询账户余额'
$script:createdAtUtc=$null

# ---- 每张卡片固定绑定自己的地区 ----
$selectorBar = New-Object Windows.Forms.FlowLayoutPanel
$selectorBar.Dock = 'Fill'
$selectorBar.Padding = New-Object Windows.Forms.Padding(8, 5, 8, 4)
$planLabel = New-Object Windows.Forms.Label
$planLabel.AutoSize = $true
$planLabel.Margin = New-Object Windows.Forms.Padding(0, 5, 0, 0)
$planLabel.Text = "$($script:selectedNode.region) · $($script:selectedNode.plan)"
[void]$selectorBar.Controls.Add($planLabel)
[void]$root.Controls.Add($selectorBar, 0, 2)

# ---- 实例连接详情 ----
$details = New-Object Windows.Forms.TableLayoutPanel
$details.Dock = 'Fill'
$details.ColumnCount = 2
$details.RowCount = 4
$details.Padding = New-Object Windows.Forms.Padding(8, 2, 8, 2)
[void]$details.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 68)))
[void]$details.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
for ($i = 0; $i -lt $details.RowCount; $i++) { [void]$details.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, (100.0 / $details.RowCount)))) }
[void]$root.Controls.Add($details, 0, 3)

$detailNames = @('实例 ID', '公网 IP', '域名解析', '443 端口')
$detailValues = @{}
for ($i = 0; $i -lt $detailNames.Count; $i++) {
  $lk = New-Object Windows.Forms.Label
  $lk.Text = $detailNames[$i]
  $lk.Dock = 'Fill'
  $lk.TextAlign = 'MiddleLeft'
  $lk.ForeColor = [Drawing.Color]::FromArgb(110, 114, 122)
  $lv = New-Object Windows.Forms.Label
  $lv.Text = '—'
  $lv.Dock = 'Fill'
  $lv.TextAlign = 'MiddleLeft'
  $lv.AutoEllipsis = $true
  $lv.ForeColor = $colInk
  [void]$details.Controls.Add($lk, 0, $i)
  [void]$details.Controls.Add($lv, 1, $i)
  $detailValues[$detailNames[$i]] = $lv
}
$lblId   = $detailValues['实例 ID']
$lblIp   = $detailValues['公网 IP']
$lblDns  = $detailValues['域名解析']
$lblPort = $detailValues['443 端口']

# ---- 按钮条 ----
$bar = New-Object Windows.Forms.FlowLayoutPanel
$bar.Dock = 'Fill'
$bar.WrapContents = $true
$bar.BackColor = $colFace
$bar.Padding = New-Object Windows.Forms.Padding(8, 4, 8, 4)
[void]$root.Controls.Add($bar, 0, 4)

function New-Btn([string]$text, $bg, $fg) {
  $b = New-Object Windows.Forms.Button
  $b.Text = $text
  $b.Size = New-Object Drawing.Size(94, 32)
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.BackColor = $bg
  $b.ForeColor = $fg
  $b.Margin = New-Object Windows.Forms.Padding(0, 0, 6, 6)
  $b.Cursor = [Windows.Forms.Cursors]::Hand
  return $b
}

$btnStart   = New-Btn '开节点'   $colOk ([Drawing.Color]::White)
$btnStop    = New-Btn '关节点'   ([Drawing.Color]::FromArgb(214, 69, 69)) ([Drawing.Color]::White)
$btnRefresh = New-Btn '刷新状态' $colBtnPl $colInk
$btnClear   = New-Btn '清空日志' $colBtnPl $colInk
$btnExport  = New-Btn '导出配置' $colBtnPl $colInk
$bar.Controls.AddRange(@($btnStart, $btnStop, $btnRefresh, $btnClear, $btnExport))

$progress = New-Object Windows.Forms.ProgressBar
$progress.Style = 'Marquee'
$progress.MarqueeAnimationSpeed = 30
$progress.Size = New-Object Drawing.Size(60, 10)
$progress.Margin = New-Object Windows.Forms.Padding(12, 11, 0, 0)
$progress.Visible = $false
$bar.SetFlowBreak($btnRefresh,$true)
$bar.Controls.Add($progress)

# ---- 日志框 ----
$log = New-Object Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.Dock = 'Fill'
$log.ScrollBars = 'Both'
$log.WordWrap = $true
$log.BorderStyle = 'FixedSingle'
$log.BackColor = [Drawing.Color]::FromArgb(24, 26, 30)
$log.ForeColor = [Drawing.Color]::FromArgb(214, 220, 230)
$log.Font = New-Object Drawing.Font('Consolas', 9)
$log.Margin = New-Object Windows.Forms.Padding(8, 0, 8, 4)
[void]$root.Controls.Add($log, 0, 5)

# ---- 底部状态文字 ----
$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Dock = 'Fill'
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.Padding = New-Object Windows.Forms.Padding(8, 0, 8, 0)
$statusLabel.ForeColor = [Drawing.Color]::FromArgb(110, 114, 122)
$statusLabel.Text = '就绪'
[void]$root.Controls.Add($statusLabel, 0, 6)

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
  $form.Dispose()
}
