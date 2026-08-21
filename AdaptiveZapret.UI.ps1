$startupLog=Join-Path $PSScriptRoot 'data\ui-startup.log'
New-Item -ItemType Directory -Path (Split-Path $startupLog) -Force|Out-Null
Set-Content -LiteralPath $startupLog -Value ("{0} UI startup" -f [DateTime]::Now.ToString('s')) -Encoding UTF8
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'AdaptiveZapret.Core.psm1') -Force -DisableNameChecking

[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text='Adaptive Zapret';$form.Size=New-Object Drawing.Size(1080,720);$form.MinimumSize=New-Object Drawing.Size(900,620);$form.StartPosition='CenterScreen';$form.Font=New-Object Drawing.Font('Segoe UI',10)
$tabs=New-Object Windows.Forms.TabControl;$tabs.Dock='Fill';$form.Controls.Add($tabs)

function New-Page($parent,[string]$name){$p=New-Object Windows.Forms.TabPage;$p.Text=$name;$parent.TabPages.Add($p)|Out-Null;return $p}
function New-Button($parent,[string]$text,[int]$x,[int]$y,[int]$w,[scriptblock]$action){$b=New-Object Windows.Forms.Button;$b.Text=$text;$b.SetBounds($x,$y,$w,36);$handler={try{&$action}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Adaptive Zapret','OK','Error')|Out-Null}}.GetNewClosure();$b.Add_Click($handler);$parent.Controls.Add($b);return $b}
function New-ValueLabel($parent,[string]$title,[int]$x,[int]$y,[int]$w){$box=New-Object Windows.Forms.GroupBox;$box.Text=$title;$box.SetBounds($x,$y,$w,78);$label=New-Object Windows.Forms.Label;$label.SetBounds(12,30,$w-24,30);$label.Font=New-Object Drawing.Font('Segoe UI',12,[Drawing.FontStyle]::Bold);$box.Controls.Add($label);$parent.Controls.Add($box);return $label}
function Invoke-Captured([scriptblock]$Action){return (&$Action 6>&1|Out-String).Trim()}
function New-Grid{$g=New-Object Windows.Forms.DataGridView;$g.ReadOnly=$true;$g.AllowUserToAddRows=$false;$g.AllowUserToDeleteRows=$false;$g.SelectionMode='FullRowSelect';$g.MultiSelect=$false;$g.AutoSizeColumnsMode='DisplayedCells';$g.BackgroundColor=[Drawing.Color]::White;$g.BorderStyle='Fixed3D';return $g}
function Set-GridRows($grid,[array]$rows){
    $grid.SuspendLayout();try{$grid.DataSource=$null;$grid.Rows.Clear();$grid.Columns.Clear();if(-not $rows.Count){return};$columns=@($rows[0].PSObject.Properties.Name);foreach($name in $columns){[void]$grid.Columns.Add($name,$name)};foreach($item in $rows){$values=@();foreach($name in $columns){$values+=[string]$item.$name};[void]$grid.Rows.Add($values)}}finally{$grid.ResumeLayout()}
}
function Sync-LiveGrid($grid,[array]$rows){
    # Live view is refreshed frequently. Update existing cells instead of rebuilding
    # the whole DataGridView (recreating columns caused visible freezes on browsers).
    $columns=@('Process','Domain','DestinationIp','DestinationPort','Protocol','State','ObservedUtc')
    if($grid.Columns.Count -eq 0){foreach($name in $columns){[void]$grid.Columns.Add($name,$name)}}
    $selectedKey=$null
    if($grid.CurrentRow -and -not $grid.CurrentRow.IsNewRow){$selectedKey='{0}|{1}|{2}|{3}' -f $grid.CurrentRow.Cells['Process'].Value,$grid.CurrentRow.Cells['DestinationIp'].Value,$grid.CurrentRow.Cells['DestinationPort'].Value,$grid.CurrentRow.Cells['Protocol'].Value}
    $incoming=@{};foreach($item in @($rows)){$key='{0}|{1}|{2}|{3}' -f $item.Process,$item.DestinationIp,$item.DestinationPort,$item.Protocol;$incoming[$key]=$item}
    $existing=@{};foreach($row in @($grid.Rows)){if($row.IsNewRow){continue};$key='{0}|{1}|{2}|{3}' -f $row.Cells['Process'].Value,$row.Cells['DestinationIp'].Value,$row.Cells['DestinationPort'].Value,$row.Cells['Protocol'].Value;$existing[$key]=$row}
    $grid.SuspendLayout();try{
        foreach($key in @($existing.Keys)){if(-not $incoming.ContainsKey($key)){$grid.Rows.Remove($existing[$key]);$existing.Remove($key)}}
        foreach($key in @($incoming.Keys)){$item=$incoming[$key];$row=$existing[$key];if(-not $row){$index=$grid.Rows.Add();$row=$grid.Rows[$index]};foreach($name in $columns){$value=[string]$item.$name;if([string]$row.Cells[$name].Value -ne $value){$row.Cells[$name].Value=$value}};if($key -eq $selectedKey){$row.Selected=$true;$grid.CurrentCell=$row.Cells[0]}}
    }finally{$grid.ResumeLayout()}
}
function Get-SelectedRow($grid){if(-not $grid.CurrentRow -or $grid.CurrentRow.IsNewRow){throw 'Выберите подключение.'};$item=[ordered]@{};foreach($column in $grid.Columns){$item[$column.Name]=[string]$grid.CurrentRow.Cells[$column.Name].Value};return [pscustomobject]$item}
function Start-LearningFromGrid($grid){$r=Get-SelectedRow $grid;$spec="$($r.Process)|$($r.Domain)|$($r.DestinationIp)|$($r.DestinationPort)|$($r.Protocol)";$result=Invoke-Captured{InvokeAdaptiveLearn -Spec $spec};$tabs.SelectedTab=$learn;[Windows.Forms.MessageBox]::Show(($result+"`r`n`r`nСоединение перезапущено. Проверьте вход в сессию."),'Adaptive Zapret')|Out-Null}

# Главная
$dashboard=New-Page $tabs 'Главная'
$versionLabel=New-ValueLabel $dashboard 'Версия' 20 20 220
$collectorLabel=New-ValueLabel $dashboard 'Сбор трафика' 255 20 240
$sysmonLabel=New-ValueLabel $dashboard 'Sysmon' 510 20 220
$engineLabel=New-ValueLabel $dashboard 'winws' 745 20 285
$rulesLabel=New-ValueLabel $dashboard 'Правила' 20 115 220
$learningLabel=New-ValueLabel $dashboard 'Подбор' 255 115 240
$connectionsLabel=New-ValueLabel $dashboard 'Известные цели' 510 115 220
$adminLabel=New-ValueLabel $dashboard 'Права' 745 115 285
$dashboardMessage=New-Object Windows.Forms.Label;$dashboardMessage.SetBounds(25,220,990,55);$dashboardMessage.AutoSize=$false;$dashboardMessage.ForeColor=[Drawing.Color]::DimGray;$dashboard.Controls.Add($dashboardMessage)
$refreshStatus={
    $s=InvokeAdaptiveStatusInfo
    $versionLabel.Text=$s.Version;$collectorLabel.Text=$(if($s.Collector){"Работает (PID $($s.CollectorPid))"}else{'Остановлен'});$collectorLabel.ForeColor=$(if($s.Collector){[Drawing.Color]::ForestGreen}else{[Drawing.Color]::DarkOrange})
    $sysmonLabel.Text=$(if($s.Sysmon){'Полный TCP/UDP'}else{'Только TCP'});$engineLabel.Text=$s.Winws;$rulesLabel.Text=[string]$s.Rules;$learningLabel.Text=$(if($s.Learning){'Активен'}else{'Нет'});$connectionsLabel.Text=[string]$s.Connections;$adminLabel.Text=$(if($s.Administrator){'Администратор'}else{'Недостаточно прав'})
    $dashboardMessage.Text=$(if(-not $s.Sysmon){'Для полноценного сбора UDP выполните «Полная настройка».'}elseif(-not $s.Collector){'Сбор трафика остановлен. Нажмите «Сбор: старт».'}else{'Система готова. Живые подключения отображаются на вкладке «Приложения».'})
}
New-Button $dashboard 'Обновить состояние' 20 295 170 $refreshStatus|Out-Null
New-Button $dashboard 'Сбор: старт' 205 295 140 {InvokeAdaptiveStart;&$refreshStatus}|Out-Null
New-Button $dashboard 'Сбор: стоп' 360 295 140 {InvokeAdaptiveStop;&$refreshStatus}|Out-Null
New-Button $dashboard 'Применить правила' 515 295 170 {InvokeAdaptiveApply;&$refreshStatus}|Out-Null
New-Button $dashboard 'Всё напрямую' 700 295 150 {InvokeAdaptiveDirect;&$refreshStatus}|Out-Null
New-Button $dashboard 'Полная настройка' 865 295 165 {InvokeAdaptiveSetup;&$refreshStatus}|Out-Null

# Приложения: живые подключения и история
$traffic=New-Page $tabs 'Приложения';$appTabs=New-Object Windows.Forms.TabControl;$appTabs.Dock='Fill';$traffic.Controls.Add($appTabs)
$livePage=New-Page $appTabs 'Сейчас'
$liveSplit=New-Object Windows.Forms.SplitContainer;$liveSplit.Dock='Fill';$liveSplit.Orientation='Vertical';$liveSplit.SplitterDistance=220;$liveSplit.FixedPanel='Panel1';$liveSplit.Panel1MinSize=170;$livePage.Controls.Add($liveSplit)
$liveApps=New-Object Windows.Forms.ListBox;$liveApps.Dock='Fill';$liveApps.IntegralHeight=$false;$liveApps.Font=New-Object Drawing.Font('Segoe UI',10);$liveSplit.Panel1.Controls.Add($liveApps)
$liveGrid=New-Grid;$liveGrid.Dock='Fill';$liveSplit.Panel2.Controls.Add($liveGrid)
$liveTop=New-Object Windows.Forms.Panel;$liveTop.Dock='Top';$liveTop.Height=54;$livePage.Controls.Add($liveTop);$liveTop.BringToFront()
$liveStatus=New-Object Windows.Forms.Label;$liveStatus.SetBounds(875,18,170,24);$liveTop.Controls.Add($liveStatus)
$script:captureActive=$false;$script:captureProcess='';$script:captureBaseline=@{};$script:captureRows=@{};$script:liveRows=@();$script:liveProcessMap=@{};$script:liveGroupsFingerprint=''
$showLiveSelection={
    $selected=[string]$liveApps.SelectedItem;$process=$(if($selected -and $script:liveProcessMap.ContainsKey($selected)){$script:liveProcessMap[$selected]}else{''})
    $visible=$(if($process){@($script:liveRows|Where-Object{$_.Process -ieq $process})}else{@($script:liveRows)})
    Sync-LiveGrid $liveGrid $visible
}
$liveApps.Add_SelectedIndexChanged({&$showLiveSelection})
$refreshLive={try{
    $script:liveRows=@(InvokeAdaptiveLiveConnections)
    $groups=@($script:liveRows|Group-Object Process|Sort-Object Name);$fingerprint=($groups|ForEach-Object{'{0}:{1}' -f $_.Name,$_.Count}) -join '|'
    if($fingerprint -ne $script:liveGroupsFingerprint){
        $selectedProcess='';$oldSelected=[string]$liveApps.SelectedItem;if($oldSelected -and $script:liveProcessMap.ContainsKey($oldSelected)){$selectedProcess=$script:liveProcessMap[$oldSelected]}
        $liveApps.BeginUpdate();try{$liveApps.Items.Clear();$script:liveProcessMap=@{};$allLabel='Все приложения ({0})' -f $script:liveRows.Count;[void]$liveApps.Items.Add($allLabel);$script:liveProcessMap[$allLabel]='';foreach($group in $groups){$label='{0} ({1})' -f $group.Name,$group.Count;[void]$liveApps.Items.Add($label);$script:liveProcessMap[$label]=[string]$group.Name}}finally{$liveApps.EndUpdate()}
        $target=0;if($selectedProcess){for($i=1;$i-lt$liveApps.Items.Count;$i++){if($script:liveProcessMap[[string]$liveApps.Items[$i]] -ieq $selectedProcess){$target=$i;break}}};$liveApps.SelectedIndex=$target;$script:liveGroupsFingerprint=$fingerprint
    }
    &$showLiveSelection
    if($script:captureActive){foreach($row in $script:liveRows){if($row.Process -ieq $script:captureProcess){$key='{0}|{1}|{2}|{3}' -f $row.Process,$row.DestinationIp,$row.DestinationPort,$row.Protocol;if(-not $script:captureBaseline.ContainsKey($key)){$script:captureRows[$key]=$row}}}}
    $suffix=$(if($script:captureActive){" · запись: $script:captureProcess ($($script:captureRows.Count))"}else{''});$liveStatus.Text=('Активных/недавних: {0} · {1}{2}' -f $script:liveRows.Count,(Get-Date -Format 'HH:mm:ss'),$suffix)
}catch{$liveStatus.Text=$_.Exception.Message}}
New-Button $liveTop 'Обновить сейчас' 10 8 155 $refreshLive|Out-Null
New-Button $liveTop 'Подобрать zapret' 180 8 170 {Start-LearningFromGrid $liveGrid}|Out-Null
New-Button $liveTop 'Direct' 365 8 90 {$r=Get-SelectedRow $liveGrid;InvokeAdaptiveRuleCreate -Process $r.Process -Domain $r.Domain -Ip $r.DestinationIp -Port([int]$r.DestinationPort)-Protocol $r.Protocol -Mode direct}|Out-Null
New-Button $liveTop 'Block' 470 8 90 {$r=Get-SelectedRow $liveGrid;InvokeAdaptiveRuleCreate -Process $r.Process -Domain $r.Domain -Ip $r.DestinationIp -Port([int]$r.DestinationPort)-Protocol $r.Protocol -Mode block}|Out-Null
New-Button $liveTop 'Запись действия' 570 8 150 {$r=Get-SelectedRow $liveGrid;$script:captureProcess=$r.Process;$script:captureBaseline=@{};$script:captureRows=@{};foreach($row in @($script:liveRows)){if($row.Process -ieq $script:captureProcess){$script:captureBaseline['{0}|{1}|{2}|{3}' -f $row.Process,$row.DestinationIp,$row.DestinationPort,$row.Protocol]=$true}};$script:captureActive=$true;$liveStatus.Text="Запись $($script:captureProcess): обновите нужную вкладку"}|Out-Null
New-Button $liveTop 'Стоп записи' 735 8 130 {$script:captureActive=$false;$captured=@($script:captureRows.Values);if($captured.Count){Sync-LiveGrid $liveGrid $captured;$liveStatus.Text="Новых: $($captured.Count)"}else{$liveStatus.Text='Новых соединений нет'}}|Out-Null

$historyPage=New-Page $appTabs 'История';$historyGrid=New-Grid;$historyGrid.Dock='Fill';$historyPage.Controls.Add($historyGrid)
$historyTop=New-Object Windows.Forms.Panel;$historyTop.Dock='Top';$historyTop.Height=54;$historyPage.Controls.Add($historyTop);$historyTop.BringToFront()
$historyStatus=New-Object Windows.Forms.Label;$historyStatus.SetBounds(385,18,580,24);$historyTop.Controls.Add($historyStatus)
$refreshHistory={InvokeAdaptiveApps;$path=Join-Path $PSScriptRoot 'data\apps-map.csv';$rows=$(if(Test-Path $path){@(Import-Csv $path)}else{@()});Set-GridRows $historyGrid $rows;$historyStatus.Text=('История целей: {0} · {1}' -f $rows.Count,(Get-Date -Format 'HH:mm:ss'))}
New-Button $historyTop 'Обновить историю' 10 8 165 $refreshHistory|Out-Null
New-Button $historyTop 'Подобрать zapret' 190 8 175 {Start-LearningFromGrid $historyGrid}|Out-Null

# Правила и подбор
$rulesTab=New-Page $tabs 'Правила';$rulesGrid=New-Grid;$rulesGrid.Dock='Fill';$rulesGrid.AutoSizeColumnsMode='Fill';$rulesTab.Controls.Add($rulesGrid)
$rulesTop=New-Object Windows.Forms.Panel;$rulesTop.Dock='Top';$rulesTop.Height=54;$rulesTab.Controls.Add($rulesTop);$rulesTop.BringToFront();$loadRules={Set-GridRows $rulesGrid @(InvokeAdaptiveRuleList)}
New-Button $rulesTop 'Обновить' 10 8 120 $loadRules|Out-Null
New-Button $rulesTop 'Удалить выбранное' 145 8 175 {$r=Get-SelectedRow $rulesGrid;InvokeAdaptiveRuleRemove $r.Id;&$loadRules}|Out-Null
New-Button $rulesTop 'Применить правила' 335 8 170 {InvokeAdaptiveApply}|Out-Null
New-Button $rulesTop 'Экспорт AUTO' 520 8 150 {InvokeAdaptiveExport}|Out-Null
New-Button $rulesTop 'Автозапуск' 685 8 130 {InvokeAdaptiveAutoStartOn}|Out-Null

$learn=New-Page $tabs 'Подбор';$learnText=New-Object Windows.Forms.Label;$learnText.SetBounds(25,25,980,115);$learnText.AutoSize=$false;$learnText.Text='При запуске профиля выбранное соединение автоматически закрывается, через 5 секунд программа проверяет повторное подключение. Проверьте вход в игровую сессию и отметьте результат.';$learn.Controls.Add($learnText)
New-Button $learn 'Работает' 25 165 180 {[Windows.Forms.MessageBox]::Show((Invoke-Captured{InvokeAdaptiveTest pass}),'Adaptive Zapret')|Out-Null}|Out-Null
New-Button $learn 'Не работает — следующая' 220 165 230 {[Windows.Forms.MessageBox]::Show((Invoke-Captured{InvokeAdaptiveTest fail}),'Adaptive Zapret')|Out-Null}|Out-Null
New-Button $learn 'Пропустить профиль' 465 165 200 {[Windows.Forms.MessageBox]::Show((Invoke-Captured{InvokeAdaptiveTest skip}),'Adaptive Zapret')|Out-Null}|Out-Null
New-Button $learn 'Отмена и direct' 680 165 180 {InvokeAdaptiveDirect}|Out-Null

# Дополнительно: диагностика и обновления
$extra=New-Page $tabs 'Дополнительно';$extraTabs=New-Object Windows.Forms.TabControl;$extraTabs.Dock='Fill';$extra.Controls.Add($extraTabs)
$diag=New-Page $extraTabs 'Диагностика';$diagBox=New-Object Windows.Forms.TextBox;$diagBox.Multiline=$true;$diagBox.ReadOnly=$true;$diagBox.ScrollBars='Both';$diagBox.SetBounds(20,70,990,500);$diag.Controls.Add($diagBox)
New-Button $diag 'Self-test' 20 20 140 {$diagBox.Text=Invoke-Captured{InvokeAdaptiveSelfTest}}|Out-Null
New-Button $diag 'Открыть папку данных' 175 20 190 {Start-Process explorer.exe (Join-Path $PSScriptRoot 'data')}|Out-Null
$update=New-Page $extraTabs 'Обновления';$updateInfo=New-Object Windows.Forms.Label;$updateInfo.SetBounds(25,25,950,70);$updateInfo.AutoSize=$false;$update.Controls.Add($updateInfo);$updateUrl=New-Object Windows.Forms.TextBox;$updateUrl.SetBounds(25,110,750,28);$update.Controls.Add($updateUrl)
New-Button $update 'Сохранить канал' 790 105 180 {InvokeAdaptiveUpdateConfigure $updateUrl.Text;[Windows.Forms.MessageBox]::Show('Канал обновлений сохранён.')|Out-Null}|Out-Null
New-Button $update 'Проверить и обновить' 25 165 220 {InvokeAdaptiveUpdateConfigure $updateUrl.Text;InvokeAdaptiveUpdate;$form.Close()}|Out-Null
New-Button $update 'Установить ZIP вручную' 260 165 220 {$dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='Adaptive Zapret ZIP (*.zip)|*.zip';if($dialog.ShowDialog() -eq 'OK'){InvokeAdaptiveUpdate -PackagePath $dialog.FileName;$form.Close()}}|Out-Null

$liveRefreshBusy=$false
$liveTimer=New-Object Windows.Forms.Timer;$liveTimer.Interval=1000;$liveTimer.Add_Tick({if(-not $liveRefreshBusy -and $tabs.SelectedTab -eq $traffic -and $appTabs.SelectedTab -eq $livePage){$liveRefreshBusy=$true;try{&$refreshLive}finally{$liveRefreshBusy=$false}}})
$form.Add_Shown({try{&$refreshStatus;&$loadRules;&$refreshLive;$updateState=InvokeAdaptiveUpdateStatus;$updateInfo.Text=("Установлена версия: {0}`r`nКанал обновлений:" -f $updateState.CurrentVersion);$updateUrl.Text=$updateState.ManifestUrl;$liveTimer.Start();Add-Content $startupLog ("{0} UI ready" -f [DateTime]::Now.ToString('s')) -Encoding UTF8}catch{$details=$_|Out-String;Add-Content $startupLog $details -Encoding UTF8;[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Adaptive Zapret — ошибка запуска','OK','Error')|Out-Null}})
$form.Add_FormClosed({$liveTimer.Stop();$liveTimer.Dispose()})
[void]$form.ShowDialog()
