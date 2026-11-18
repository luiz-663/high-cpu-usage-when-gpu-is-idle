param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
try {
    foreach($name in @('Set-Workaround.ps1','WorkaroundData.ps1','Read-DxgTraceConsumers.ps1','Read-DiagLogProviderConfiguration.ps1','DiagLogKeywordControl.cs','WdiRegistryAccess.cs','Measure-SystemCPU.ps1','Measure-GpuQueryCPU.ps1','GpuQueryProbe.cs')) {
        if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)){throw ('Required file missing: '+$name)}
    }
    if($CheckOnly){'Package files verified; no system configuration changes.';exit 0}
    . (Join-Path $PSScriptRoot 'WorkaroundData.ps1')
    $dataRoot=Get-WorkaroundDataDirectory
    $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    while($true) {
        Write-Host ''
        Write-Host 'HIGH CPU USAGE WHEN THE GPU IS IDLE v0.1.3'
        Write-Host 'Experimental Windows workaround'
        Write-Host 'Preserves GPU sleep settings; configuration must match.'
        Write-Host '1 - Check configuration (read-only)'
        Write-Host '2 - Measure, apply workaround, and measure again'
        Write-Host '3 - Restore original configuration'
        Write-Host '0 - Exit'
        $choice=Read-Host 'Choose an option'
        if($choice -eq '0'){break}
        $mode=switch($choice){'1'{'Status'};'2'{'Apply'};'3'{'Undo'};default{$null}}
        if(-not $mode){Write-Host 'Invalid option.';continue}
        if($mode -eq 'Apply'){
            Write-Host 'The comparison takes about one minute. Keep the NVIDIA GPU free of graphics workloads.'
            Write-Host 'Close Task Manager and other GPU monitors before the test.'
            if(Get-Process -Name Taskmgr -ErrorAction SilentlyContinue){
                Write-Host 'Task Manager is open. Close it and choose option 2 again.' -ForegroundColor Yellow
                continue
            }
            Write-Host 'Checking the original registry and live DiagLog configuration.'
        }
        elseif($mode -eq 'Undo'){Write-Host 'Restoring the original configuration; the elevated CPU symptom may return.'}
        $started=Get-Date
        $log=Join-Path $dataRoot ('menu-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.log')
        & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Set-Workaround.ps1') -Mode $mode 2>&1|
            Tee-Object -FilePath $log|ForEach-Object {
                $line=[string]$_
                if($line.StartsWith('[progress] ')){Write-Host $line.Substring(11)}
            }
        $code=$LASTEXITCODE
        if($code -ne 0){
            Write-Host ('Operation failed. Read the log before retrying: '+$log) -ForegroundColor Yellow
            Get-Content -LiteralPath $log -Tail 12|ForEach-Object{Write-Host $_}
            continue
        }
        $result=Get-Content -LiteralPath (Join-Path $dataRoot ('workaround-'+$mode.ToLowerInvariant()+'-status.json')) -Raw|ConvertFrom-Json
        if([datetimeoffset]$result.Time -lt [datetimeoffset]$started -or $result.Status -eq 'Failed'){throw 'No successful current operation report was produced.'}
        if($mode -eq 'Status'){
            Write-Host ('Registry: '+$result.RegistryBeforeHex+' | Live session: '+$result.RuntimeBeforeHex)
            if($result.RegistryBeforeHex -eq '0x10000' -and $result.RuntimeBeforeHex -eq '0x30000') {Write-Host 'WORKAROUND ACTIVE in registry and live session.' -ForegroundColor Green}
            elseif($result.RegistryBeforeHex -eq '0x2000000' -and $result.RuntimeBeforeHex -eq '0x2030000') {Write-Host 'ORIGINAL CONFIGURATION ACTIVE.'}
            else{Write-Host 'Registry and live session differ; inspect the reports.'}
            if(-not $result.BackupPresent){Write-Host 'This public edition has no original backup for this installation.'}
            Write-Host 'Checking configuration does not measure CPU or confirm physical D3cold.'
        }elseif($mode -eq 'Apply'){
            Write-Host 'WORKAROUND APPLIED.' -ForegroundColor Green
            $comparison=$result.CpuComparison
            if($comparison.Status -eq 'Completed'){
                $border='+'+('-'*44)+'+'
                $rowFormat='| {0,-33} {1,8} |'
                Write-Host ''
                Write-Host $border
                Write-Host ('| {0,-42} |' -f 'Average System process CPU usage')
                Write-Host $border
                Write-Host ($rowFormat -f 'Before applying the workaround',('{0:F2}%' -f $comparison.Before.AveragePercent))
                Write-Host ($rowFormat -f 'After applying the workaround',('{0:F2}%' -f $comparison.After.AveragePercent))
                Write-Host $border
                Write-Host ''
            }else{
                Write-Host 'The before/after comparison could not be completed.' -ForegroundColor Yellow
                if($comparison.Error){Write-Host $comparison.Error}
            }
            if($comparison.ReportDirectory){Write-Host ('Measurement files: '+$comparison.ReportDirectory)}
            Write-Host 'Verify System CPU in Task Manager with the NVIDIA GPU idle and other monitoring tools closed. Check again after restarting.'
        }else{Write-Host 'ORIGINAL CONFIGURATION RESTORED.' -ForegroundColor Green}
        Write-Host ('Operation log: '+$log)
    }
    exit 0
}catch{Write-Host ('Error: '+$_.Exception.Message) -ForegroundColor Red;exit 1}
