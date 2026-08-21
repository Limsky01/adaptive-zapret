# Adaptive Zapret core module 1.0.1.

Import-Module (Join-Path $PSScriptRoot 'AdaptiveZapret.Engine.psm1') -Force -DisableNameChecking

$PollSeconds = 2
$DnsWindowSeconds = 30

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$DataDir = Join-Path $Root 'data'
$ConnectionLog = Join-Path $DataDir 'connections.jsonl'
$DnsLog = Join-Path $DataDir 'dns.jsonl'
$StateFile = Join-Path $DataDir 'state.json'
$MapFile = Join-Path $DataDir 'traffic-map.csv'
$AppsFile = Join-Path $DataDir 'apps-map.csv'
$CollectorPidFile = Join-Path $DataDir 'collector.pid'
$SysmonLog = 'Microsoft-Windows-Sysmon/Operational'
$Version = '1.2.4'

New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SysmonLog {
    try {
        $null = Get-WinEvent -ListLog $SysmonLog -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Read-State {
    if (-not (Test-Path $StateFile)) {
        $latest=0
        if(Test-SysmonLog){$event=Get-WinEvent -LogName $SysmonLog -MaxEvents 1 -ErrorAction SilentlyContinue;if($event){$latest=[long]$event.RecordId}}
        return [ordered]@{ LastSysmonRecordId = $latest; SeenTcp = @{} }
    }
    try {
        $raw = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
        $seen = @{}
        if ($raw.SeenTcp) {
            foreach ($property in $raw.SeenTcp.PSObject.Properties) {
                $seen[$property.Name] = [bool]$property.Value
            }
        }
        return [ordered]@{
            LastSysmonRecordId = $(if ($null -ne $raw.LastSysmonRecordId) { [long]$raw.LastSysmonRecordId } else { 0 })
            SeenTcp = $seen
        }
    } catch {
        return [ordered]@{ LastSysmonRecordId = 0; SeenTcp = @{} }
    }
}

function Save-State([System.Collections.IDictionary]$State) {
    $temporary = "$StateFile.tmp"
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $temporary -Encoding UTF8
    Move-Item -Path $temporary -Destination $StateFile -Force
}

function Add-JsonLine([string]$Path, [object]$Value) {
    $line = $Value | ConvertTo-Json -Compress -Depth 6
    Add-Content -Path $Path -Value $line -Encoding UTF8
}

function Convert-EventData($Event) {
    [xml]$xml = $Event.ToXml()
    $fields = @{}
    foreach ($node in $xml.Event.EventData.Data) {
        $fields[[string]$node.Name] = [string]$node.'#text'
    }
    return $fields
}

function Get-ProcessDetails([int]$ProcessId, [string]$ImageHint) {
    $name = $null
    $path = $ImageHint
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $name = $process.ProcessName
        if (-not $path) { $path = $process.Path }
    } catch {
        if ($ImageHint) { $name = [IO.Path]::GetFileNameWithoutExtension($ImageHint) }
    }
    return @{ Name = $name; Path = $path }
}

function Read-NewSysmonEvents([System.Collections.IDictionary]$State) {
    $last = [long]$State.LastSysmonRecordId
    $xpath = "*[System[(EventID=3 or EventID=22) and EventRecordID>$last]]"
    $events = @(Get-WinEvent -LogName $SysmonLog -FilterXPath $xpath -Oldest -ErrorAction SilentlyContinue)
    foreach ($event in $events) {
        $data = Convert-EventData $event
        $pidValue = 0
        [void][int]::TryParse($data.ProcessId, [ref]$pidValue)
        $process = Get-ProcessDetails -ProcessId $pidValue -ImageHint $data.Image

        if ($event.Id -eq 3) {
            $record = [ordered]@{
                TimeUtc = $data.UtcTime
                ProcessId = $pidValue
                Process = $process.Name
                Image = $process.Path
                Protocol = ([string]$data.Protocol).ToUpperInvariant()
                SourceIp = $data.SourceIp
                SourcePort = $data.SourcePort
                DestinationIp = $data.DestinationIp
                DestinationHostname = $data.DestinationHostname
                DestinationPort = $data.DestinationPort
                Initiated = $data.Initiated
                Source = 'sysmon'
            }
            Add-JsonLine -Path $ConnectionLog -Value $record
            Write-Host ("[{0}] {1} -> {2}:{3}/{4}" -f $record.TimeUtc, $record.Process, $record.DestinationIp, $record.DestinationPort, $record.Protocol)
        } elseif ($event.Id -eq 22) {
            $record = [ordered]@{
                TimeUtc = $data.UtcTime
                ProcessId = $pidValue
                Process = $process.Name
                Image = $process.Path
                QueryName = $data.QueryName
                QueryStatus = $data.QueryStatus
                QueryResults = $data.QueryResults
                Source = 'sysmon'
            }
            Add-JsonLine -Path $DnsLog -Value $record
        }
        if ($event.RecordId -gt $State.LastSysmonRecordId) {
            $State.LastSysmonRecordId = [long]$event.RecordId
        }
    }
}

function Read-TcpFallback([System.Collections.IDictionary]$State) {
    $now = [DateTime]::UtcNow.ToString('o')
    $currentKeys = @{}
    $connections = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue)
    foreach ($connection in $connections) {
        $key = "{0}|{1}|{2}|{3}|{4}" -f $connection.OwningProcess, $connection.LocalAddress, $connection.LocalPort, $connection.RemoteAddress, $connection.RemotePort
        $currentKeys[$key] = $true
        if ($State.SeenTcp.ContainsKey($key)) { continue }

        $process = Get-ProcessDetails -ProcessId ([int]$connection.OwningProcess) -ImageHint $null
        $record = [ordered]@{
            TimeUtc = $now
            ProcessId = [int]$connection.OwningProcess
            Process = $process.Name
            Image = $process.Path
            Protocol = 'TCP'
            SourceIp = $connection.LocalAddress
            SourcePort = $connection.LocalPort
            DestinationIp = $connection.RemoteAddress
            DestinationHostname = $null
            DestinationPort = $connection.RemotePort
            Initiated = $true
            Source = 'tcp-fallback'
        }
        Add-JsonLine -Path $ConnectionLog -Value $record
        Write-Host ("[{0}] {1} -> {2}:{3}/TCP" -f $now, $record.Process, $record.DestinationIp, $record.DestinationPort)
    }
    $State.SeenTcp = $currentKeys
}

function Read-JsonLines([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    $items = @()
    foreach ($line in Get-Content -Path $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $items += ($line | ConvertFrom-Json) } catch { }
    }
    return $items
}

function Resolve-DomainForConnection($Connection, [array]$DnsEvents, [int]$WindowSeconds) {
    if ($Connection.DestinationHostname -and $Connection.DestinationHostname -ne '-') {
        return [string]$Connection.DestinationHostname
    }
    $connectionTime = [DateTime]::Parse($Connection.TimeUtc).ToUniversalTime()
    $candidate = $DnsEvents |
        Where-Object {
            $_.ProcessId -eq $Connection.ProcessId -and
            $_.QueryResults -like "*$($Connection.DestinationIp)*" -and
            [Math]::Abs(([DateTime]::Parse($_.TimeUtc).ToUniversalTime() - $connectionTime).TotalSeconds) -le $WindowSeconds
        } |
        Sort-Object { [Math]::Abs(([DateTime]::Parse($_.TimeUtc).ToUniversalTime() - $connectionTime).TotalSeconds) } |
        Select-Object -First 1
    if ($candidate) { return [string]$candidate.QueryName }
    return $null
}

function InvokeAdaptiveSummary {
    $connections = @(Read-JsonLines $ConnectionLog)
    $dns = @(Read-JsonLines $DnsLog)
    if ($connections.Count -eq 0) {
        Write-Host 'Нет собранных соединений. Сначала запустите monitor.' -ForegroundColor Yellow
        return
    }

    $rows = foreach ($connection in $connections) {
        $domain = Resolve-DomainForConnection -Connection $connection -DnsEvents $dns -WindowSeconds $DnsWindowSeconds
        [pscustomobject]@{
            Process = $connection.Process
            Image = $connection.Image
            Domain = $domain
            DestinationIp = $connection.DestinationIp
            DestinationPort = $connection.DestinationPort
            Protocol = $connection.Protocol
            FirstSeenUtc = $connection.TimeUtc
            Collector = $connection.Source
        }
    }

    $rows |
        Sort-Object Process, Domain, DestinationIp, DestinationPort, Protocol -Unique |
        Export-Csv -Path $MapFile -NoTypeInformation -Encoding UTF8
    Write-Host "Карта трафика сохранена: $MapFile" -ForegroundColor Green
}

function InvokeAdaptiveStatus {
    Write-Host "Adaptive Zapret: $Version"
    $sysmon = Test-SysmonLog
    Write-Host "Администратор: $(Test-IsAdministrator)"
    Write-Host "Sysmon журнал: $sysmon"
    if ($sysmon) {
        Write-Host 'Режим: полный TCP/UDP через Sysmon Event ID 3/22'
    } else {
        Write-Host 'Режим: ограниченный TCP fallback; для UDP установите и настройте Sysmon' -ForegroundColor Yellow
    }
    Write-Host "Данные: $DataDir"
    Get-AdaptiveEngineStatus | Format-List
}

function InvokeAdaptiveMonitor {
    if (-not (Test-IsAdministrator)) {
        Write-Warning 'Рекомендуется запустить PowerShell от имени администратора.'
    }
    $state = Read-State
    $useSysmon = Test-SysmonLog
    if ($useSysmon) {
        Write-Host 'Наблюдение запущено: Sysmon TCP/UDP + DNS. Ctrl+C для остановки.' -ForegroundColor Green
    } else {
        Write-Host 'Sysmon не найден. Запущен ограниченный сбор текущих TCP-соединений. Ctrl+C для остановки.' -ForegroundColor Yellow
    }
    try {
        while ($true) {
            if ($useSysmon) { Read-NewSysmonEvents -State $state }
            else { Read-TcpFallback -State $state }
            Save-State -State $state
            Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
        }
    } finally {
        Save-State -State $state
    }
}

function Test-IsNoiseTarget($Connection) {
    $ip = [string]$Connection.DestinationIp
    $port = [int]$Connection.DestinationPort
    if ($ip -eq '127.0.0.1' -or $ip -eq '::1') { return $true }
    if ($ip -like '192.168.*' -or $ip -like '169.254.*') { return $true }
    if ($ip -like 'fe80:*' -or $ip -like 'ff0*') { return $true }
    $first = 0
    if ($ip -match '^(\d+)\.') { $first = [int]$Matches[1] }
    if ($first -ge 224 -and $first -le 239) { return $true }
    if ($port -in @(53, 67, 68, 137, 138, 1900, 5353, 5355)) { return $true }
    if ([string]$Connection.Process -in @('System', 'svchost', 'mDNSResponder')) { return $true }
    return $false
}

function Get-AdaptiveApplicationRows([string]$OnlyProcess) {
    $connections = @(Read-JsonLines $ConnectionLog)
    $dns = @(Read-JsonLines $DnsLog)
    foreach ($connection in $connections) {
        if ($OnlyProcess -and ([string]$connection.Process -ine $OnlyProcess)) { continue }
        if (Test-IsNoiseTarget $connection) { continue }
        $domain = Resolve-DomainForConnection -Connection $connection -DnsEvents $dns -WindowSeconds $DnsWindowSeconds
        [pscustomobject]@{
            Process = $connection.Process
            Image = $connection.Image
            Domain = $domain
            DestinationIp = $connection.DestinationIp
            DestinationPort = $connection.DestinationPort
            Protocol = $connection.Protocol
            FirstSeenUtc = $connection.TimeUtc
            Collector = $connection.Source
        }
    }
}

function Group-AdaptiveRows([array]$Rows) {
    foreach($group in @($Rows | Group-Object Process,Image,Domain,DestinationIp,DestinationPort,Protocol)) {
        $first=@($group.Group | Sort-Object FirstSeenUtc | Select-Object -First 1)[0]
        $last=@($group.Group | Sort-Object FirstSeenUtc -Descending | Select-Object -First 1)[0]
        [pscustomobject]@{Process=$first.Process;Image=$first.Image;Domain=$first.Domain;DestinationIp=$first.DestinationIp;DestinationPort=$first.DestinationPort;Protocol=$first.Protocol;Connections=$group.Count;FirstSeenUtc=$first.FirstSeenUtc;LastSeenUtc=$last.FirstSeenUtc;Collector=$first.Collector}
    }
}

function InvokeAdaptiveApps {
    $rows = @(Group-AdaptiveRows @(Get-AdaptiveApplicationRows -OnlyProcess $null))
    if ($rows.Count -eq 0) {
        if (Test-Path -LiteralPath $AppsFile) {
            Write-Host "Новых соединений нет; предыдущая карта сохранена: $AppsFile" -ForegroundColor Yellow
        } else {
            Write-Host 'Внешние соединения пока не собраны. Карта не создана.' -ForegroundColor Yellow
        }
        return
    }
    $rows |
        Sort-Object Process, Domain, DestinationIp, DestinationPort, Protocol -Unique |
        Export-Csv -Path $AppsFile -NoTypeInformation -Encoding UTF8
    Write-Host "Карта приложений обновлена ($($rows.Count) строк): $AppsFile" -ForegroundColor Green
}

function InvokeAdaptiveStatusInfo {
    $engine=Get-AdaptiveEngineStatus
    $collector=$false;$collectorPid='—'
    if(Test-Path $CollectorPidFile){
        $value=0;if([int]::TryParse((Get-Content $CollectorPidFile -Raw).Trim(),[ref]$value) -and (Get-Process -Id $value -ErrorAction SilentlyContinue)){$collector=$true;$collectorPid=$value}
    }
    $apps=0;$appsFile=Join-Path $DataDir 'apps-map.csv';if(Test-Path $appsFile){$apps=@(Import-Csv $appsFile).Count}
    [pscustomobject]@{
        Version=(Get-Content (Join-Path $Root 'VERSION') -Raw).Trim()
        Administrator=Test-IsAdministrator
        Sysmon=Test-SysmonLog
        Collector=$collector
        CollectorPid=$collectorPid
        Engine=$engine.Engine
        Winws=$engine.ManagedWinws
        Rules=$engine.Rules
        Learning=$engine.Learning
        Connections=$apps
        DataDirectory=$DataDir
    }
}

function Get-AdaptiveKnownDomain([string]$Process,[string]$Ip,[int]$Port){
    $apps=Join-Path $DataDir 'apps-map.csv';if(-not (Test-Path $apps)){return ''}
    $row=Import-Csv $apps|Where-Object{$_.Process -ieq $Process -and $_.DestinationIp -eq $Ip -and [int]$_.DestinationPort -eq $Port -and $_.Domain -and $_.Domain -ne '-'}|Select-Object -First 1
    return [string]$row.Domain
}

function InvokeAdaptiveLiveConnections {
    # This function runs every second while the live tab is visible. Keep the
    # work bounded: do not reread the complete journal or apps map per socket.
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $processCache=@{}
    $domainCache=@{}
    $apps=Join-Path $DataDir 'apps-map.csv'
    if(Test-Path -LiteralPath $apps){
        foreach($known in @(Import-Csv -LiteralPath $apps)){
            if($known.Domain -and $known.Domain -ne '-'){
                $domainKey='{0}|{1}|{2}' -f ([string]$known.Process).ToLowerInvariant(),$known.DestinationIp,[int]$known.DestinationPort
                if(-not $domainCache.ContainsKey($domainKey)){$domainCache[$domainKey]=[string]$known.Domain}
            }
        }
    }
    foreach($connection in @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue)){
        $pidValue=[int]$connection.OwningProcess
        if(-not $processCache.ContainsKey($pidValue)){$processCache[$pidValue]=Get-ProcessDetails -ProcessId $pidValue -ImageHint $null}
        $details=$processCache[$pidValue]
        $candidate=[pscustomobject]@{Process=$details.Name;DestinationIp=$connection.RemoteAddress;DestinationPort=$connection.RemotePort}
        if(-not $details.Name -or (Test-IsNoiseTarget $candidate)){continue}
        $domainKey='{0}|{1}|{2}' -f ([string]$details.Name).ToLowerInvariant(),$connection.RemoteAddress,[int]$connection.RemotePort
        $domain=$(if($domainCache.ContainsKey($domainKey)){$domainCache[$domainKey]}else{''})
        $rows.Add([pscustomobject][ordered]@{Process=$details.Name;Domain=$domain;DestinationIp=$connection.RemoteAddress;DestinationPort=$connection.RemotePort;Protocol='TCP';State='Подключено';ObservedUtc=[DateTime]::Now.ToString('HH:mm:ss')})
    }
    $cutoff=[DateTime]::UtcNow.AddSeconds(-20)
    $recentLines=$(if(Test-Path -LiteralPath $ConnectionLog){@(Get-Content -LiteralPath $ConnectionLog -Tail 1000 -ErrorAction SilentlyContinue)}else{@()})
    foreach($line in $recentLines){
        if([string]::IsNullOrWhiteSpace($line)){continue}
        try{$connection=$line|ConvertFrom-Json}catch{continue}
        if($connection.Protocol -ne 'UDP' -or [string]$connection.Initiated -ne 'true'){continue}
        $time=[DateTime]::MinValue;if(-not [DateTime]::TryParse([string]$connection.TimeUtc,[ref]$time) -or $time.ToUniversalTime() -lt $cutoff){continue}
        if(Test-IsNoiseTarget $connection){continue}
        $domainKey='{0}|{1}|{2}' -f ([string]$connection.Process).ToLowerInvariant(),$connection.DestinationIp,[int]$connection.DestinationPort
        $domain=$(if($connection.DestinationHostname -and $connection.DestinationHostname -ne '-'){$connection.DestinationHostname}elseif($domainCache.ContainsKey($domainKey)){$domainCache[$domainKey]}else{''})
        $rows.Add([pscustomobject][ordered]@{Process=$connection.Process;Domain=$domain;DestinationIp=$connection.DestinationIp;DestinationPort=$connection.DestinationPort;Protocol='UDP';State='Недавно';ObservedUtc=$time.ToLocalTime().ToString('HH:mm:ss')})
    }
    return @($rows|Sort-Object Process,DestinationIp,DestinationPort,Protocol -Unique)
}

function InvokeAdaptiveFocus([string]$ProcessName) {
    $safeName = $ProcessName -replace '[^a-zA-Z0-9_.-]', '_'
    $focusFile = Join-Path $DataDir ("focus-{0}.csv" -f $safeName)
    $rows = @(Group-AdaptiveRows @(Get-AdaptiveApplicationRows -OnlyProcess $ProcessName))
    $rows |
        Sort-Object Domain, DestinationIp, DestinationPort, Protocol -Unique |
        Export-Csv -Path $focusFile -NoTypeInformation -Encoding UTF8
    if ($rows.Count -eq 0) {
        Write-Host "Для процесса $ProcessName внешние цели не найдены." -ForegroundColor Yellow
    } else {
        Write-Host "Цели ${ProcessName}: $focusFile" -ForegroundColor Green
        $rows | Sort-Object Connections -Descending | Format-Table Domain, DestinationIp, DestinationPort, Protocol, Connections
    }
}

function InvokeAdaptiveStart {
    if (Test-Path $CollectorPidFile) {
        $oldPid = [int](Get-Content -Raw $CollectorPidFile)
        if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
            Write-Host "Сборщик уже работает, PID $oldPid" -ForegroundColor Yellow
            return
        }
    }
    $launcher = Join-Path $Root 'AdaptiveZapret.ps1'
    $stdout = Join-Path $DataDir 'collector-output.log'
    $stderr = Join-Path $DataDir 'collector-error.log'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launcher`" monitor"
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    Set-Content -Path $CollectorPidFile -Value $process.Id -Encoding ASCII
    Write-Host "Фоновый сбор запущен, PID $($process.Id)" -ForegroundColor Green
}

function InvokeAdaptiveStop {
    if (-not (Test-Path $CollectorPidFile)) {
        Write-Host 'Фоновый сборщик не запущен.' -ForegroundColor Yellow
        return
    }
    $collectorPid = [int](Get-Content -Raw $CollectorPidFile)
    Stop-Process -Id $collectorPid -Force -ErrorAction SilentlyContinue
    Remove-Item $CollectorPidFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    InvokeAdaptiveApps
    Write-Host 'Фоновый сбор остановлен.' -ForegroundColor Green
}

function InvokeAdaptiveEngineInstall { Install-AdaptiveEngine }
function InvokeAdaptiveSysmonInstall {
    if(-not (Test-IsAdministrator)){throw 'Установка Sysmon требует PowerShell от имени администратора.'}
    if(Test-SysmonLog){Write-Host 'Sysmon уже установлен.' -ForegroundColor Yellow;return}
    $runtime=Join-Path $Root 'data\runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
    $zip=Join-Path $runtime 'Sysmon.zip';$folder=Join-Path $runtime 'Sysmon'
    Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/Sysmon.zip' -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $folder -Force
    $exe=Join-Path $folder 'Sysmon64.exe'
    $signature=Get-AuthenticodeSignature -LiteralPath $exe
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft'){throw 'Подпись загруженного Sysmon не подтверждена как Microsoft.'}
    & $exe -accepteula -i (Join-Path $Root 'sysmon-adaptive-zapret.xml') | Out-Host
    if(-not (Test-SysmonLog)){throw 'Sysmon установлен, но журнал не найден.'}
    Write-Host 'Официальный Microsoft Sysmon установлен и настроен.' -ForegroundColor Green
}
function InvokeAdaptiveSetup {
    if(-not (Test-IsAdministrator)){throw 'Первичная настройка требует PowerShell от имени администратора.'}
    InvokeAdaptiveSysmonInstall
    if(-not (Resolve-AdaptiveEngine)){Install-AdaptiveEngine}
    InvokeAdaptiveStart
    Write-Host 'Настройка завершена. Откройте интерфейс командой: .\AdaptiveZapret.ps1 ui' -ForegroundColor Green
}
function InvokeAdaptiveEngineSet([string]$Path) { Set-AdaptiveEngineRoot -Path $Path }
function InvokeAdaptiveRules { Get-AdaptiveRules | Format-Table Id,Process,Domain,Ip,Port,Protocol,Mode,Strategy,Enabled -AutoSize }
function InvokeAdaptiveRuleList { return @(Get-AdaptiveRules) }
function InvokeAdaptiveRuleCreate([string]$Process,[string]$Domain,[string]$Ip,[int]$Port,[string]$Protocol,[string]$Mode,[string]$Strategy='') {
    Add-AdaptiveRule -Process $Process -Domain $Domain -Ip $Ip -Port $Port -Protocol $Protocol -Mode $Mode -Strategy $Strategy
}
function InvokeAdaptiveRuleAdd([string]$Spec) {
    if ([string]::IsNullOrWhiteSpace($Spec)) { throw 'Формат: Process|Domain|IP|Port|TCP|direct|Strategy (пустые Domain/IP допустимы по одному)' }
    $parts = @($Spec -split '\|', 7)
    if ($parts.Count -lt 6) { throw 'Формат: Process|Domain|IP|Port|TCP|direct|Strategy' }
    Add-AdaptiveRule -Process $parts[0] -Domain $parts[1] -Ip $parts[2] -Port ([int]$parts[3]) -Protocol $parts[4].ToUpperInvariant() -Mode $parts[5].ToLowerInvariant() -Strategy $(if($parts.Count -gt 6){$parts[6]}else{''})
}
function InvokeAdaptiveRuleRemove([string]$Id) { Remove-AdaptiveRule -Id $Id }
function InvokeAdaptiveApply { Apply-AdaptiveRules }
function InvokeAdaptiveDirect { Reset-AdaptiveNetwork }
function InvokeAdaptiveLearn([string]$Spec) {
    $parts=@($Spec -split '\|',5)
    if ($parts.Count -eq 1) { Start-AdaptiveLearning -ProcessName $parts[0]; return }
    if ($parts.Count -lt 5) { throw 'Формат: Process|Domain|IP|Port|Protocol' }
    Start-AdaptiveLearning -ProcessName $parts[0] -Domain $parts[1] -Ip $parts[2] -Port ([int]$parts[3]) -Protocol $parts[4]
}
function InvokeAdaptiveTest([string]$Result) { Submit-AdaptiveLearningResult -Result $Result }
function InvokeAdaptiveExport { Export-AdaptiveAutoBatch }
function InvokeAdaptiveAutoStartOn { Enable-AdaptiveAutoStart }
function InvokeAdaptiveAutoStartOff { Disable-AdaptiveAutoStart }
function InvokeAdaptiveBoot {
    if((Get-AdaptiveSettings).AutoStartCollector){InvokeAdaptiveStart}
    InvokeAdaptiveApply
}
function InvokeAdaptiveSelfTest {
    Test-AdaptiveEngineSelf
    $tokens=$null; $errors=$null
    foreach ($file in @((Join-Path $Root 'AdaptiveZapret.ps1'),(Join-Path $Root 'AdaptiveZapret.Core.psm1'),(Join-Path $Root 'AdaptiveZapret.Engine.psm1'),(Join-Path $Root 'AdaptiveZapret.UI.ps1'))) {
        $null=[System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
        if (@($errors).Count) { throw "Синтаксическая ошибка в ${file}: $($errors[0].Message)" }
    }
    Write-Host 'PowerShell self-test: OK' -ForegroundColor Green
}

function InvokeAdaptiveUpdateStatus {
    $versionFile=Join-Path $Root 'VERSION'
    $current=$(if(Test-Path $versionFile){(Get-Content $versionFile -Raw).Trim()}else{'0.0.0'})
    $settings=Get-AdaptiveSettings
    if(-not $settings.UpdateManifestUrl){
        InvokeAdaptiveUpdateConfigure 'https://raw.githubusercontent.com/Limsky01/adaptive-zapret/main/release-manifest.json'
        $settings=Get-AdaptiveSettings
    }
    [pscustomobject]@{CurrentVersion=$current;ManifestUrl=[string]$settings.UpdateManifestUrl}
}

function InvokeAdaptiveUpdateConfigure([string]$ManifestUrl) {
    if($ManifestUrl -and $ManifestUrl -notmatch '^https://'){throw 'Канал обновлений должен использовать HTTPS.'}
    $settings=Get-AdaptiveSettings
    if(-not $settings.PSObject.Properties['UpdateManifestUrl']){$settings|Add-Member NoteProperty UpdateManifestUrl ''}
    $settings.UpdateManifestUrl=$ManifestUrl.Trim()
    $settings|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $Root 'config\settings.json') -Encoding UTF8
}

function InvokeAdaptiveUpdate([string]$PackagePath='') {
    $updater=Join-Path $Root 'AdaptiveZapret.Updater.ps1'
    if(-not (Test-Path $updater)){throw 'Файл обновления отсутствует.'}
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $updater),'-Root',('"{0}"' -f $Root))
    if($PackagePath){$arguments+=@('-PackagePath',('"{0}"' -f $PackagePath))}
    Start-Process powershell.exe -ArgumentList ($arguments -join ' ') -Verb RunAs | Out-Null
}

Export-ModuleMember -Function 'InvokeAdaptive*'
