$startupLog=Join-Path $PSScriptRoot 'data\ui-startup.log'
New-Item -ItemType Directory -Path (Split-Path $startupLog) -Force | Out-Null
Set-Content -LiteralPath $startupLog -Value ("{0} UI startup" -f [DateTime]::Now.ToString('s')) -Encoding UTF8

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'AdaptiveZapret.Core.psm1') -Force -DisableNameChecking

[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text='Adaptive Zapret'
$form.Size=New-Object Drawing.Size(980,680)
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10)

$tabs=New-Object Windows.Forms.TabControl
$tabs.Dock='Fill'
$form.Controls.Add($tabs)

function New-Tab([string]$Name){$tab=New-Object Windows.Forms.TabPage;$tab.Text=$Name;$tabs.TabPages.Add($tab)|Out-Null;return $tab}
function New-Button($parent,[string]$text,[int]$x,[int]$y,[int]$w,[scriptblock]$action){$b=New-Object Windows.Forms.Button;$b.Text=$text;$b.SetBounds($x,$y,$w,36);$handler={try{&$action}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Adaptive Zapret','OK','Error')|Out-Null}}.GetNewClosure();$b.Add_Click($handler);$parent.Controls.Add($b);return $b}
function Invoke-Captured([scriptblock]$Action){return (&$Action 6>&1 | Out-String).Trim()}
function Set-AppsGrid {
    $path=Join-Path $PSScriptRoot 'data\apps-map.csv'
    $appsGrid.SuspendLayout()
    try {
        $appsGrid.DataSource=$null
        $appsGrid.Rows.Clear()
        $appsGrid.Columns.Clear()
        if(-not (Test-Path -LiteralPath $path)){$appsStatus.Text='Карта ещё не создана. Запустите сбор трафика.';return}
        $rows=@(Import-Csv -LiteralPath $path)
        if($rows.Count -eq 0){$appsStatus.Text='Новых внешних соединений пока нет.';return}
        $columns=@($rows[0].PSObject.Properties.Name)
        foreach($name in $columns){[void]$appsGrid.Columns.Add($name,$name)}
        foreach($item in $rows){
            $values=@();foreach($name in $columns){$values += [string]$item.$name}
            [void]$appsGrid.Rows.Add($values)
        }
        $appsStatus.Text=('Показано подключений: {0}. Обновлено: {1}' -f $rows.Count,(Get-Date -Format 'HH:mm:ss'))
    } finally {$appsGrid.ResumeLayout()}
}
function Get-SelectedAppRow {
    if(-not $appsGrid.CurrentRow -or $appsGrid.CurrentRow.IsNewRow){throw 'Выберите строку.'}
    $item=[ordered]@{}
    foreach($column in $appsGrid.Columns){$item[$column.Name]=[string]$appsGrid.CurrentRow.Cells[$column.Name].Value}
    return [pscustomobject]$item
}

$dashboard=New-Tab 'Главная'
$statusBox=New-Object Windows.Forms.TextBox;$statusBox.Multiline=$true;$statusBox.ReadOnly=$true;$statusBox.ScrollBars='Vertical';$statusBox.SetBounds(20,70,915,485);$dashboard.Controls.Add($statusBox)
$refresh={ $statusBox.Text=Invoke-Captured { InvokeAdaptiveStatus } }
New-Button $dashboard 'Обновить' 20 20 130 $refresh | Out-Null
New-Button $dashboard 'Сбор: старт' 165 20 130 {InvokeAdaptiveStart;&$refresh} | Out-Null
New-Button $dashboard 'Сбор: стоп' 310 20 130 {InvokeAdaptiveStop;&$refresh} | Out-Null
New-Button $dashboard 'Применить' 455 20 130 {InvokeAdaptiveApply;&$refresh} | Out-Null
New-Button $dashboard 'Всё напрямую' 600 20 150 {InvokeAdaptiveDirect;&$refresh} | Out-Null
New-Button $dashboard 'Полная настройка' 765 20 170 {InvokeAdaptiveSetup;&$refresh} | Out-Null

$update=New-Tab 'Обновления'
$updateInfo=New-Object Windows.Forms.Label;$updateInfo.SetBounds(25,25,880,70);$updateInfo.AutoSize=$false;$update.Controls.Add($updateInfo)
$updateUrl=New-Object Windows.Forms.TextBox;$updateUrl.SetBounds(25,110,700,28);$update.Controls.Add($updateUrl)
New-Button $update 'Сохранить канал' 740 105 170 {InvokeAdaptiveUpdateConfigure $updateUrl.Text;[Windows.Forms.MessageBox]::Show('Канал обновлений сохранён.')|Out-Null} | Out-Null
New-Button $update 'Проверить и обновить' 25 165 220 {
    if([string]::IsNullOrWhiteSpace($updateUrl.Text)){throw 'Сначала укажите HTTPS-адрес канала обновлений.'}
    InvokeAdaptiveUpdateConfigure $updateUrl.Text
    InvokeAdaptiveUpdate
    $form.Close()
} | Out-Null
New-Button $update 'Установить ZIP вручную' 260 165 220 {
    $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='Adaptive Zapret ZIP (*.zip)|*.zip'
    if($dialog.ShowDialog() -eq 'OK'){InvokeAdaptiveUpdate -PackagePath $dialog.FileName;$form.Close()}
} | Out-Null
$updateNote=New-Object Windows.Forms.Label;$updateNote.SetBounds(25,225,880,180);$updateNote.AutoSize=$false;$updateNote.Text='Обновление проверяет цифровую подпись канала и SHA-256 архива, делает резервную копию, не заменяет data, config и engine, а после установки перезапускает приложение. При ошибке выполняется автоматический откат.';$update.Controls.Add($updateNote)

$traffic=New-Tab 'Приложения'
$appsGrid=New-Object Windows.Forms.DataGridView;$appsGrid.Dock='Fill';$appsGrid.ReadOnly=$true;$appsGrid.AllowUserToAddRows=$false;$appsGrid.AllowUserToDeleteRows=$false;$appsGrid.SelectionMode='FullRowSelect';$appsGrid.MultiSelect=$false;$appsGrid.AutoSizeColumnsMode='DisplayedCells';$traffic.Controls.Add($appsGrid)
$trafficTop=New-Object Windows.Forms.Panel;$trafficTop.Dock='Top';$trafficTop.Height=52;$traffic.Controls.Add($trafficTop);$trafficTop.BringToFront()
$appsStatus=New-Object Windows.Forms.Label;$appsStatus.AutoSize=$true;$appsStatus.SetBounds(575,18,380,24);$appsStatus.Text='Загрузка карты...';$trafficTop.Controls.Add($appsStatus)
New-Button $trafficTop 'Обновить карту' 10 8 150 {InvokeAdaptiveApps;Set-AppsGrid} | Out-Null
New-Button $trafficTop 'Подобрать zapret' 175 8 165 {
    $r=Get-SelectedAppRow
    $spec="$($r.Process)|$($r.Domain)|$($r.DestinationIp)|$($r.DestinationPort)|$($r.Protocol)"
    InvokeAdaptiveLearn -Spec $spec
    [Windows.Forms.MessageBox]::Show('Профиль запущен. Проверьте подключение и откройте вкладку Подбор.')|Out-Null
} | Out-Null
New-Button $trafficTop 'Direct' 350 8 100 {
    $r=Get-SelectedAppRow
    InvokeAdaptiveRuleCreate -Process $r.Process -Domain $r.Domain -Ip $r.DestinationIp -Port ([int]$r.DestinationPort) -Protocol $r.Protocol -Mode direct
} | Out-Null
New-Button $trafficTop 'Block' 460 8 100 {
    $r=Get-SelectedAppRow
    InvokeAdaptiveRuleCreate -Process $r.Process -Domain $r.Domain -Ip $r.DestinationIp -Port ([int]$r.DestinationPort) -Protocol $r.Protocol -Mode block
} | Out-Null

$rulesTab=New-Tab 'Правила'
$rulesGrid=New-Object Windows.Forms.DataGridView;$rulesGrid.Dock='Fill';$rulesGrid.ReadOnly=$true;$rulesGrid.AutoSizeColumnsMode='Fill';$rulesTab.Controls.Add($rulesGrid)
$rulesTop=New-Object Windows.Forms.Panel;$rulesTop.Dock='Top';$rulesTop.Height=52;$rulesTab.Controls.Add($rulesTop);$rulesTop.BringToFront()
$loadRules={ $rulesGrid.DataSource=@(InvokeAdaptiveRuleList) }
New-Button $rulesTop 'Обновить' 10 8 120 $loadRules | Out-Null
New-Button $rulesTop 'Удалить выбранное' 145 8 175 {if(-not $rulesGrid.CurrentRow){throw 'Выберите правило.'};InvokeAdaptiveRuleRemove $rulesGrid.CurrentRow.DataBoundItem.Id;&$loadRules} | Out-Null
New-Button $rulesTop 'Применить правила' 335 8 170 {InvokeAdaptiveApply} | Out-Null
New-Button $rulesTop 'Экспорт AUTO' 520 8 150 {InvokeAdaptiveExport} | Out-Null
New-Button $rulesTop 'Автозапуск' 685 8 130 {InvokeAdaptiveAutoStartOn} | Out-Null

$learn=New-Tab 'Подбор'
$learnText=New-Object Windows.Forms.Label;$learnText.SetBounds(25,25,900,120);$learnText.Text='После запуска подбора проверьте вход в игровую сессию. Результат остаётся на компьютере; отправлять журналы не нужно.';$learn.Controls.Add($learnText)
New-Button $learn 'Работает' 25 165 180 {[Windows.Forms.MessageBox]::Show((Invoke-Captured {InvokeAdaptiveTest pass}),'Adaptive Zapret')|Out-Null} | Out-Null
New-Button $learn 'Не работает — следующая' 220 165 230 {InvokeAdaptiveTest fail} | Out-Null
New-Button $learn 'Пропустить профиль' 465 165 200 {InvokeAdaptiveTest skip} | Out-Null
New-Button $learn 'Отмена и direct' 680 165 180 {InvokeAdaptiveDirect} | Out-Null

$diag=New-Tab 'Диагностика'
$diagBox=New-Object Windows.Forms.TextBox;$diagBox.Multiline=$true;$diagBox.ReadOnly=$true;$diagBox.ScrollBars='Both';$diagBox.SetBounds(20,70,915,485);$diag.Controls.Add($diagBox)
New-Button $diag 'Self-test' 20 20 140 {$diagBox.Text=Invoke-Captured {InvokeAdaptiveSelfTest}} | Out-Null
New-Button $diag 'Открыть папку данных' 175 20 190 {Start-Process explorer.exe (Join-Path $PSScriptRoot 'data')} | Out-Null

$form.Add_Shown({
    try {
        $statusBox.Text='Загрузка состояния...'
        [Windows.Forms.Application]::DoEvents()
        &$refresh
        &$loadRules
        Set-AppsGrid
        $updateState=InvokeAdaptiveUpdateStatus
        $updateInfo.Text=("Установлена версия: {0}`r`nКанал обновлений:" -f $updateState.CurrentVersion)
        $updateUrl.Text=$updateState.ManifestUrl
        Add-Content -LiteralPath $startupLog -Value ("{0} UI ready" -f [DateTime]::Now.ToString('s')) -Encoding UTF8
    } catch {
        $details=$_ | Out-String
        Add-Content -LiteralPath $startupLog -Value $details -Encoding UTF8
        $statusBox.Text=$details
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Adaptive Zapret — ошибка запуска','OK','Error')|Out-Null
    }
})
[void]$form.ShowDialog()
