param([ValidateSet('Apply','Undo','Status')][string]$Mode='Status',[switch]$CompileOnly)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Read-DxgTraceConsumers.ps1') -CompileOnly | Out-Null
. (Join-Path $PSScriptRoot 'Read-DiagLogProviderConfiguration.ps1')
. (Join-Path $PSScriptRoot 'WorkaroundData.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'DiagLogKeywordControl.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'WdiRegistryAccess.cs')
[DiagLogKeywordControl]::ValidateLayout() | Out-Null
if($CompileOnly){
    & (Join-Path $PSScriptRoot 'Measure-GpuQueryCPU.ps1') -CompileOnly
    'Compilation succeeded; no system configuration changes.'
    return
}
if(-not([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))){throw 'Run in a 64-bit administrator Windows PowerShell.'}
$dataRoot=Get-WorkaroundDataDirectory
$machineId=Get-WorkaroundMachineId
$subkey='SYSTEM\CurrentControlSet\Control\WDI\Scenarios\{186f47ef-626c-4670-800a-4a30756babad}\Instrumentation\{802ec45a-1e99-4b83-9920-87c98277ba9d};2'
$registryPath='HKEY_LOCAL_MACHINE\'+$subkey
$provider=[Guid]'802ec45a-1e99-4b83-9920-87c98277ba9d'
$backupPath=Join-Path $dataRoot 'original-backup.json'
$statusPath=Join-Path $dataRoot ('workaround-'+$Mode.ToLowerInvariant()+'-status.json')
$key=$null;$base=$null;$registryChanged=$false;$runtimeAttempted=$false;$handle=[UInt64]0
$registryBefore=[Int64]0;$runtimeBefore=[UInt64]0
$result=[ordered]@{Version='0.1.3';Mode=$Mode;Time=(Get-Date -Format o);RegistryPath=$registryPath;Status='Started';Error=$null;DataDirectory=$dataRoot;RebootPersistence='Not evaluated by this command'}
function ReadRuntime([string]$name){
    $s=[DxgEtwReadOnly]::Read($provider)
    if($s.SessionQueryStatus -ne 0 -or $s.ProviderQueryStatus -ne 0){throw 'ETW enumeration failed.'}
    # Keep only the provider consumers and their associated sessions in local logs.
    $names=@($s.Consumers.SessionName)
    [pscustomobject]@{CapturedUtc=$s.CapturedUtc;ProviderGuid=$s.ProviderGuid;Consumers=$s.Consumers;Sessions=@($s.Sessions|Where-Object{$_.Name -in $names})}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $dataRoot ('workaround-'+$Mode.ToLowerInvariant()+'-'+$name+'.json')) -Encoding UTF8
    return $s
}
function CheckRuntime($state){
    $session=@($state.Sessions|Where-Object Name -eq 'DiagLog')
    if($session.Count -ne 1 -or $session[0].Guid -ne '08b524eb-a2bf-47eb-aef1-dbd871741d7a'){throw 'Expected DiagLog session is not running.'}
    $entries=@($state.Consumers|Where-Object SessionName -eq 'DiagLog')
    if($entries.Count -eq 0){throw 'Expected DxgKrnl provider is missing.'}
    $masks=@($entries.MatchAnyKeyword|Select-Object -Unique)
    if($masks.Count -ne 1 -or $masks[0] -notin @('0x0000000002030000','0x0000000000030000')){throw 'Unexpected DxgKrnl keywords; no automatic overwrite.'}
    foreach($entry in $entries){if($entry.IsEnabled -ne 1 -or $entry.Level -ne 255 -or $entry.MatchAllKeyword -ne '0x0000000000000000' -or $entry.EnableProperty -notin @(0,64)){throw 'Unexpected provider settings.'}}
    return [pscustomobject]@{Handle=[UInt64]$session[0].HistoricalContext;Mask=[Convert]::ToUInt64($masks[0].Substring(2),16)}
}
function Assert-TaskManagerClosed {
    if(Get-Process -Name Taskmgr -ErrorAction SilentlyContinue){
        throw 'Close Task Manager during the comparison. Its own GPU queries can affect the measurement.'
    }
}
function Measure-GpuPhase([string]$Phase,[string]$ExpectedAdapterId){
    Assert-TaskManagerClosed
    $outputPath=Join-Path $result.CpuComparison.ReportDirectory ($Phase+'.json')
    $errorPath=Join-Path $result.CpuComparison.ReportDirectory ($Phase+'-error.txt')
    $probePath=Join-Path $PSScriptRoot 'Measure-GpuQueryCPU.ps1'
    $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$probePath+'"'),'-OutputFile',('"'+$outputPath+'"'))
    if($ExpectedAdapterId){
        if($ExpectedAdapterId -cnotmatch '^[0-9A-F]{16}$'){throw 'Invalid adapter identifier from the first measurement.'}
        $arguments+=@('-ExpectedAdapterId',$ExpectedAdapterId)
    }
    $worker=Start-Process -FilePath $psExe -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardError $errorPath -PassThru
    try{
        # Windows PowerShell can lose the exit code if it never opens a process handle.
        $null=$worker.Handle
        if(-not $worker.WaitForExit(40000)){throw 'The GPU query measurement exceeded its 40-second time limit.'}
        if($worker.ExitCode -ne 0){
            $detail=([string](Get-Content -LiteralPath $errorPath -Raw)).Trim()
            throw ('The GPU query measurement failed. '+$detail)
        }
    }finally{
        try{if(-not $worker.HasExited){$worker.Kill();[void]$worker.WaitForExit(3000)}}
        finally{$worker.Dispose()}
    }
    Assert-TaskManagerClosed
    $measurement=Get-Content -LiteralPath $outputPath -Raw|ConvertFrom-Json
    if($measurement.SampleCount -ne 20 -or @($measurement.Samples).Count -ne 20){throw 'The GPU query measurement is incomplete.'}
    return $measurement | Select-Object Adapter,AdapterId,SampleCount,AveragePercent,PeakPercent,AverageQueryMilliseconds
}
try{
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    if($Mode -eq 'Status'){$key=$base.OpenSubKey($subkey,$false)}else{$key=[WdiRegistryAccess]::OpenExistingReviewedKey()}
    if($null -eq $key){throw 'WDI instrumentation key is absent.'}
    $registryBefore=[Int64]$key.GetValue('Keyword')
    $result.SecurityDescriptor=$key.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
    if($key.GetValueKind('Keyword') -ne [Microsoft.Win32.RegistryValueKind]::QWord -or $registryBefore -notin @(33554432,65536)){throw 'Unexpected WDI registry value/type; no automatic overwrite.'}
    $runtime=CheckRuntime (ReadRuntime 'before')
    $handle=$runtime.Handle;$runtimeBefore=$runtime.Mask
    $result.RegistryBeforeHex=('0x{0:X}' -f $registryBefore)
    $result.RuntimeBeforeHex=('0x{0:X}' -f $runtimeBefore)
    $configuration=Read-DiagLogProviderConfiguration
    $configuration|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $dataRoot ('workaround-'+$Mode.ToLowerInvariant()+'-filters-before.json')) -Encoding UTF8
    Assert-DiagLogProviderConfiguration $configuration $handle $runtimeBefore
    $result.FilterVerification='PLA API: no provider filter; configuration matched native ETW snapshot'
    if($Mode -eq 'Status'){
        $result.Status='ReadOnly'
        $result.BackupPresent=Test-Path -LiteralPath $backupPath
    }else{
        if($Mode -eq 'Apply'){
            if($registryBefore -ne 33554432 -or $runtimeBefore -ne 0x2030000){
                throw 'The before/after comparison requires the original configuration in both the registry and DiagLog. Use option 1 to check the current state.'
            }
            $comparisonDirectory=Join-Path $dataRoot ('comparison-'+[Guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($comparisonDirectory)|Out-Null
            $result.CpuComparison=[ordered]@{Status='MeasuringBefore';ReportDirectory=$comparisonDirectory}
            Write-Output '[progress] 1/3 Measuring BEFORE: querying NVIDIA performance data once per second under the original configuration.'
            Write-Output '[progress]     Collecting 20 CPU samples after 3 warm-up queries. Keep Task Manager and other monitors closed.'
            $result.CpuComparison.Before=Measure-GpuPhase 'before' ''
            $result.CpuComparison.Status='BeforeMeasured'
            Write-Output ('[progress]     Before: System CPU average {0:F2}%, peak {1:F2}%.' -f $result.CpuComparison.Before.AveragePercent,$result.CpuComparison.Before.PeakPercent)
            $current=CheckRuntime (ReadRuntime 'before-write')
            if($current.Handle -ne $handle -or $current.Mask -ne $runtimeBefore -or [Int64]$key.GetValue('Keyword') -ne $registryBefore){
                throw 'The configuration changed during the before measurement. Run Check before retrying.'
            }
            Assert-DiagLogProviderConfiguration (Read-DiagLogProviderConfiguration) $handle $runtimeBefore
            Write-Output '[progress] 2/3 Saving or verifying the backup, applying the DiagLog workaround and verifying the new configuration.'
        }
        if(Test-Path -LiteralPath $backupPath){
            $backup=Get-Content -LiteralPath $backupPath -Raw|ConvertFrom-Json
            Assert-WorkaroundBackup $backup $machineId $registryPath
        }elseif($Mode -eq 'Apply'){
            if($registryBefore -ne 33554432 -or $runtimeBefore -ne 0x2030000){throw 'Original registry and runtime configuration required for the first backup. If already adjusted by another tool, use that tool to restore first.'}
            $backup=[pscustomobject]@{SchemaVersion=1;Created=(Get-Date -Format o);MachineId=$machineId;Path=$registryPath;ValueName='Keyword';ValueKind='QWord';OriginalValue=[Int64]33554432;ReplacementValue=[Int64]65536;OriginalRuntimeMask=[UInt64]0x2030000;ReplacementRuntimeMask=[UInt64]0x30000;SecurityDescriptor=$result.SecurityDescriptor}
            $bytes=[Text.Encoding]::UTF8.GetBytes(($backup|ConvertTo-Json -Depth 5))
            $stream=[IO.File]::Open($backupPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}finally{$stream.Dispose()}
        }else{throw 'This edition has no original backup for this installation. Do not use someone else''s backup.'}
        if($Mode -eq 'Apply'){$targetRegistry=[Int64]65536;$targetRuntime=[UInt64]0x30000}
        else{$targetRegistry=[Int64]$backup.OriginalValue;$targetRuntime=[UInt64]$backup.OriginalRuntimeMask}
        if($registryBefore -ne $targetRegistry){$registryChanged=$true;$key.SetValue('Keyword',$targetRegistry,[Microsoft.Win32.RegistryValueKind]::QWord);$key.Flush()}
        if([Int64]$key.GetValue('Keyword') -ne $targetRegistry){throw 'Registry verification failed.'}
        $result.SecurityDescriptorUnchanged=($key.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All) -eq $result.SecurityDescriptor)
        if(-not $result.SecurityDescriptorUnchanged){throw 'Registry permissions changed unexpectedly.'}
        if($runtimeBefore -ne $targetRuntime){$runtimeAttempted=$true;[DiagLogKeywordControl]::SetKeywords($handle,$targetRuntime)}
        $checked=CheckRuntime (ReadRuntime 'after')
        if($checked.Handle -ne $handle -or $checked.Mask -ne $targetRuntime){throw 'Runtime verification failed.'}
        $result.RegistryAfterHex=('0x{0:X}' -f [Int64]$key.GetValue('Keyword'))
        $result.RuntimeAfterHex=('0x{0:X}' -f $checked.Mask)
        $result.Status=$(if($Mode -eq 'Apply'){'Applied'}else{'Restored original registry and runtime keywords'})
        $registryChanged=$false;$runtimeAttempted=$false
    }
}catch{
    $result.Status='Failed';$result.Error=($_|Out-String)
    if($result.CpuComparison){$result.CpuComparison.Status='Interrupted';$result.CpuComparison.Error=$_.Exception.Message}
    if($registryChanged -and $key){try{$key.SetValue('Keyword',$registryBefore,[Microsoft.Win32.RegistryValueKind]::QWord);$key.Flush();$result.RegistryRollback='Succeeded'}catch{$result.RegistryRollback=($_|Out-String)}}
    if($runtimeAttempted -and $handle){try{$live=CheckRuntime ([DxgEtwReadOnly]::Read($provider));if($live.Handle -ne $handle){throw 'Session changed; runtime rollback refused.'};[DiagLogKeywordControl]::SetKeywords($handle,$runtimeBefore);$result.RuntimeRollback='Succeeded'}catch{$result.RuntimeRollback=($_|Out-String)}}
}finally{
    if($key){$key.Dispose()};if($base){$base.Dispose()}
}
if($Mode -eq 'Apply' -and $result.Status -eq 'Applied'){
    Write-Output '[progress] 3/3 Configuration applied. Measuring AFTER with the same query, adapter and sampling interval.'
    try{
        $result.CpuComparison.After=Measure-GpuPhase 'after' $result.CpuComparison.Before.AdapterId
        $current=CheckRuntime (ReadRuntime 'after-measurement')
        $currentKeyword=[Microsoft.Win32.Registry]::GetValue($registryPath,'Keyword',$null)
        if($current.Handle -ne $handle -or $current.Mask -ne $targetRuntime -or $currentKeyword -ne $targetRegistry){
            throw 'The configuration changed during the after measurement.'
        }
        Assert-DiagLogProviderConfiguration (Read-DiagLogProviderConfiguration) $handle $targetRuntime
        $result.CpuComparison.Status='Completed'
        $result.CpuComparison.ReductionPercentagePoints=$result.CpuComparison.Before.AveragePercent-$result.CpuComparison.After.AveragePercent
    }catch{
        $result.CpuComparison.Status='Incomplete'
        $result.CpuComparison.Error=$_.Exception.Message
    }
}
$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $statusPath -Encoding UTF8
$result|ConvertTo-Json -Depth 6
if($result.Status -eq 'Failed'){exit 1}
