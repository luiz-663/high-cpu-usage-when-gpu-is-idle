param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
try {
    foreach($name in @('Set-Workaround.ps1','WorkaroundData.ps1','Read-DxgTraceConsumers.ps1','Read-DiagLogProviderConfiguration.ps1','DiagLogKeywordControl.cs','WdiRegistryAccess.cs','Measure-SystemCPU.ps1')) {
        if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)){throw ('Required file missing: '+$name)}
    }
    if($CheckOnly){'Package files verified; no system configuration changes.';exit 0}
    . (Join-Path $PSScriptRoot 'WorkaroundData.ps1')
    $dataRoot=Get-WorkaroundDataDirectory
    $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    while($true) {
        Write-Host ''
        Write-Host 'GPU IDLE CPU WORKAROUND v0.1.0'
        Write-Host 'Preserves GPU sleep settings. Experimental; configuration must match.'
        Write-Host '1 - Check configuration (read-only)'
        Write-Host '2 - Apply workaround'
        Write-Host '3 - Restore original configuration'
        Write-Host '0 - Exit'
        $choice=Read-Host 'Choose an option'
        if($choice -eq '0'){break}
        $mode=switch($choice){'1'{'Status'};'2'{'Apply'};'3'{'Undo'};default{$null}}
        if(-not $mode){Write-Host 'Invalid option.';continue}
        if($mode -eq 'Apply'){Write-Host 'Applying and measuring CPU; allow about 30 seconds.'}
        elseif($mode -eq 'Undo'){Write-Host 'Restoring the original configuration; the elevated CPU symptom may return.'}
        $started=Get-Date
        $log=Join-Path $dataRoot ('menu-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.log')
        & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Set-Workaround.ps1') -Mode $mode 2>&1|Out-File -LiteralPath $log -Encoding UTF8
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
            Write-Host 'After restarting, check configuration before reapplying and observe System CPU.'
        }else{Write-Host 'ORIGINAL CONFIGURATION RESTORED.' -ForegroundColor Green}
        Write-Host ('Operation log: '+$log)
    }
    exit 0
}catch{Write-Host ('Error: '+$_.Exception.Message) -ForegroundColor Red;exit 1}
