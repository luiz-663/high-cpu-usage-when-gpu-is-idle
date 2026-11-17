# Offline only: no registry writes, trace reconfiguration, or live PLA queries.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'src'
$passed=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw ('FAILED: '+$Name)};$script:passed++;Write-Output ('PASS: '+$Name)}
foreach($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse){
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null
    Check ($errors.Count -eq 0) ('PowerShell syntax: '+$file.Name)
}
. (Join-Path $source 'Read-DiagLogProviderConfiguration.ps1')
. (Join-Path $source 'WorkaroundData.ps1')
& (Join-Path $source 'Read-DxgTraceConsumers.ps1') -CompileOnly|Out-Null
Add-Type -Path (Join-Path $source 'DiagLogKeywordControl.cs')
Add-Type -Path (Join-Path $source 'WdiRegistryAccess.cs')
[DiagLogKeywordControl]::ValidateLayout()|Out-Null
Check $true 'Native x64 layouts and helper compilation'
$fixture=@'
<DataCollectorSet><Name>DiagLog</Name><Status>1</Status><Description>Translated label</Description><TraceDataCollector><Guid>{08B524EB-A2BF-47EB-AEF1-DBD871741D7A}</Guid><SessionName>DiagLog</SessionName><TraceDataProvider><Guid>{802EC45A-1E99-4B83-9920-87C98277BA9D}</Guid><DisplayName>A translated name</DisplayName><FilterEnabled>0</FilterEnabled><FilterType>0</FilterType><Level><Value>255</Value></Level><KeywordsAny><Value>0x2030000</Value></KeywordsAny><KeywordsAll><Value>0x0</Value></KeywordsAll><Properties><Value>64</Value></Properties></TraceDataProvider></TraceDataCollector></DataCollectorSet>
'@
$oldCulture=[Threading.Thread]::CurrentThread.CurrentCulture
$oldUICulture=[Threading.Thread]::CurrentThread.CurrentUICulture
try{
    foreach($locale in @('pt-BR','en-US','es-ES','de-DE','fr-FR','ja-JP','tr-TR')){
        [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($locale)
        [Threading.Thread]::CurrentThread.CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo($locale)
        Assert-DiagLogProviderConfiguration (ConvertFrom-DiagLogProviderXml $fixture 7) 7 0x2030000
        Check $true ('Invariant XML configuration: '+$locale)
    }
}finally{
    [Threading.Thread]::CurrentThread.CurrentCulture=$oldCulture
    [Threading.Thread]::CurrentThread.CurrentUICulture=$oldUICulture
}
foreach($mutation in @(
    @{Name='Nonzero filter type';From='<FilterType>0</FilterType>';To='<FilterType>1</FilterType>'},
    @{Name='Enabled filter';From='<FilterEnabled>0</FilterEnabled>';To='<FilterEnabled>-1</FilterEnabled>'},
    @{Name='Filter payload';From='</TraceDataProvider>';To='<FilterData>AAAA</FilterData></TraceDataProvider>'},
    @{Name='Missing filter type';From='<FilterType>0</FilterType>';To=''},
    @{Name='Wrong keyword mask';From='0x2030000';To='0x1'},
    @{Name='Wrong session GUID';From='08B524EB-A2BF-47EB-AEF1-DBD871741D7A';To='00000000-0000-0000-0000-000000000001'},
    @{Name='Wrong provider';From='802EC45A-1E99-4B83-9920-87C98277BA9D';To='00000000-0000-0000-0000-000000000002'}
)){
    $rejected=$false
    try{Assert-DiagLogProviderConfiguration (ConvertFrom-DiagLogProviderXml ($fixture.Replace($mutation.From,$mutation.To)) 7) 7 0x2030000}catch{$rejected=$true}
    Check $rejected ('Refused: '+$mutation.Name)
}
$rejected=$false
try{Assert-DiagLogProviderConfiguration (ConvertFrom-DiagLogProviderXml $fixture 8) 7 0x2030000}catch{$rejected=$true}
Check $rejected 'Refused mismatched session handle'
$rejected=$false
try{ConvertFrom-DiagLogProviderXml ('<!DOCTYPE x [<!ENTITY y "bad">]>'+$fixture) 7|Out-Null}catch{$rejected=$true}
Check $rejected 'DTD prohibited'
$backup=[pscustomobject]@{SchemaVersion=1;MachineId=('a'*64);Path='reviewed-path';ValueName='Keyword';ValueKind='QWord';OriginalValue=33554432;ReplacementValue=65536;OriginalRuntimeMask=33751040;ReplacementRuntimeMask=196608;SecurityDescriptor='test-descriptor'}
Assert-WorkaroundBackup $backup ('a'*64) 'reviewed-path'
Check $true 'Matching installation backup accepted'
foreach($mutation in @(@{Field='MachineId';Value=('b'*64)},@{Field='OriginalValue';Value=0},@{Field='Path';Value='other-path'},@{Field='SchemaVersion';Value=2})){
    $changed=$backup|Select-Object *;$changed.($mutation.Field)=$mutation.Value
    $rejected=$false
    try{Assert-WorkaroundBackup $changed ('a'*64) 'reviewed-path'}catch{$rejected=$true}
    Check $rejected ('Backup mismatch refused: '+$mutation.Field)
}
$cmdPath=Join-Path $root 'dist\DxgKrnl-DiagLog-CPU-Workaround.cmd'
$cmd=[IO.File]::ReadAllText($cmdPath)
$marker=':GPU_IDLE_CPU_PAYLOAD_V1'
$position=$cmd.LastIndexOf($marker)
Check ($position -ge 0) 'Standalone payload present'
$package=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cmd.Substring($position+$marker.Length).Trim()))|ConvertFrom-Json
Check (-not $package.PSObject.Properties['OriginalMachineGuid'] -and -not $package.PSObject.Properties['OriginalBackup']) 'No bundled installation identity or historical backup'
foreach($file in $package.Files){
    $bytes=[Convert]::FromBase64String($file.Data)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
    Check ($hash -eq $file.Hash) ('Embedded hash: '+$file.Name)
    $decoded=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) -replace '\r?\n',"`n"
    $original=[IO.File]::ReadAllText((Join-Path $source $file.Name)) -replace '\r?\n',"`n"
    Check ($decoded -ceq $original) ('Embedded source matches: '+$file.Name)
    Check ($decoded -notmatch 'C:\\Users\\|OriginalMachineGuid|OriginalBackup|diaglog-wdi-backup-nov16') ('No investigation data in: '+$file.Name)
}
$expected=(Get-Content -LiteralPath (Join-Path $root 'dist\SHA256SUMS.txt') -Raw).Split(' ')[0]
Check ((Get-FileHash -LiteralPath $cmdPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected) 'Distribution SHA256SUMS matches'
& $env:ComSpec /d /c ('"'+$cmdPath+'" /check')
Check ($LASTEXITCODE -eq 0) 'Single-file extraction and compile check'
Write-Output ('All '+$passed+' offline checks passed. No system configuration changes.')
