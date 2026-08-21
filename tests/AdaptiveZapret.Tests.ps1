$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engineModule=Join-Path $root 'AdaptiveZapret.Engine.psm1'
$rulesFile=Join-Path $root 'data\rules.json'
$backup=$(if(Test-Path $rulesFile){Get-Content $rulesFile -Raw}else{$null})
try {
    Import-Module $engineModule -Force -DisableNameChecking
    Test-AdaptiveEngineSelf
    $ui=Get-Content -LiteralPath (Join-Path $root 'AdaptiveZapret.UI.ps1') -Raw
    if($ui -notmatch 'GetNewClosure'){throw 'UI event handler closure guard missing'}
    if($ui -notmatch 'Проверить и обновить'){throw 'Update UI missing'}
    $updater=Join-Path $root 'AdaptiveZapret.Updater.ps1'
    if(-not(Test-Path $updater)){throw 'Updater missing'}
    $updaterText=Get-Content $updater -Raw
    foreach($guard in @('Test-ReleaseSignature','Get-FileHash','Restore-ProgramBackup')){if($updaterText -notmatch $guard){throw "Updater guard missing: $guard"}}
    $caught=$false
    try { Add-AdaptiveRule -Process System -Domain example.org -Ip '' -Port 443 -Protocol TCP -Mode direct } catch { $caught=$true }
    if(-not $caught){throw 'Protected process guard failed'}
    Add-AdaptiveRule -Process AdaptiveZapretTest -Domain example.org -Ip 203.0.113.10 -Port 443 -Protocol TCP -Mode direct
    $row=@(Get-AdaptiveRules | Where-Object Process -eq AdaptiveZapretTest)
    if($row.Count -ne 1 -or $row[0].Mode -ne 'direct'){throw 'Rule roundtrip failed'}
    Remove-AdaptiveRule $row[0].Id
    if(@(Get-AdaptiveRules | Where-Object Process -eq AdaptiveZapretTest).Count){throw 'Rule removal failed'}
    Write-Host 'AdaptiveZapret tests: OK' -ForegroundColor Green
} finally {
    if($null -ne $backup){Set-Content -LiteralPath $rulesFile -Value $backup -Encoding UTF8}
}
