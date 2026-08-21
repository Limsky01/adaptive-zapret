[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Root,[string]$PackagePath='')

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
$runtime=Join-Path $Root 'data\runtime\update'
$log=Join-Path $Root 'data\update.log'
$publicModulus='F8D7C10E6D931C0B320183181B6D0FBDE8DA86C8DEE0414FA07FB18398B398C06E89C173D07543C084D35EED2B873E6E7C51D37ED51334DF274E31086B75C11BB3C519D372C3D33D111600A641DA3C6CD4F44B8C0D8B04B1680F53A9A75EC0999102F4AB6B2430D0A75443A419C5B30EB74FE6458591CABB3AC682A7B1761DE97BBC693FABCED32087BCDC76E0E72065FFEAD4782B8A7DD3A254394C2855EF7DAED89D3DCF95C12C46CAC1A9E2582452C9D017BDE82C872879E101DE950BC584F230E8110D5716B2EF1A0AFBB32F01DDAFA643C7C49CA0D12964160F28B1B689E74F15A3E4B5416502FE23C6FCC3208E804FC1DF10663D3F343BA732FAEE9F1D3E2AE4081465825EE86949B5384D71D329D2B8135B823C42A16E4981DA352E2D1BF221986C1C8D5BE142EE753339911274C512460CEF0904BC7136CD1D9063DF2D4C2A99EA5E7110B79619353E7330299CFDF1570063B88D9FD06FA0600917FFDA2222E368AE7970CCBEFCB56048A7D6A68363F5DCDAFB9A1E388EAE09BE2555'

function Write-UpdateLog([string]$Text){New-Item -ItemType Directory -Path (Split-Path $log) -Force|Out-Null;Add-Content -LiteralPath $log -Encoding UTF8 -Value ('{0} {1}' -f [DateTime]::Now.ToString('s'),$Text)}
function Compare-Version([string]$Left,[string]$Right){return ([version]$Left).CompareTo([version]$Right)}
function Convert-Hex([string]$Hex){$bytes=New-Object byte[] ($Hex.Length/2);for($i=0;$i-lt$bytes.Length;$i++){$bytes[$i]=[Convert]::ToByte($Hex.Substring($i*2,2),16)};return $bytes}
function Test-ReleaseSignature($Manifest){
    if(-not $Manifest.Signature){throw 'Манифест не подписан.'}
    $rsa=New-Object Security.Cryptography.RSACryptoServiceProvider
    try{$rsa.ImportParameters([Security.Cryptography.RSAParameters]@{Modulus=(Convert-Hex $publicModulus);Exponent=[byte[]](1,0,1)})
        $payload='{0}|{1}|{2}' -f $Manifest.Version,$Manifest.PackageUrl,$Manifest.Sha256.ToUpperInvariant()
        return $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes($payload),'SHA256',[Convert]::FromBase64String($Manifest.Signature))
    }finally{$rsa.Dispose()}
}
function Copy-ProgramBackup([string]$Destination){
    New-Item -ItemType Directory -Path $Destination -Force|Out-Null
    Get-ChildItem -LiteralPath $Root -Force|Where-Object{$_.Name -notin @('data','config','engine')}|ForEach-Object{Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force}
}
function Restore-ProgramBackup([string]$Backup){
    Get-ChildItem -LiteralPath $Root -Force|Where-Object{$_.Name -notin @('data','config','engine')}|Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $Backup -Force|ForEach-Object{Copy-Item -LiteralPath $_.FullName -Destination $Root -Recurse -Force}
}

try{
    Write-UpdateLog 'Update started.'
    New-Item -ItemType Directory -Path $runtime -Force|Out-Null
    $current=(Get-Content (Join-Path $Root 'VERSION') -Raw).Trim()
    $manifest=$null
    if(-not $PackagePath){
        $settings=Get-Content (Join-Path $Root 'config\settings.json') -Raw|ConvertFrom-Json
        if(-not $settings.UpdateManifestUrl){throw 'Канал обновлений не настроен.'}
        $manifest=Invoke-RestMethod -Uri $settings.UpdateManifestUrl -Headers @{'User-Agent'='AdaptiveZapret-Updater'}
        if(-not (Test-ReleaseSignature $manifest)){throw 'Цифровая подпись манифеста недействительна.'}
        if((Compare-Version $manifest.Version $current)-le 0){[Windows.Forms.MessageBox]::Show("Установлена актуальная версия $current.",'Adaptive Zapret')|Out-Null;exit 0}
        $PackagePath=Join-Path $runtime 'release.zip'
        Invoke-WebRequest -Uri $manifest.PackageUrl -OutFile $PackagePath
        if((Get-FileHash $PackagePath -Algorithm SHA256).Hash -ne $manifest.Sha256){throw 'SHA-256 загруженного архива не совпадает с манифестом.'}
    }
    if(-not (Test-Path -LiteralPath $PackagePath)){throw 'Архив обновления не найден.'}
    $stage=Join-Path $runtime ('stage-'+[guid]::NewGuid().ToString('N'));Expand-Archive -LiteralPath $PackagePath -DestinationPath $stage -Force
    $source=$stage;$children=@(Get-ChildItem $stage);if($children.Count -eq 1 -and $children[0].PSIsContainer){$source=$children[0].FullName}
    $newVersionFile=Join-Path $source 'VERSION';if(-not (Test-Path $newVersionFile)){throw 'Это не архив Adaptive Zapret: отсутствует VERSION.'}
    $newVersion=(Get-Content $newVersionFile -Raw).Trim();if((Compare-Version $newVersion $current) -le 0){throw "Версия архива $newVersion не новее установленной $current."}
    if($manifest -and $newVersion -ne $manifest.Version){throw 'Версия внутри архива не совпадает с манифестом.'}
    $backup=Join-Path $runtime ('backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'));Copy-ProgramBackup $backup
    try{
        Get-ChildItem -LiteralPath $source -Force|Where-Object{$_.Name -notin @('data','config','engine')}|ForEach-Object{Copy-Item -LiteralPath $_.FullName -Destination $Root -Recurse -Force}
        $tokens=$null;$errors=$null;Get-ChildItem $Root -Filter 'AdaptiveZapret*.ps1'|ForEach-Object{$null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors);if($errors.Count){throw "Ошибка синтаксиса после обновления: $($_.Name)"}}
    }catch{Restore-ProgramBackup $backup;throw}
    Write-UpdateLog "Updated $current -> $newVersion. Backup: $backup"
    [Windows.Forms.MessageBox]::Show("Обновление установлено: $current → $newVersion.`r`nПриложение будет перезапущено.",'Adaptive Zapret')|Out-Null
    Start-Process (Join-Path $Root 'AdaptiveZapret.cmd')
}catch{
    Write-UpdateLog ('ERROR: '+($_|Out-String))
    [Windows.Forms.MessageBox]::Show(("Обновление не установлено.`r`n`r`n{0}`r`n`r`nЖурнал: {1}" -f $_.Exception.Message,$log),'Adaptive Zapret — обновление','OK','Error')|Out-Null
    exit 1
}
