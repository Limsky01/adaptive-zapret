$ErrorActionPreference = 'Stop'

$Script:Root = $PSScriptRoot
$Script:DataDir = Join-Path $Script:Root 'data'
$Script:ConfigDir = Join-Path $Script:Root 'config'
$Script:RuntimeDir = Join-Path $Script:DataDir 'runtime'
$Script:RulesFile = Join-Path $Script:DataDir 'rules.json'
$Script:LearningFile = Join-Path $Script:DataDir 'learning.json'
$Script:StrategyHistoryFile = Join-Path $Script:DataDir 'strategy-history.jsonl'
$Script:EnginePidFile = Join-Path $Script:RuntimeDir 'winws.pid'
$Script:EngineLog = Join-Path $Script:RuntimeDir 'winws.log'
$Script:EngineErrorLog = Join-Path $Script:RuntimeDir 'winws-error.log'
$Script:EngineDebugLog = Join-Path $Script:RuntimeDir 'winws-debug.log'
$Script:EngineCommandFile = Join-Path $Script:RuntimeDir 'winws-command.txt'
$Script:ScenarioDir = Join-Path $Script:RuntimeDir 'scenario'
$Script:SettingsFile = Join-Path $Script:ConfigDir 'settings.json'
$Script:StrategiesFile = Join-Path $Script:ConfigDir 'strategies.json'
$Script:FirewallPrefix = 'AdaptiveZapret-'

New-Item -ItemType Directory -Path $Script:DataDir,$Script:ConfigDir,$Script:RuntimeDir,$Script:ScenarioDir -Force | Out-Null

function Write-AdaptiveJson([string]$Path, [object]$Value) {
    $temp = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-AdaptiveJson([string]$Path, $Default) {
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $Default }
}

function Initialize-AdaptiveConfiguration {
    if (-not (Test-Path -LiteralPath $Script:SettingsFile)) {
        Write-AdaptiveJson $Script:SettingsFile ([ordered]@{
            SchemaVersion = 2
            EngineRoot = ''
            AutoStartCollector = $true
            MaxAttemptsPerSession = 12
            UpdateManifestUrl = 'https://raw.githubusercontent.com/Limsky01/adaptive-zapret/main/release-manifest.json'
            ProtectedProcesses = @('System','svchost','lsass','services','wininit','winlogon','MsMpEng')
            ProtectedDomains = @('microsoft.com','windowsupdate.com','office.com','live.com')
        })
    }
    if (-not (Test-Path -LiteralPath $Script:StrategiesFile)) {
        Write-AdaptiveJson $Script:StrategiesFile ([ordered]@{ SchemaVersion=2; Source='Flowseal general*.bat'; Profiles=@() })
    }
    if (-not (Test-Path -LiteralPath $Script:RulesFile)) {
        Write-AdaptiveJson $Script:RulesFile ([ordered]@{ SchemaVersion=1; Rules=@() })
    }
}

function Get-AdaptiveSettings { Initialize-AdaptiveConfiguration; return Read-AdaptiveJson $Script:SettingsFile $null }
function Get-AdaptiveRules { Initialize-AdaptiveConfiguration; return @(Read-AdaptiveJson $Script:RulesFile ([pscustomobject]@{Rules=@()}) | Select-Object -ExpandProperty Rules) }
function Save-AdaptiveRules([array]$Rules) { Write-AdaptiveJson $Script:RulesFile ([ordered]@{ SchemaVersion=1; Rules=@($Rules) }) }

function Invoke-AdaptiveConfigurationMigration {
    $settings=Get-AdaptiveSettings
    if([int]$settings.SchemaVersion -ge 2){return}
    $rules=@(Get-AdaptiveRules)
    foreach($rule in $rules){
        if($rule.Mode -eq 'zapret' -and $rule.Strategy -and $rule.Strategy -notlike 'flowseal::*'){
            $rule|Add-Member -NotePropertyName LegacyStrategy -NotePropertyValue ([string]$rule.Strategy) -Force
            $rule.Strategy='';$rule.Enabled=$false
        }
    }
    Save-AdaptiveRules $rules
    $settings.SchemaVersion=2
    Write-AdaptiveJson $Script:SettingsFile $settings
}

function Resolve-AdaptiveEngine {
    $settings = Get-AdaptiveSettings
    # Never recursively scan the parent of the application directory.  When the
    # application is installed as C:\adaptive-zapret that parent is C:\, and a
    # status refresh would otherwise walk the whole system drive on the UI
    # thread and make the window appear hung.
    $roots = @($settings.EngineRoot, (Join-Path $Script:Root 'engine'), $Script:Root) |
        Where-Object { $_ } | Select-Object -Unique
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'bin\winws.exe'
        if (Test-Path -LiteralPath $candidate) { return [pscustomobject]@{ Root=$root; Winws=$candidate; Bin=(Split-Path $candidate); Kind='flowseal' } }
        $candidate = Join-Path $root 'winws.exe'
        if (Test-Path -LiteralPath $candidate) { return [pscustomobject]@{ Root=$root; Winws=$candidate; Bin=(Split-Path $candidate); Kind='standalone' } }
        $found = Get-ChildItem -LiteralPath $root -Filter winws.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return [pscustomobject]@{ Root=$root; Winws=$found.FullName; Bin=$found.DirectoryName; Kind='detected' } }
    }
    return $null
}

function Set-AdaptiveEngineRoot([string]$Path) {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $settings = Get-AdaptiveSettings
    $settings.EngineRoot = $resolved
    Write-AdaptiveJson $Script:SettingsFile $settings
    $engine = Resolve-AdaptiveEngine
    if (-not $engine) { throw "В указанной папке не найден winws.exe: $resolved" }
    Write-Host "Движок найден: $($engine.Winws)" -ForegroundColor Green
}

function Install-AdaptiveEngine {
    $destination = Join-Path $Script:Root 'engine'
    if (Resolve-AdaptiveEngine) {
        if(-not (Get-AdaptiveFlowsealRoot)){throw 'Найден только winws.exe, но нет полного комплекта Flowseal с general*.bat, lists и bin. Укажите полную папку Flowseal.'}
        Write-Host 'Полный комплект Flowseal уже установлен или обнаружен.' -ForegroundColor Yellow; return
    }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest' -Headers @{ 'User-Agent'='AdaptiveZapret' }
    $asset = @($release.assets) | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'В последнем официальном релизе Flowseal не найден ZIP-архив.' }
    $zip = Join-Path $Script:RuntimeDir 'flowseal-release.zip'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if (Test-Path -LiteralPath $destination) { throw "Папка уже существует: $destination" }
    Expand-Archive -LiteralPath $zip -DestinationPath $destination -Force
    $settings = Get-AdaptiveSettings
    $settings.EngineRoot = $destination
    Write-AdaptiveJson $Script:SettingsFile $settings
    [ordered]@{ Repository='Flowseal/zapret-discord-youtube'; Tag=$release.tag_name; Asset=$asset.name; Sha256=$hash; InstalledUtc=[DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Script:ConfigDir 'engine-receipt.json') -Encoding UTF8
    if (-not (Resolve-AdaptiveEngine)) { throw 'Архив загружен, но winws.exe внутри не найден.' }
    Write-Host "Официальный движок установлен. SHA256 архива: $hash" -ForegroundColor Green
}

function Test-AdaptiveSafeTarget([string]$Process, [string]$Domain, [string]$Ip, [int]$Port) {
    $settings = Get-AdaptiveSettings
    if ([string]::IsNullOrWhiteSpace($Process)) { throw 'Для правила обязателен процесс.' }
    if ($settings.ProtectedProcesses -contains $Process) { throw "Защищённый системный процесс: $Process" }
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'Порт должен быть от 1 до 65535.' }
    if (-not $Domain -and -not $Ip) { throw 'Нужен домен или IP.' }
    if ($Domain -match '[*?]') { throw 'Шаблоны доменов запрещены: укажите точный домен.' }
    foreach ($protected in $settings.ProtectedDomains) {
        if ($Domain -eq $protected -or $Domain -like "*.$protected") { throw "Защищённый домен: $Domain" }
    }
}

function Add-AdaptiveRule([string]$Process,[string]$Domain,[string]$Ip,[int]$Port,[ValidateSet('TCP','UDP')][string]$Protocol,[ValidateSet('direct','zapret','block')][string]$Mode,[string]$Strategy='') {
    Test-AdaptiveSafeTarget $Process $Domain $Ip $Port
    $rules = @(Get-AdaptiveRules | Where-Object { -not ($_.Process -ieq $Process -and $_.Domain -ieq $Domain -and $_.Ip -eq $Ip -and [int]$_.Port -eq $Port -and $_.Protocol -eq $Protocol) })
    $rules += [pscustomobject][ordered]@{ Id=[guid]::NewGuid().ToString('N'); Process=$Process; Domain=$Domain; Ip=$Ip; Port=$Port; Protocol=$Protocol; Mode=$Mode; Strategy=$Strategy; Enabled=$true; UpdatedUtc=[DateTime]::UtcNow.ToString('o') }
    Save-AdaptiveRules $rules
    Write-Host "Правило сохранено: $Process $Domain $Ip $Port/$Protocol -> $Mode" -ForegroundColor Green
}

function Remove-AdaptiveRule([string]$Id) {
    $rules = @(Get-AdaptiveRules)
    $remaining = @($rules | Where-Object { $_.Id -ne $Id })
    if ($remaining.Count -eq $rules.Count) { throw "Правило не найдено: $Id" }
    Save-AdaptiveRules $remaining
}

function Get-AdaptiveManagedProcess {
    if (-not (Test-Path -LiteralPath $Script:EnginePidFile)) { return $null }
    $pidValue = 0
    if (-not [int]::TryParse((Get-Content -LiteralPath $Script:EnginePidFile -Raw).Trim(), [ref]$pidValue)) { return $null }
    return Get-Process -Id $pidValue -ErrorAction SilentlyContinue
}

function Stop-AdaptiveEngine {
    $process = Get-AdaptiveManagedProcess
    if ($process) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; $process.WaitForExit(3000) }
    Remove-Item -LiteralPath $Script:EnginePidFile -Force -ErrorAction SilentlyContinue
    Write-Host 'Управляемый экземпляр winws остановлен.' -ForegroundColor Green
}

function Get-AdaptiveProfile([string]$Id) {
    $catalog = Read-AdaptiveJson $Script:StrategiesFile $null
    return @($catalog.Profiles | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
}

function Initialize-AdaptiveTcpResetApi {
    if('AdaptiveTcpReset' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AdaptiveTcpReset {
  [StructLayout(LayoutKind.Sequential)] public struct MIB_TCPROW {
    public uint state, localAddr, localPort, remoteAddr, remotePort;
  }
  [DllImport("iphlpapi.dll", SetLastError=true)] public static extern uint SetTcpEntry(ref MIB_TCPROW row);
}
'@
}

function Get-AdaptiveFlowsealRoot {
    $engine = Resolve-AdaptiveEngine
    if (-not $engine) { return $null }
    $candidate = Split-Path -Parent $engine.Bin
    if (Test-Path -LiteralPath (Join-Path $candidate 'general.bat')) { return $candidate }
    $bat = Get-ChildItem -LiteralPath $engine.Root -Filter 'general.bat' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bat) { return $bat.DirectoryName }
    return $null
}

function Get-AdaptiveFlowsealStrategies {
    $root = Get-AdaptiveFlowsealRoot
    if (-not $root) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Filter 'general*.bat' -File -ErrorAction SilentlyContinue |
        Sort-Object @{Expression={ if ($_.Name -eq 'general.bat') { 0 } else { 1 } }},Name |
        ForEach-Object { [pscustomobject]@{ Id=('flowseal::' + $_.Name); Name=$_.BaseName; Path=$_.FullName; Kind='FlowsealBat' } })
}

function Get-AdaptiveFlowsealCommand([string]$BatPath,[array]$Targets) {
    $engine = Resolve-AdaptiveEngine
    $flowRoot = Get-AdaptiveFlowsealRoot
    if (-not $engine -or -not $flowRoot) { throw 'Не найден полный комплект Flowseal.' }
    $lines = @(Get-Content -LiteralPath $BatPath)
    $startIndex = -1
    for ($i=0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'winws\.exe') { $startIndex=$i; break } }
    if ($startIndex -lt 0) { throw "В стратегии не найдена команда winws.exe: $BatPath" }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    for ($i=$startIndex; $i -lt $lines.Count; $i++) {
        $line=[string]$lines[$i]
        if ($i -eq $startIndex) {
            $match=[regex]::Match($line,'winws\.exe"\s*(.*)$',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $match.Success) { throw "Не удалось разобрать запуск winws: $BatPath" }
            $line=$match.Groups[1].Value
        }
        $continued=$line.TrimEnd().EndsWith('^')
        if ($continued) { $line=$line.TrimEnd();$line=$line.Substring(0,$line.Length-1) }
        $line=$line.Replace('^!','!').Trim()
        if ($line) { $parts.Add($line) }
        if (-not $continued) { break }
    }
    $raw=($parts -join ' ')
    $bin=($engine.Bin.TrimEnd('\') + '\')
    $lists=(Join-Path $flowRoot 'lists').TrimEnd('\') + '\'
    $tcpPorts=@($Targets|Where-Object Protocol -eq 'TCP'|ForEach-Object{[int]$_.Port}|Where-Object{$_ -ge 1024}|Sort-Object -Unique)
    $udpPorts=@($Targets|Where-Object Protocol -eq 'UDP'|ForEach-Object{[int]$_.Port}|Where-Object{$_ -ge 1024}|Sort-Object -Unique)
    $raw=$raw.Replace('%BIN%',$bin).Replace('%LISTS%',$lists)
    $raw=$raw.Replace('%GameFilterTCP%',$(if($tcpPorts.Count){$tcpPorts -join ','}else{'12'}))
    $raw=$raw.Replace('%GameFilterUDP%',$(if($udpPorts.Count){$udpPorts -join ','}else{'12'}))

    $hosts=@($Targets|ForEach-Object{[string]$_.Domain}|Where-Object{$_ -and $_ -ne '-'}|Sort-Object -Unique)
    $ips=@($Targets|ForEach-Object{[string]$_.Ip}|Where-Object{$_}|Sort-Object -Unique)
    $hostFile=Join-Path $Script:ScenarioDir 'hosts.txt'
    $ipFile=Join-Path $Script:ScenarioDir 'ips.txt'
    $emptyFile=Join-Path $Script:ScenarioDir 'exclude-empty.txt'
    Set-Content -LiteralPath $hostFile -Value $hosts -Encoding ASCII
    Set-Content -LiteralPath $ipFile -Value $ips -Encoding ASCII
    Set-Content -LiteralPath $emptyFile -Value @() -Encoding ASCII
    $quotedIp='--ipset="' + $ipFile + '"'
    $quotedEmptyHost='--hostlist-exclude="' + $emptyFile + '"'
    $quotedEmptyIp='--ipset-exclude="' + $emptyFile + '"'
    # Sysmon/DNS correlation is not TLS SNI. During a scenario test, select the
    # exact observed IPs and remove Flowseal's static hostlists. This guarantees
    # that a PTR/CNAME mismatch cannot silently exclude the packet.
    $raw=[regex]::Replace($raw,'\s*--hostlist="[^"]+"','')
    $raw=[regex]::Replace($raw,'\s*--hostlist-domains=[^\s]+','')
    if ($ips.Count) { $raw=[regex]::Replace($raw,'--ipset="[^"]+"',$quotedIp) }
    $raw=[regex]::Replace($raw,'--hostlist-exclude="[^"]+"',$quotedEmptyHost)
    $raw=[regex]::Replace($raw,'--ipset-exclude="[^"]+"',$quotedEmptyIp)
    Remove-Item -LiteralPath $Script:EngineDebugLog -Force -ErrorAction SilentlyContinue
    return ('--debug="@' + $Script:EngineDebugLog + '" ' + $raw)
}

function Start-AdaptiveFlowsealStrategy([string]$StrategyId,[array]$Targets) {
    $strategy=@(Get-AdaptiveFlowsealStrategies|Where-Object Id -eq $StrategyId)|Select-Object -First 1
    if (-not $strategy) { throw "Стратегия Flowseal не найдена: $StrategyId" }
    $engine=Resolve-AdaptiveEngine
    Stop-AdaptiveEngine | Out-Null
    if (@(Get-Process winws -ErrorAction SilentlyContinue).Count) { throw 'Уже запущен сторонний winws. Остановите его штатным способом.' }
    $arguments=Get-AdaptiveFlowsealCommand -BatPath $strategy.Path -Targets $Targets
    Set-Content -LiteralPath $Script:EngineCommandFile -Value ((('"'+$engine.Winws+'" ') + $arguments)) -Encoding UTF8
    $process=Start-Process -FilePath $engine.Winws -ArgumentList $arguments -WorkingDirectory $engine.Bin -WindowStyle Hidden -RedirectStandardOutput $Script:EngineLog -RedirectStandardError $Script:EngineErrorLog -PassThru
    Set-Content -LiteralPath $Script:EnginePidFile -Value $process.Id -Encoding ASCII
    Start-Sleep -Milliseconds 1000
    if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) { throw "winws завершился. Проверьте $Script:EngineErrorLog" }
    Write-Host "Запущена полная стратегия Flowseal: $($strategy.Name), PID $($process.Id)" -ForegroundColor Green
}

function Get-AdaptiveProfileEvidence {
    $debugLines=$(if(Test-Path -LiteralPath $Script:EngineDebugLog){@(Get-Content -LiteralPath $Script:EngineDebugLog -Tail 300 -ErrorAction SilentlyContinue)}else{@()})
    $debugBytes=$(if(Test-Path -LiteralPath $Script:EngineDebugLog){[long](Get-Item -LiteralPath $Script:EngineDebugLog).Length}else{0})
    $recognized=@($debugLines|Where-Object{$_ -match 'TLS ClientHello|QUIC initial|HTTP request|discord voice|STUN message'}).Count
    $hostChecks=@($debugLines|Where-Object{$_ -match 'hostlist check for'}).Count
    $desync=@($debugLines|Where-Object{$_ -match 'sending|multisplit|multidisorder|hostfakesplit|fakedsplit'}).Count
    [pscustomobject]@{DebugLines=$debugLines.Count;DebugBytes=$debugBytes;Recognized=$recognized;HostChecks=$hostChecks;DesyncEvidence=$desync;CommandFile=$Script:EngineCommandFile;DebugFile=$Script:EngineDebugLog}
}

function Convert-AdaptiveTcpAddress([string]$Address){
    return [BitConverter]::ToUInt32([Net.IPAddress]::Parse($Address).GetAddressBytes(),0)
}

function Convert-AdaptiveTcpPort([int]$Port){
    return [BitConverter]::ToUInt32([byte[]]@([byte]($Port-shr 8),[byte]($Port-band 255),0,0),0)
}

function Restart-AdaptiveTargetConnection([object]$Rule,[int]$DelaySeconds=5) {
    $pids=@(Get-Process -Name $Rule.Process -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Id)
    if(-not $pids.Count){Write-Host "Процесс $($Rule.Process) сейчас не запущен." -ForegroundColor Yellow;return}
    if($Rule.Protocol -eq 'TCP'){
        if(-not $Rule.Ip -or $Rule.Ip -match ':'){Write-Host 'Автосброс TCP пока поддерживает точный IPv4-адрес.' -ForegroundColor Yellow;return}
        $connections=@(Get-NetTCPConnection -RemoteAddress $Rule.Ip -RemotePort ([int]$Rule.Port) -ErrorAction SilentlyContinue|Where-Object{$pids -contains $_.OwningProcess})
        if(-not $connections.Count){Write-Host 'Активное TCP-соединение не найдено; следующая попытка сразу пойдёт через новый профиль.' -ForegroundColor Yellow;return}
        Initialize-AdaptiveTcpResetApi
        $closed=0
        foreach($connection in $connections){
            if($connection.LocalAddress -match ':'){continue}
            $row=New-Object AdaptiveTcpReset+MIB_TCPROW
            $row.state=12
            $row.localAddr=Convert-AdaptiveTcpAddress $connection.LocalAddress
            $row.localPort=Convert-AdaptiveTcpPort ([int]$connection.LocalPort)
            $row.remoteAddr=Convert-AdaptiveTcpAddress $connection.RemoteAddress
            $row.remotePort=Convert-AdaptiveTcpPort ([int]$connection.RemotePort)
            if([AdaptiveTcpReset]::SetTcpEntry([ref]$row) -eq 0){$closed++}
        }
        Write-Host "Закрыто TCP-соединений: $closed. Ожидание повторного подключения: $DelaySeconds сек." -ForegroundColor Cyan
        Start-Sleep -Seconds $DelaySeconds
        $reconnected=@(Get-NetTCPConnection -RemoteAddress $Rule.Ip -RemotePort ([int]$Rule.Port) -State Established -ErrorAction SilentlyContinue|Where-Object{$pids -contains $_.OwningProcess}).Count -gt 0
        Write-Host $(if($reconnected){'Повторное TCP-подключение обнаружено.'}else{'Повторное подключение пока не обнаружено; игра может ждать следующей попытки.'}) -ForegroundColor $(if($reconnected){'Green'}else{'Yellow'})
        return
    }
    if($Rule.Protocol -eq 'UDP'){
        if(-not $Rule.Ip){Write-Host 'Для перезапуска UDP нужен точный IP.' -ForegroundColor Yellow;return}
        $process=Get-Process -Name $Rule.Process -ErrorAction SilentlyContinue|Select-Object -First 1
        if(-not $process.Path){Write-Host 'Не найден путь процесса для временного UDP-правила.' -ForegroundColor Yellow;return}
        $name="$Script:FirewallPrefix temporary reconnect"
        try{
            New-NetFirewallRule -DisplayName $name -Direction Outbound -Action Block -Program $process.Path -Protocol UDP -RemoteAddress $Rule.Ip -RemotePort ([int]$Rule.Port)|Out-Null
            Write-Host "UDP-цель заблокирована на $DelaySeconds сек. для принудительной новой попытки." -ForegroundColor Cyan
            Start-Sleep -Seconds $DelaySeconds
        }finally{Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue|Remove-NetFirewallRule -ErrorAction SilentlyContinue}
        Write-Host 'Временная UDP-блокировка снята.' -ForegroundColor Green
    }
}

function Start-AdaptiveProfile([object]$Rule,[string]$ProfileId) {
    if($ProfileId -like 'flowseal::*'){
        Start-AdaptiveFlowsealStrategy -StrategyId $ProfileId -Targets @($Rule)
        Restart-AdaptiveTargetConnection -Rule $Rule -DelaySeconds 5
        return
    }
    $engine = Resolve-AdaptiveEngine
    if (-not $engine) { throw 'winws.exe не найден. Выполните engine-install или engine-set <папка>.' }
    $profile = Get-AdaptiveProfile $ProfileId
    if (-not $profile) { throw "Профиль не найден: $ProfileId" }
    if ($profile.Protocol -ne $Rule.Protocol) { throw "Профиль $ProfileId не подходит для $($Rule.Protocol)." }
    Stop-AdaptiveEngine | Out-Null
    $portFilter = if ($Rule.Protocol -eq 'TCP') { "--wf-tcp=$($Rule.Port)" } else { "--wf-udp=$($Rule.Port)" }
    $profileFilter = if ($Rule.Protocol -eq 'TCP') { "--filter-tcp=$($Rule.Port)" } else { "--filter-udp=$($Rule.Port)" }
    $targetFilter = if ($Rule.Domain) { "--hostlist-domains=$($Rule.Domain)" } else { "--ipset-ip=$($Rule.Ip)" }
    $arguments = @($portFilter,$profileFilter,$targetFilter) + @($profile.Args)
    $otherWinws = @(Get-Process winws -ErrorAction SilentlyContinue)
    if ($otherWinws.Count -gt 0) { throw 'Уже запущен сторонний winws. Остановите его штатным способом, чтобы фильтры не пересекались.' }
    $process = Start-Process -FilePath $engine.Winws -ArgumentList $arguments -WorkingDirectory $engine.Bin -WindowStyle Hidden -RedirectStandardOutput $Script:EngineLog -RedirectStandardError $Script:EngineErrorLog -PassThru
    Set-Content -LiteralPath $Script:EnginePidFile -Value $process.Id -Encoding ASCII
    Start-Sleep -Milliseconds 700
    if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) { throw "winws завершился. Проверьте $Script:EngineErrorLog" }
    Write-Host "Профиль $ProfileId запущен для $($Rule.Domain)$($Rule.Ip):$($Rule.Port)/$($Rule.Protocol), PID $($process.Id)" -ForegroundColor Green
    Restart-AdaptiveTargetConnection -Rule $Rule -DelaySeconds 5
}

function Start-AdaptiveRuleSet([array]$Rules) {
    $engine = Resolve-AdaptiveEngine
    if (-not $engine) { throw 'winws.exe не найден. Выполните engine-install или engine-set <папка>.' }
    $tcpPorts = @($Rules | Where-Object Protocol -eq 'TCP' | ForEach-Object { [int]$_.Port } | Sort-Object -Unique)
    $udpPorts = @($Rules | Where-Object Protocol -eq 'UDP' | ForEach-Object { [int]$_.Port } | Sort-Object -Unique)
    $arguments = @()
    if ($tcpPorts.Count) { $arguments += '--wf-tcp=' + ($tcpPorts -join ',') }
    if ($udpPorts.Count) { $arguments += '--wf-udp=' + ($udpPorts -join ',') }
    $first = $true
    foreach ($rule in $Rules) {
        $profile = Get-AdaptiveProfile $rule.Strategy
        if (-not $profile) { throw "Профиль не найден: $($rule.Strategy)" }
        if ($profile.Protocol -ne $rule.Protocol) { throw "Профиль $($profile.Id) не подходит для $($rule.Protocol)." }
        if (-not $first) { $arguments += '--new' }
        $first = $false
        $arguments += $(if ($rule.Protocol -eq 'TCP') { "--filter-tcp=$($rule.Port)" } else { "--filter-udp=$($rule.Port)" })
        $arguments += $(if ($rule.Domain) { "--hostlist-domains=$($rule.Domain)" } else { "--ipset-ip=$($rule.Ip)" })
        $arguments += @($profile.Args)
    }
    Stop-AdaptiveEngine | Out-Null
    if (@(Get-Process winws -ErrorAction SilentlyContinue).Count) { throw 'Уже запущен сторонний winws. Остановите его штатным способом, чтобы фильтры не пересекались.' }
    $process = Start-Process -FilePath $engine.Winws -ArgumentList $arguments -WorkingDirectory $engine.Bin -WindowStyle Hidden -RedirectStandardOutput $Script:EngineLog -RedirectStandardError $Script:EngineErrorLog -PassThru
    Set-Content -LiteralPath $Script:EnginePidFile -Value $process.Id -Encoding ASCII
    Start-Sleep -Milliseconds 700
    if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) { throw "winws завершился. Проверьте $Script:EngineErrorLog" }
    Write-Host "Активировано zapret-профилей: $($Rules.Count), PID $($process.Id)" -ForegroundColor Green
}

function Apply-AdaptiveRules {
    $rules = @(Get-AdaptiveRules | Where-Object { $_.Enabled })
    $zapret = @($rules | Where-Object { $_.Mode -eq 'zapret' })
    try {
      Get-NetFirewallRule -DisplayName "$Script:FirewallPrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
      foreach ($rule in @($rules | Where-Object { $_.Mode -eq 'block' })) {
        if (-not $rule.Ip) { throw "Для block-правила нужен точный IP: $($rule.Domain)" }
        $params = @{ DisplayName="$Script:FirewallPrefix$($rule.Id)"; Direction='Outbound'; Action='Block'; Protocol=$rule.Protocol; RemotePort=[int]$rule.Port }
        if ($rule.Ip) { $params.RemoteAddress=$rule.Ip }
        $program = $null
        $processRow = Get-Process -Name $rule.Process -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($processRow -and $processRow.Path) { $program=$processRow.Path }
        if (-not $program) {
            $apps = Join-Path $Script:DataDir 'apps-map.csv'
            if (Test-Path $apps) { $program=(Import-Csv $apps | Where-Object Process -ieq $rule.Process | Select-Object -First 1 -ExpandProperty Image) }
        }
        if (-not $program) { throw "Не найден путь процесса $($rule.Process); глобальная блокировка не создана." }
        $params.Program=$program
          New-NetFirewallRule @params | Out-Null
      }
      if ($zapret.Count -gt 0) {
        if (@($zapret | Where-Object { -not $_.Strategy }).Count) { throw 'У zapret-правила ещё нет проверенной стратегии. Запустите learn <процесс>.' }
        $flowsealStrategies=@($zapret|Where-Object{$_.Strategy -like 'flowseal::*'}|Select-Object -ExpandProperty Strategy -Unique)
        if($flowsealStrategies.Count){
            if($flowsealStrategies.Count -ne 1 -or $flowsealStrategies.Count -ne @($zapret|Select-Object -ExpandProperty Strategy -Unique).Count){throw 'Одновременно можно применить только одну полную стратегию Flowseal.'}
            Start-AdaptiveFlowsealStrategy -StrategyId $flowsealStrategies[0] -Targets $zapret
        }else{Start-AdaptiveRuleSet $zapret}
      } else { Stop-AdaptiveEngine | Out-Null }
      Write-Host 'Правила применены.' -ForegroundColor Green
    } catch {
      Stop-AdaptiveEngine | Out-Null
      Get-NetFirewallRule -DisplayName "$Script:FirewallPrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
      throw "Применение отменено, выполнен откат в direct: $($_.Exception.Message)"
    }
}

function Reset-AdaptiveNetwork {
    Stop-AdaptiveEngine | Out-Null
    Get-NetFirewallRule -DisplayName "$Script:FirewallPrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Write-Host 'Режим direct восстановлен; правила Adaptive Zapret удалены.' -ForegroundColor Green
}

function Find-AdaptiveObservedTarget([string]$ProcessName) {
    $apps = Join-Path $Script:DataDir 'apps-map.csv'
    if (-not (Test-Path -LiteralPath $apps)) { throw 'Сначала выполните apps или запустите сборщик.' }
    $rows = @(Import-Csv -LiteralPath $apps | Where-Object { $_.Process -ieq $ProcessName -and $_.DestinationPort -and $_.Protocol })
    if ($rows.Count -eq 0) { throw "Для процесса $ProcessName целей не найдено." }
    $needle=($ProcessName -replace '[^a-zA-Z0-9]','').ToLowerInvariant()
    $ranked=$rows | ForEach-Object {
        $score=0; $d=[string]$_.Domain
        if($d -and $d -ne '-'){$score+=10;if(($d -replace '[^a-zA-Z0-9]','').ToLowerInvariant().Contains($needle)){$score+=100}}
        if($_.Protocol -eq 'TCP' -and [int]$_.DestinationPort -eq 443){$score+=5}
        if($_.Connections){$score+=[Math]::Min(20,[int]$_.Connections)}
        [pscustomobject]@{Row=$_;Score=$score}
    } | Sort-Object Score -Descending
    return $ranked[0].Row
}

function Enable-AdaptiveAutoStart {
    $launcher=Join-Path $Script:Root 'AdaptiveZapret.ps1'
    $argument="-NoProfile -ExecutionPolicy Bypass -File `"$launcher`" boot"
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
    $trigger=New-ScheduledTaskTrigger -AtLogOn
    $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel Highest -LogonType Interactive
    Register-ScheduledTask -TaskName 'AdaptiveZapret' -Action $action -Trigger $trigger -Principal $principal -Description 'Apply verified Adaptive Zapret rules at logon' -Force | Out-Null
    Write-Host 'Автозапуск правил включён.' -ForegroundColor Green
}

function Disable-AdaptiveAutoStart {
    Unregister-ScheduledTask -TaskName 'AdaptiveZapret' -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'Автозапуск правил выключен.' -ForegroundColor Green
}

function Start-AdaptiveLearning([string]$ProcessName,[string]$Domain='',[string]$Ip='',[int]$Port=0,[string]$Protocol='') {
    if (-not $Domain -and -not $Ip) {
        $target = Find-AdaptiveObservedTarget $ProcessName
        $Domain=$target.Domain; $Ip=$target.DestinationIp; $Port=[int]$target.DestinationPort; $Protocol=$target.Protocol
    }
    $Protocol=$Protocol.ToUpperInvariant()
    Test-AdaptiveSafeTarget $ProcessName $Domain $Ip $Port
    $candidates = @(Get-AdaptiveFlowsealStrategies | Select-Object -ExpandProperty Id)
    if ($candidates.Count -eq 0) { throw "Нет профилей для $Protocol" }
    # The candidate set is the installed Flowseal release itself.  Do not
    # silently truncate it using the legacy synthetic-profile limit.
    $session = [ordered]@{ Process=$ProcessName; Domain=$Domain; Ip=$Ip; Port=$Port; Protocol=$Protocol; Candidates=$candidates; Index=0; ConsecutivePasses=0; PassesRequired=2; EvidenceBaselineBytes=0; Results=@(); StartedUtc=[DateTime]::UtcNow.ToString('o') }
    Write-AdaptiveJson $Script:LearningFile $session
    $rule = [pscustomobject]@{ Process=$ProcessName; Domain=$Domain; Ip=$Ip; Port=$Port; Protocol=$Protocol }
    Start-AdaptiveProfile $rule $candidates[0]
    Write-Host "Попытка 1/$($candidates.Count). Проверьте подключение, затем: test pass или test fail" -ForegroundColor Cyan
}

function Start-AdaptiveLearningGroup([array]$Targets) {
    $targets=@($Targets);if(-not $targets.Count){throw 'Не выбрано ни одной цели.'}
    $protocols=@($targets|ForEach-Object{([string]$_.Protocol).ToUpperInvariant()}|Sort-Object -Unique)
    $processes=@($targets|ForEach-Object{$_.Process}|Sort-Object -Unique)
    foreach($target in $targets){Test-AdaptiveSafeTarget $target.Process $target.Domain $target.Ip ([int]$target.Port)}
    $protocol=($protocols -join '+');$candidates=@(Get-AdaptiveFlowsealStrategies|Select-Object -ExpandProperty Id)
    if(-not $candidates.Count){throw "Нет профилей для $protocol"}
    $session=[ordered]@{Process=($processes -join ', ');Targets=$targets;Protocol=$protocol;Candidates=$candidates;Index=0;ConsecutivePasses=0;PassesRequired=2;EvidenceBaselineBytes=0;Results=@();StartedUtc=[DateTime]::UtcNow.ToString('o')}
    Write-AdaptiveJson $Script:LearningFile $session;Start-AdaptiveLearningGroupProfile -Targets $targets -ProfileId $candidates[0]
    Write-Host "Попытка 1/$($candidates.Count): $($targets.Count) целей." -ForegroundColor Cyan
}

function Start-AdaptiveLearningGroupProfile([array]$Targets,[string]$ProfileId) {
    if($ProfileId -like 'flowseal::*'){
        Start-AdaptiveFlowsealStrategy -StrategyId $ProfileId -Targets $Targets
        foreach($rule in @($Targets|Where-Object Protocol -eq 'TCP')){Restart-AdaptiveTargetConnection -Rule $rule -DelaySeconds 0}
        Write-Host 'Стратегия применена. Ожидание новых TCP/UDP-потоков: 5 сек.' -ForegroundColor Cyan
        Start-Sleep -Seconds 5
        return
    }
    $rules=@($Targets|ForEach-Object{[pscustomobject]@{Process=$_.Process;Domain=$_.Domain;Ip=$_.Ip;Port=[int]$_.Port;Protocol=$_.Protocol;Strategy=$ProfileId}})
    Start-AdaptiveRuleSet $rules
    if($rules[0].Protocol -eq 'TCP'){foreach($rule in $rules){Restart-AdaptiveTargetConnection -Rule $rule -DelaySeconds 0};Write-Host 'Все выбранные TCP-соединения закрыты. Ожидание: 5 сек.' -ForegroundColor Cyan;Start-Sleep -Seconds 5}else{Write-Host 'UDP-профиль применён ко всей выбранной группе.' -ForegroundColor Cyan}
}

function Submit-AdaptiveLearningResult([ValidateSet('pass','fail','skip')][string]$Result) {
    $session = Read-AdaptiveJson $Script:LearningFile $null
    if (-not $session) { throw 'Активного подбора нет. Запустите learn <процесс>.' }
    $current = [string]$session.Candidates[[int]$session.Index]
    $targets=$(if($session.Targets){@($session.Targets)}else{@([pscustomobject]@{Process=$session.Process;Domain=$session.Domain;Ip=$session.Ip;Port=$session.Port;Protocol=$session.Protocol})})
    $evidence=Get-AdaptiveProfileEvidence
    if($Result -eq 'pass' -and $current -like 'flowseal::*' -and [long]$evidence.DebugBytes -le [long]$session.EvidenceBaselineBytes){throw 'Нельзя подтвердить профиль: после запуска проверки winws не увидел новых пакетов. Повторите действие и дождитесь нового соединения.'}
    $resultRow=[pscustomobject]@{ Process=$session.Process; Targets=$targets.Count; Strategy=$current; Result=$Result; DebugLines=$evidence.DebugLines;Recognized=$evidence.Recognized;HostChecks=$evidence.HostChecks;DesyncEvidence=$evidence.DesyncEvidence; TimeUtc=[DateTime]::UtcNow.ToString('o') }
    $session.Results = @($session.Results) + $resultRow
    Add-Content -LiteralPath $Script:StrategyHistoryFile -Value ($resultRow|ConvertTo-Json -Compress) -Encoding UTF8
    if ($Result -eq 'pass') {
        $session.ConsecutivePasses=[int]$session.ConsecutivePasses+1
        if([int]$session.ConsecutivePasses -lt [int]$session.PassesRequired){
            $session.EvidenceBaselineBytes=[long]$evidence.DebugBytes
            Write-AdaptiveJson $Script:LearningFile $session
            if($session.Targets){Start-AdaptiveLearningGroupProfile -Targets $targets -ProfileId $current}else{$repeatRule=[pscustomobject]@{Process=$session.Process;Domain=$session.Domain;Ip=$session.Ip;Port=[int]$session.Port;Protocol=$session.Protocol};Restart-AdaptiveTargetConnection -Rule $repeatRule -DelaySeconds 5}
            Write-Host "Первый успех отмечен. Повторите подключение с тем же профилем и снова выполните test pass/fail." -ForegroundColor Cyan
            return
        }
        foreach($target in $targets){Add-AdaptiveRule -Process $target.Process -Domain $target.Domain -Ip $target.Ip -Port ([int]$target.Port) -Protocol $target.Protocol -Mode zapret -Strategy $current}
        Remove-Item -LiteralPath $Script:LearningFile -Force
        Write-Host "Рабочая стратегия сохранена: $current. Она уже активна." -ForegroundColor Green
        return
    }
    $session.ConsecutivePasses=0
    $session.EvidenceBaselineBytes=0
    $session.Index = [int]$session.Index + 1
    if ($session.Index -ge @($session.Candidates).Count) {
        Write-AdaptiveJson (Join-Path $Script:DataDir ("learning-failed-{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))) $session
        Remove-Item -LiteralPath $Script:LearningFile -Force
        Reset-AdaptiveNetwork
        Write-Host 'Безопасные профили закончились; сеть возвращена в direct.' -ForegroundColor Yellow
        return
    }
    Write-AdaptiveJson $Script:LearningFile $session
    $next = [string]$session.Candidates[[int]$session.Index]
    if($session.Targets){Start-AdaptiveLearningGroupProfile -Targets $targets -ProfileId $next}else{$rule=[pscustomobject]@{Process=$session.Process;Domain=$session.Domain;Ip=$session.Ip;Port=[int]$session.Port;Protocol=$session.Protocol};Start-AdaptiveProfile $rule $next}
    Write-Host "Попытка $([int]$session.Index + 1)/$(@($session.Candidates).Count): $next. Затем test pass или test fail" -ForegroundColor Cyan
}

function Export-AdaptiveAutoBatch {
    $rules = @(Get-AdaptiveRules | Where-Object { $_.Enabled -and $_.Mode -eq 'zapret' -and $_.Strategy })
    if (-not $rules.Count) { throw 'Нет проверенного zapret-правила для экспорта.' }
    $flow=@($rules|Where-Object{$_.Strategy -like 'flowseal::*'}|Select-Object -ExpandProperty Strategy -Unique)
    if($flow.Count){
      if($flow.Count -ne 1){throw 'Экспорт нескольких разных полных стратегий Flowseal не поддерживается.'}
      $strategy=@(Get-AdaptiveFlowsealStrategies|Where-Object Id -eq $flow[0])|Select-Object -First 1
      $engine=Resolve-AdaptiveEngine;$arguments=Get-AdaptiveFlowsealCommand -BatPath $strategy.Path -Targets $rules
      $path=Join-Path $Script:Root 'general (AUTO).bat'
      $line='start "Adaptive Zapret AUTO" /min "' + $engine.Winws + '" ' + $arguments
      Set-Content -LiteralPath $path -Value @('@echo off','chcp 65001 > nul',('cd /d "'+$engine.Bin+'"'),$line) -Encoding UTF8
      Write-Host "Экспортирована полная стратегия Flowseal: $($strategy.Name). Файл: $path" -ForegroundColor Green
      return
    }
    $tcpPorts=@($rules|Where-Object Protocol -eq TCP|ForEach-Object Port|Sort-Object -Unique)
    $udpPorts=@($rules|Where-Object Protocol -eq UDP|ForEach-Object Port|Sort-Object -Unique)
    $args=@();if($tcpPorts.Count){$args+='--wf-tcp='+($tcpPorts -join ',')};if($udpPorts.Count){$args+='--wf-udp='+($udpPorts -join ',')}
    $first=$true
    foreach($rule in $rules){
      $profile=Get-AdaptiveProfile $rule.Strategy;if(-not $first){$args+='--new'};$first=$false
      $args+=$(if($rule.Protocol -eq 'TCP'){"--filter-tcp=$($rule.Port)"}else{"--filter-udp=$($rule.Port)"})
      $args+=$(if($rule.Domain){"--hostlist-domains=$($rule.Domain)"}else{"--ipset-ip=$($rule.Ip)"})
      $args+=@($profile.Args)
    }
    $engine=Resolve-AdaptiveEngine
    if(-not $engine){throw 'winws.exe не найден.'}
    $path = Join-Path $Script:Root 'general (AUTO).bat'
    $lines = @('@echo off','chcp 65001 > nul',('cd /d "'+$engine.Bin+'"'),('start "Adaptive Zapret AUTO" /min "'+$engine.Winws+'" ' + ($args -join ' ')))
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
    Write-Host "Экспортировано правил: $($rules.Count). Файл: $path" -ForegroundColor Green
}

function Get-AdaptiveEngineStatus {
    $engine = Resolve-AdaptiveEngine
    $managed = Get-AdaptiveManagedProcess
    [pscustomobject]@{ Engine=$(if($engine){$engine.Winws}else{'не найден'}); ManagedWinws=$(if($managed){"Running PID $($managed.Id)"}else{'Stopped'}); Rules=@(Get-AdaptiveRules).Count; Learning=Test-Path -LiteralPath $Script:LearningFile }
}

function Test-AdaptiveEngineSelf {
    Initialize-AdaptiveConfiguration
    $flowseal=@(Get-AdaptiveFlowsealStrategies)
    if(-not (Resolve-AdaptiveEngine)){Write-Host 'Engine self-test: приложение исправно; Flowseal ещё не установлен (выполните setup).' -ForegroundColor Yellow;return}
    if(-not $flowseal.Count){throw 'Найден winws.exe, но отсутствуют стратегии general*.bat полного комплекта Flowseal.'}
    foreach($strategy in $flowseal){
        $text=Get-Content -LiteralPath $strategy.Path -Raw
        if($text -notmatch 'winws\.exe' -or $text -notmatch '--dpi-desync'){throw "Некорректная стратегия Flowseal: $($strategy.Path)"}
    }
    Write-Host "Engine self-test: OK ($($flowseal.Count) полных стратегий Flowseal)" -ForegroundColor Green
}

Initialize-AdaptiveConfiguration
Invoke-AdaptiveConfigurationMigration
Export-ModuleMember -Function '*-Adaptive*'
