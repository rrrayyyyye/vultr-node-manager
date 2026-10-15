<#
  Vultr 多地区节点图形界面。
  地区配置来自 nodes.json；子进程调用 vultr-node.ps1，状态以 JSON 标记传递。
  双击 节点管理.vbs 启动；-SelfTest -Node los-angeles 只读检查子进程链路。
#>
[CmdletBinding()]
param([switch]$SelfTest, [string]$Node = 'tokyo')

$ErrorActionPreference = 'Stop'

$Dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$NodeScript = Join-Path $Dir 'vultr-node.ps1'
$NodeConfig = Get-Content -LiteralPath (Join-Path $Dir 'nodes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:selectedNode = @($NodeConfig.nodes | Where-Object { $_.id -eq $Node })[0]
if (-not $script:selectedNode) { throw "找不到节点配置：$Node" }

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
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))

  $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$enc `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError  $errFile `
            -WindowStyle Hidden -PassThru

  # 保留句柄，确保 Windows PowerShell 能读取已退出的子进程退出码。
  $null = $proc.Handle

  [pscustomobject]@{ Process = $proc; OutFile = $outFile; ErrFile = $errFile }
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

$colOk    = [Drawing.Color]::FromArgb(38, 160, 90)
$colOff   = [Drawing.Color]::FromArgb(120, 124, 132)
$colWarn  = [Drawing.Color]::FromArgb(200, 145, 20)
$colBusy  = [Drawing.Color]::FromArgb(30, 120, 200)
$colInk   = [Drawing.Color]::FromArgb(32, 34, 38)
$colFace  = [Drawing.Color]::FromArgb(246, 247, 249)
$colBtnPl = [Drawing.Color]::FromArgb(232, 234, 238)

$form = New-Object Windows.Forms.Form
$form.Text = 'Vultr 多地区节点管理 · 东京 / 洛杉矶'
$form.ClientSize = New-Object Drawing.Size(850, 650)
$form.MinimumSize = New-Object Drawing.Size(830, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = $colFace

$root = New-Object Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 6
[void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 74)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 48)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 104)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 58)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 26)))
$form.Controls.Add($root)

# ---- 顶部状态横幅 ----
$banner = New-Object Windows.Forms.Label
$banner.Dock = 'Fill'
$banner.Margin = New-Object Windows.Forms.Padding(0)
$banner.Text = '…  正在读取状态'
$banner.TextAlign = 'MiddleCenter'
$banner.Font = New-Object Drawing.Font('Microsoft YaHei UI', 18, [Drawing.FontStyle]::Bold)
$banner.ForeColor = [Drawing.Color]::White
$banner.BackColor = $colOff
[void]$root.Controls.Add($banner, 0, 0)

# ---- 地区选择：所有动作仅针对当前选择 ----
$selectorBar = New-Object Windows.Forms.FlowLayoutPanel
$selectorBar.Dock = 'Fill'
$selectorBar.Padding = New-Object Windows.Forms.Padding(18, 9, 18, 4)
$selectorLabel = New-Object Windows.Forms.Label
$selectorLabel.Text = '选择地区'
$selectorLabel.AutoSize = $true
$selectorLabel.Margin = New-Object Windows.Forms.Padding(0, 5, 12, 0)
$nodeSelector = New-Object Windows.Forms.ComboBox
$nodeSelector.DropDownStyle = 'DropDownList'
$nodeSelector.DisplayMember = 'name'
$nodeSelector.Width = 210
foreach ($entry in $NodeConfig.nodes) { [void]$nodeSelector.Items.Add($entry) }
$nodeSelector.SelectedItem = $script:selectedNode
$planLabel = New-Object Windows.Forms.Label
$planLabel.AutoSize = $true
$planLabel.Margin = New-Object Windows.Forms.Padding(16, 5, 0, 0)
$planLabel.Text = "$($script:selectedNode.region) · $($script:selectedNode.plan)"
$selectorBar.Controls.AddRange(@($selectorLabel, $nodeSelector, $planLabel))
[void]$root.Controls.Add($selectorBar, 0, 1)

# ---- 详情四行 ----
$details = New-Object Windows.Forms.TableLayoutPanel
$details.Dock = 'Fill'
$details.ColumnCount = 2
$details.RowCount = 4
$details.Padding = New-Object Windows.Forms.Padding(18, 6, 18, 6)
[void]$details.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 96)))
[void]$details.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
for ($i = 0; $i -lt 4; $i++) { [void]$details.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 25))) }
[void]$root.Controls.Add($details, 0, 2)

$detailNames = @('实例 ID', '公网 IP', '域名解析', '443 端口')
$detailValues = @{}
for ($i = 0; $i -lt 4; $i++) {
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
$bar.WrapContents = $false
$bar.BackColor = $colFace
$bar.Padding = New-Object Windows.Forms.Padding(18, 10, 18, 8)
[void]$root.Controls.Add($bar, 0, 3)

function New-Btn([string]$text, $bg, $fg) {
  $b = New-Object Windows.Forms.Button
  $b.Text = $text
  $b.Size = New-Object Drawing.Size(104, 34)
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.BackColor = $bg
  $b.ForeColor = $fg
  $b.Margin = New-Object Windows.Forms.Padding(0, 0, 10, 0)
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
$progress.Size = New-Object Drawing.Size(150, 14)
$progress.Margin = New-Object Windows.Forms.Padding(12, 11, 0, 0)
$progress.Visible = $false
$bar.Controls.Add($progress)

# ---- 日志框 ----
$log = New-Object Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.Dock = 'Fill'
$log.ScrollBars = 'Both'
$log.WordWrap = $false
$log.BorderStyle = 'FixedSingle'
$log.BackColor = [Drawing.Color]::FromArgb(24, 26, 30)
$log.ForeColor = [Drawing.Color]::FromArgb(214, 220, 230)
$log.Font = New-Object Drawing.Font('Consolas', 9)
$log.Margin = New-Object Windows.Forms.Padding(18, 0, 18, 10)
[void]$root.Controls.Add($log, 0, 4)

# ---- 底部状态文字 ----
$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Dock = 'Fill'
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.Padding = New-Object Windows.Forms.Padding(18, 0, 0, 0)
$statusLabel.ForeColor = [Drawing.Color]::FromArgb(110, 114, 122)
$statusLabel.Text = '就绪'
[void]$root.Controls.Add($statusLabel, 0, 5)

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
  $visibleText = [regex]::Replace($norm, '(?m)^@@NODE_STATUS@@[^\r\n]*(?:\r?\n)?', '')
  $log.AppendText($visibleText)
  $log.SelectionStart = $log.TextLength
  $log.ScrollToCaret()
}

function Set-Busy([bool]$b) {
  $btnStart.Enabled   = -not $b
  $btnStop.Enabled    = -not $b
  $btnRefresh.Enabled = -not $b
  $btnClear.Enabled   = -not $b
  $btnExport.Enabled  = -not $b
  $nodeSelector.Enabled = -not $b
  $progress.Visible   = $b
}

function Update-Card([string]$t) {
  $markers = [regex]::Matches($t, '(?m)^@@NODE_STATUS@@([^\r\n]+)')
  $lblId.Text='—'; $lblIp.Text='—'; $lblDns.Text='—'; $lblPort.Text='—'
  if ($markers.Count -eq 0) {
    $banner.Text = "$($script:selectedNode.name) · 查询失败，请查看日志"
    $banner.BackColor = $colWarn; return
  }
  try { $data = $markers[$markers.Count-1].Groups[1].Value | ConvertFrom-Json }
  catch { $banner.Text='状态数据无法解析'; $banner.BackColor=$colWarn; return }
  if ($data.node -ne $script:selectedNode.id) { $banner.Text='地区状态不匹配，请刷新'; $banner.BackColor=$colWarn; return }
  if (-not $data.exists) {
    $banner.Text = "$($data.name) · 未创建 / 已销毁"
    $banner.BackColor = $colOff; return
  }
  $lblId.Text = $data.id; $lblIp.Text = $data.ip
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
  [void]$script:buf.Clear()
  [void]$script:errBuf.Clear()
  $script:outOff = [long]0
  $script:errOff = [long]0

  Append-Log ("`r`n===== {0}  ·  {1} · {2} =====`r`n" -f (Get-Date -Format 'HH:mm:ss'), $script:selectedNode.name, $names[$action])
  Set-Busy $true
  $statusLabel.Text = "正在 $($names[$action]) ..."
  if ($action -ne 'export') { $banner.Text = "$($script:selectedNode.name) · 正在$($names[$action])"; $banner.BackColor = $colBusy }

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
  if ($exitCode -ne 0) { Append-Log "操作未成功（退出码 $exitCode），请查看上方日志。`r`n" }
  Remove-Item -LiteralPath $script:job.OutFile, $script:job.ErrFile -ErrorAction SilentlyContinue

  $cur = $script:cur
  $script:job   = $null
  $script:busy  = $false
  Set-Busy $false
  $statusLabel.Text = '就绪'
  if ($cur -eq 'status') { Update-Card $script:buf.ToString() }

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

# ==================== 事件绑定 ====================
$btnStart.Add_Click({ Invoke-Action 'start' })
$btnRefresh.Add_Click({ Invoke-Action 'status' })
$btnExport.Add_Click({ Invoke-Action 'export' })
$nodeSelector.Add_SelectedIndexChanged({
  if ($script:busy -or -not $nodeSelector.SelectedItem) { return }
  $script:selectedNode = $nodeSelector.SelectedItem
  $planLabel.Text = "$($script:selectedNode.region) · $($script:selectedNode.plan)"
  $lblId.Text='—'; $lblIp.Text='—'; $lblDns.Text='—'; $lblPort.Text='—'
  Invoke-Action 'status'
})
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

$form.Add_Shown({ Invoke-Action 'status' })

$form.Add_FormClosing({
  param($s, $e)
  if ($script:busy) {
    $r = [Windows.Forms.MessageBox]::Show('当前还有操作在进行中。关闭窗口不会取消已提交的云端操作，确定要关闭吗？', '确认关闭',
          [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true }
  }
})

# ==================== 启动 ====================
try {
  [void]$form.ShowDialog()
} catch {
  [void][Windows.Forms.MessageBox]::Show("界面运行出错：`n$($_.Exception.Message)", '错误')
} finally {
  $timer.Dispose()
  $form.Dispose()
}
