# Presentation only. Node operations and process state remain in vultr-node-gui.ps1.
function New-DashboardLabel([string]$Text, [single]$Size=9, [bool]$Bold=$false) {
  $label=New-Object Windows.Forms.Label
  $label.Text=$Text; $label.Dock='Fill'; $label.TextAlign='MiddleLeft'
  $label.AutoEllipsis=$true; $label.Margin=New-Object Windows.Forms.Padding(0)
  $style=if($Bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}
  $label.Font=New-Object Drawing.Font('Microsoft YaHei UI',$Size,$style)
  $label.ForeColor=[Drawing.Color]::FromArgb(45,52,64)
  return $label
}

function New-DashboardButton([string]$Text, [int]$Width=66) {
  $button=New-Object Windows.Forms.Button
  $button.Text=$Text; $button.Size=New-Object Drawing.Size($Width,30)
  $button.FlatStyle='Flat'; $button.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(222,226,232)
  $button.BackColor=[Drawing.Color]::White; $button.ForeColor=[Drawing.Color]::FromArgb(65,75,91)
  $button.Margin=New-Object Windows.Forms.Padding(0,0,6,0)
  $button.Cursor=[Windows.Forms.Cursors]::Hand
  return $button
}

function Set-NodeColumns($Table) {
  # Identical column widths keep the header and every row aligned when resizing.
  $Table.ColumnCount=4; $Table.RowCount=1
  [void]$Table.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
  foreach($width in @(26,24,20,30)){
    [void]$Table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',$width)))
  }
}

function Show-NodeDashboard {
  $dashboard=New-Object Windows.Forms.Form
  $dashboard.Text='Vultr 节点管理'; $dashboard.StartPosition='CenterScreen'
  $dashboard.ClientSize=New-Object Drawing.Size(1020,466)
  $dashboard.MinimumSize=New-Object Drawing.Size(990,500)
  $dashboard.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
  $dashboard.BackColor=[Drawing.Color]::FromArgb(246,247,249)
  $layout=New-Object Windows.Forms.TableLayoutPanel
  $layout.Dock='Fill'; $layout.Padding=New-Object Windows.Forms.Padding(24,12,24,12)
  $layout.ColumnCount=1; $layout.RowCount=4
  foreach($height in @(84,30)) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) }
  [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
  [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',42)))
  $dashboard.Controls.Add($layout)

  $header=New-Object Windows.Forms.TableLayoutPanel
  $header.Dock='Fill'; $header.ColumnCount=3; $header.RowCount=2; $header.Margin=New-Object Windows.Forms.Padding(0)
  [void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
  [void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',270)))
  [void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',110)))
  [void]$header.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',40)))
  [void]$header.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',30)))
  $title=New-DashboardLabel '节点管理' 19 $true
  $subtitle=New-DashboardLabel 'VULTR  /  我的节点' 8
  $subtitle.ForeColor=[Drawing.Color]::FromArgb(138,145,156)
  $balance=New-DashboardLabel '—' 15 $true
  $balance.TextAlign='MiddleRight'
  $balanceGroup=New-Object Windows.Forms.TableLayoutPanel
  $balanceGroup.Dock='Fill'; $balanceGroup.ColumnCount=2; $balanceGroup.RowCount=1; $balanceGroup.Margin=New-Object Windows.Forms.Padding(0)
  [void]$balanceGroup.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',55)))
  [void]$balanceGroup.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',45)))
  $balanceCaption=New-DashboardLabel '账户预计剩余' 8
  $balanceCaption.TextAlign='MiddleRight'; $balanceCaption.ForeColor=$subtitle.ForeColor
  [void]$balanceGroup.Controls.Add($balanceCaption,0,0); [void]$balanceGroup.Controls.Add($balance,1,0)
  $balanceDetail=New-DashboardLabel '正在查询账户' 8
  $balanceDetail.TextAlign='MiddleRight'; $balanceDetail.ForeColor=$subtitle.ForeColor
  $balanceUpdated=New-Object Windows.Forms.Label
  $export=New-DashboardButton '导出配置' 94
  $export.Anchor='Right'; $export.Margin=New-Object Windows.Forms.Padding(16,0,0,0)
  [void]$header.Controls.Add($title,0,0); [void]$header.Controls.Add($subtitle,0,1)
  [void]$header.Controls.Add($balanceGroup,1,0); [void]$header.Controls.Add($balanceDetail,1,1)
  [void]$header.Controls.Add($export,2,0)
  [void]$layout.Controls.Add($header,0,0)

  $columns=New-Object Windows.Forms.TableLayoutPanel
  $columns.Dock='Fill'; $columns.Margin=New-Object Windows.Forms.Padding(0)
  $columns.Padding=New-Object Windows.Forms.Padding(16,0,16,0)
  Set-NodeColumns $columns
  $columnIndex=0
  foreach($caption in @('节点 / 地区','状态','已开时长','操作')){
    $label=New-DashboardLabel $caption 8
    $label.ForeColor=$subtitle.ForeColor
    [void]$columns.Controls.Add($label,$columnIndex,0); $columnIndex++
  }
  [void]$layout.Controls.Add($columns,0,1)
  $scroll=New-Object Windows.Forms.Panel
  $scroll.Dock='Fill'; $scroll.AutoScroll=$true; $scroll.Margin=New-Object Windows.Forms.Padding(0)
  $rows=New-Object Windows.Forms.TableLayoutPanel
  $rows.Dock='Top'; $rows.AutoSize=$true; $rows.ColumnCount=1; $rows.RowCount=@($NodeConfig.nodes).Count
  $rows.Margin=New-Object Windows.Forms.Padding(0)
  $scroll.Controls.Add($rows); [void]$layout.Controls.Add($scroll,0,2)

  $details=New-Object Windows.Forms.TableLayoutPanel
  $details.Dock='Fill'; $details.ColumnCount=1; $details.RowCount=3; $details.Margin=New-Object Windows.Forms.Padding(0)
  [void]$details.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',42)))
  [void]$details.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',54)))
  [void]$details.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
  [void]$layout.Controls.Add($details,0,3)
  $detailBar=New-Object Windows.Forms.FlowLayoutPanel
  $detailBar.Dock='Fill'; $detailBar.WrapContents=$false; $detailBar.Padding=New-Object Windows.Forms.Padding(0,8,0,0)
  $toggle=New-DashboardButton '日志与详情  ▾' 110
  $toggle.FlatAppearance.BorderSize=0; $toggle.BackColor=$dashboard.BackColor
  [void]$detailBar.Controls.Add($toggle)
  $tabs=@()
  $shared=[pscustomobject]@{selectedId=[string]$NodeConfig.nodes[0].id;expanded=$false;balance=$balance;balanceDetail=$balanceDetail;balanceUpdated=$balanceUpdated}
  foreach($entry in $NodeConfig.nodes){
    $tab=New-DashboardButton $entry.name 120
    $tab.AutoSize=$true; $tab.FlatAppearance.BorderSize=0; $tab.BackColor=$dashboard.BackColor
    $tab.Tag=[string]$entry.id
    $tab.Add_Click({$shared.selectedId=[string]$this.Tag})
    $tabs+=$tab; [void]$detailBar.Controls.Add($tab)
  }
  $clear=New-DashboardButton '清空' 52
  $clear.FlatAppearance.BorderSize=0; $clear.BackColor=$dashboard.BackColor
  [void]$detailBar.Controls.Add($clear)
  [void]$details.Controls.Add($detailBar,0,0)
  $detailText=New-DashboardLabel '' 8
  $detailText.ForeColor=[Drawing.Color]::FromArgb(114,123,137)
  [void]$details.Controls.Add($detailText,0,1)
  $logHost=New-Object Windows.Forms.Panel
  $logHost.Dock='Fill'; $logHost.Margin=New-Object Windows.Forms.Padding(0)
  [void]$details.Controls.Add($logHost,0,2)
  $detailText.Visible=$false; $logHost.Visible=$false; $clear.Visible=$false

  $modules=@(); $viewTimer=New-Object Windows.Forms.Timer; $viewTimer.Interval=150
  $accountTip=New-Object Windows.Forms.ToolTip
  $balance.Add_MouseEnter({$accountTip.SetToolTip($balance,$balanceUpdated.Text)})
  $view=[pscustomobject]@{expanded=$false;selectedId='';compactHeight=0}
  $refreshView={
    foreach($module in $modules){ & $module { Update-NodeRow } }
    if($view.expanded -ne $shared.expanded){
      if($shared.expanded){
        $view.compactHeight=$dashboard.ClientSize.Height
        $layout.RowStyles[3].Height=260
        $maximum=[Windows.Forms.Screen]::FromControl($dashboard).WorkingArea.Height-80
        $dashboard.ClientSize=New-Object Drawing.Size($dashboard.ClientSize.Width,[Math]::Min($maximum,$view.compactHeight+218))
      } else {
        $layout.RowStyles[3].Height=42
        $dashboard.ClientSize=New-Object Drawing.Size($dashboard.ClientSize.Width,$view.compactHeight)
      }
      $detailText.Visible=$shared.expanded; $logHost.Visible=$shared.expanded; $clear.Visible=$shared.expanded
      $toggle.Text=if($shared.expanded){'日志与详情  ▴'}else{'日志与详情  ▾'}
      $view.expanded=$shared.expanded
    }
    $selected=@($modules|Where-Object { (& $_ {$script:selectedNode.id}) -eq $shared.selectedId })[0]
    if($selected){
      $data=& $selected { [pscustomobject]@{log=$log;id=$lblId.Text;ip=$lblIp.Text;dns=$lblDns.Text;port=$lblPort.Text;created=$lblCreated.Text;status=$banner.Text} }
      if($view.selectedId -ne $shared.selectedId){
        $logHost.Controls.Clear(); $logHost.Controls.Add($data.log)
        $view.selectedId=$shared.selectedId
      }
      $detailText.Text="IP  $($data.ip)     443  $($data.port)`r`nDNS  $($data.dns)`r`n实例  $($data.id)     创建于  $($data.created)"
    }
    foreach($tab in $tabs){
      $tab.ForeColor=if($tab.Tag -eq $shared.selectedId){[Drawing.Color]::FromArgb(51,100,190)}else{[Drawing.Color]::FromArgb(138,145,156)}
      $tab.Visible=$shared.expanded
    }
    $idle=@($modules|Where-Object {-not (& $_ {Get-NodeBusy})})
    $exporting=@($modules|Where-Object {& $_ {$script:busy -and $script:cur -eq 'export'}})
    $export.Enabled=$idle.Count -gt 0 -and $exporting.Count -eq 0
  }
  $toggle.Add_Click({$shared.expanded=-not $shared.expanded; & $refreshView})
  $clear.Add_Click({
    $selected=@($modules|Where-Object {(& $_ {$script:selectedNode.id}) -eq $shared.selectedId})[0]
    if($selected){& $selected {$log.Clear()}}
  })
  $export.Add_Click({
    $target=@($modules|Where-Object {-not (& $_ {Get-NodeBusy})})[0]
    if($target){
      $shared.selectedId=& $target {$script:selectedNode.id}; $shared.expanded=$true
      & $target {Invoke-Action 'export'}; & $refreshView
    }
  })
  try {
    foreach($entry in $NodeConfig.nodes){
      if(@($NodeConfig.nodes|Where-Object {$_.id -eq $entry.id}).Count -ne 1){throw '节点 ID 重复。'}
      $module=New-Module -Name ('NodeRow-'+[guid]::NewGuid().ToString('N')) -ArgumentList (Join-Path $Dir 'vultr-node-gui.ps1'),$entry.id,$shared -ScriptBlock {
        param($PanelPath,$NodeId,$SharedControls)
        . $PanelPath -Panel -Node $NodeId -Shared $SharedControls
        Export-ModuleMember -Function Get-NodePanel,Initialize-NodePanel,Close-NodePanel,Get-NodeBusy
      }
      $modules+=$module
      [void]$rows.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',88)))
      [void]$rows.Controls.Add((& $module {Get-NodePanel}),0,($modules.Count-1))
    }
    $dashboard.Add_Shown({foreach($module in $modules){& $module {Initialize-NodePanel}}; & $refreshView; $viewTimer.Start()})
    $viewTimer.Add_Tick({& $refreshView})
    $dashboard.Add_FormClosing({
      param($sender,$eventArgs)
      if(@($modules|Where-Object {& $_ {Get-NodeBusy}}).Count){
        $answer=[Windows.Forms.MessageBox]::Show($dashboard,'当前还有操作在进行中。关闭窗口不会取消已提交的云端操作，确定要关闭吗？','确认关闭','YesNo','Question')
        if($answer -ne [Windows.Forms.DialogResult]::Yes){$eventArgs.Cancel=$true}
      }
    })
    [void]$dashboard.ShowDialog()
  } finally {
    $viewTimer.Dispose()
    foreach($module in $modules){& $module {Close-NodePanel}; Remove-Module $module -ErrorAction SilentlyContinue}
    $accountTip.Dispose(); $balanceUpdated.Dispose(); $dashboard.Dispose()
  }
}

function Initialize-NodeRow {
  $colOk=[Drawing.Color]::FromArgb(43,139,100)
  $colOff=[Drawing.Color]::FromArgb(138,145,156)
  $colWarn=[Drawing.Color]::FromArgb(177,123,35)
  $colBusy=[Drawing.Color]::FromArgb(51,100,190)
  $form=New-Object Windows.Forms.UserControl
  $form.Name=[string]$script:selectedNode.id; $form.Dock='Fill'; $form.Margin=New-Object Windows.Forms.Padding(0)
  $form.Padding=New-Object Windows.Forms.Padding(0,0,0,1)
  $form.BackColor=[Drawing.Color]::FromArgb(235,238,242)
  $row=New-Object Windows.Forms.TableLayoutPanel
  $row.Dock='Fill'; $row.BackColor=[Drawing.Color]::White; $row.Padding=New-Object Windows.Forms.Padding(16,12,16,12)
  Set-NodeColumns $row
  $identity=New-Object Windows.Forms.TableLayoutPanel
  $identity.Dock='Fill'; $identity.ColumnCount=1; $identity.RowCount=2; $identity.Margin=New-Object Windows.Forms.Padding(0)
  [void]$identity.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',50)))
  [void]$identity.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',50)))
  $name=New-DashboardLabel ([string]$script:selectedNode.name) 10 $true
  $plan=New-DashboardLabel ("$($script:selectedNode.region)  ·  $($script:selectedNode.plan)") 8
  $plan.ForeColor=$colOff
  [void]$identity.Controls.Add($name,0,0); [void]$identity.Controls.Add($plan,0,1)
  [void]$row.Controls.Add($identity,0,0)
  $stateLabel=New-DashboardLabel '正在读取…' 10
  [void]$row.Controls.Add($stateLabel,1,0)
  $lblAge=New-DashboardLabel '—' 9
  [void]$row.Controls.Add($lblAge,2,0)
  $bar=New-Object Windows.Forms.FlowLayoutPanel
  $bar.Dock='Fill'; $bar.WrapContents=$false; $bar.Padding=New-Object Windows.Forms.Padding(0,16,0,0); $bar.Margin=New-Object Windows.Forms.Padding(0)
  $btnStart=New-DashboardButton '开启' 62
  $btnStart.BackColor=$colBusy; $btnStart.ForeColor=[Drawing.Color]::White; $btnStart.FlatAppearance.BorderSize=0
  $btnStop=New-DashboardButton '销毁' 62
  $btnStop.ForeColor=[Drawing.Color]::FromArgb(171,86,86)
  $btnRefresh=New-DashboardButton '刷新' 58
  $btnDetails=New-DashboardButton '详情' 46
  $btnDetails.FlatAppearance.BorderSize=0; $btnDetails.ForeColor=$colBusy
  $btnDetails.Add_Click({$Shared.selectedId=[string]$script:selectedNode.id; $Shared.expanded=$true})
  $bar.Controls.AddRange(@($btnStart,$btnStop,$btnRefresh,$btnDetails))
  [void]$row.Controls.Add($bar,3,0); $form.Controls.Add($row)
  # These fields retain the full status/details while the row shows a short summary.
  foreach($field in @('banner','lblId','lblIp','lblDns','lblPort','lblCreated','statusLabel')){
    Set-Variable -Name $field -Value (New-Object Windows.Forms.Label)
  }
  $banner.Text='正在读取状态'; $banner.BackColor=$colOff
  $btnClear=New-Object Windows.Forms.Button; $btnExport=New-Object Windows.Forms.Button
  $progress=New-Object Windows.Forms.ProgressBar
  $lblBalance=$Shared.balance; $lblBalanceDetail=$Shared.balanceDetail; $lblBalanceUpdated=$Shared.balanceUpdated
  $ageLabels=@($lblAge,$lblCreated); $balanceLabels=@()
  $log=New-Object Windows.Forms.TextBox
  $log.Multiline=$true; $log.ReadOnly=$true; $log.Dock='Fill'; $log.ScrollBars='Vertical'; $log.WordWrap=$true
  $log.BorderStyle='None'; $log.BackColor=[Drawing.Color]::FromArgb(240,242,245)
  $log.ForeColor=[Drawing.Color]::FromArgb(91,103,122); $log.Font=New-Object Drawing.Font('Consolas',9)
  $script:createdAtUtc=$null
}

function Update-NodeRow {
  $text=$banner.Text
  $stateLabel.ForeColor=$banner.BackColor
  $stateLabel.Text=switch -Regex ($text){
    '运行中，基础检查通过' {'● 运行中';break}
    '未创建 / 已销毁' {'○ 未创建';break}
    ' · 已销毁$' {'○ 已销毁';break}
    '查询失败|无法解析|不匹配' {'! 查询失败';break}
    '销毁请求|正在销毁|确认销毁|销毁结果' {'◌ 确认销毁中';break}
    '正在|读取' {'◌ 处理中…';break}
    default {'! 需要检查'}
  }
  if($script:busy -and $script:cur -ne 'status'){
    $stateLabel.Text=switch($script:cur){'start'{'◌ 正在创建…'}'stop'{'◌ 正在销毁…'}'export'{'◌ 导出中…'}}
    $stateLabel.ForeColor=$colBusy
  }
  $toolTip.SetToolTip($stateLabel,$banner.Text)
}
