param()

$ErrorActionPreference = 'Stop'
$launchLog = Join-Path $PSScriptRoot 'AdaptiveZapret-startup.log'

try {
    Set-Content -LiteralPath $launchLog -Encoding UTF8 -Value @(
        ('{0} Launcher started' -f [DateTime]::Now.ToString('s'))
        ('PowerShell: {0}' -f $PSVersionTable.PSVersion)
        ('ApartmentState: {0}' -f [Threading.Thread]::CurrentThread.ApartmentState)
        ('Directory: {0}' -f $PSScriptRoot)
    )

    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'Интерфейс должен быть запущен в режиме STA.'
    }

    $uiPath = Join-Path $PSScriptRoot 'AdaptiveZapret.UI.ps1'
    if (-not (Test-Path -LiteralPath $uiPath)) {
        throw "Не найден файл интерфейса: $uiPath"
    }

    & $uiPath
    Add-Content -LiteralPath $launchLog -Encoding UTF8 -Value ('{0} UI closed normally' -f [DateTime]::Now.ToString('s'))
}
catch {
    $details = $_ | Format-List * -Force | Out-String
    Add-Content -LiteralPath $launchLog -Encoding UTF8 -Value @(
        ('{0} STARTUP ERROR' -f [DateTime]::Now.ToString('s'))
        $details
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show(
            ("Интерфейс не запустился.`r`n`r`n{0}`r`n`r`nЖурнал: {1}" -f $_.Exception.Message, $launchLog),
            'Adaptive Zapret — ошибка запуска',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        )
    }
    catch {
        Write-Host $details -ForegroundColor Red
        Write-Host "Журнал: $launchLog" -ForegroundColor Yellow
        Read-Host 'Нажмите Enter, чтобы закрыть окно'
    }
    exit 1
}
