[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('monitor', 'summary', 'status', 'start', 'stop', 'apps', 'focus', 'engine-install', 'engine-set', 'sysmon-install', 'setup', 'rules', 'rule-add', 'rule-remove', 'apply', 'direct', 'learn', 'test', 'export', 'selftest', 'ui', 'autostart-on', 'autostart-off', 'boot', 'update')]
    [string]$Command = 'status'
    ,
    [Parameter(Position = 1)]
    [string]$ProcessName
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'AdaptiveZapret.Core.psm1'

if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Не найден модуль: $modulePath. Распакуйте архив целиком."
}

Import-Module -Name $modulePath -Force -DisableNameChecking

switch ($Command) {
    'monitor' { InvokeAdaptiveMonitor }
    'summary' { InvokeAdaptiveSummary }
    'status' { InvokeAdaptiveStatus }
    'start' { InvokeAdaptiveStart }
    'stop' { InvokeAdaptiveStop }
    'apps' { InvokeAdaptiveApps }
    'focus' {
        if ([string]::IsNullOrWhiteSpace($ProcessName)) { throw 'Укажите имя процесса, например: focus BrokenArrow' }
        InvokeAdaptiveFocus -ProcessName $ProcessName
    }
    'engine-install' { InvokeAdaptiveEngineInstall }
    'sysmon-install' { InvokeAdaptiveSysmonInstall }
    'setup' { InvokeAdaptiveSetup }
    'engine-set' { if (-not $ProcessName) { throw 'Укажите папку с winws/Flowseal.' }; InvokeAdaptiveEngineSet -Path $ProcessName }
    'rules' { InvokeAdaptiveRules }
    'rule-add' { InvokeAdaptiveRuleAdd -Spec $ProcessName }
    'rule-remove' { InvokeAdaptiveRuleRemove -Id $ProcessName }
    'apply' { InvokeAdaptiveApply }
    'direct' { InvokeAdaptiveDirect }
    'learn' { if (-not $ProcessName) { throw 'Укажите имя процесса.' }; InvokeAdaptiveLearn -ProcessName $ProcessName }
    'test' { if ($ProcessName -notin @('pass','fail','skip')) { throw 'Используйте test pass, test fail или test skip.' }; InvokeAdaptiveTest -Result $ProcessName }
    'export' { InvokeAdaptiveExport }
    'selftest' { InvokeAdaptiveSelfTest }
    'ui' { & (Join-Path $PSScriptRoot 'AdaptiveZapret.UI.ps1') }
    'autostart-on' { InvokeAdaptiveAutoStartOn }
    'autostart-off' { InvokeAdaptiveAutoStartOff }
    'boot' { InvokeAdaptiveBoot }
    'update' { InvokeAdaptiveUpdate -PackagePath $ProcessName }
}
