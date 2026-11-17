$ErrorActionPreference='Stop'
$extract=$null;$mutex=$null;$locked=$false
try {
    $mode=$env:GPU_IDLE_CPU_MODE
    if($mode -notin @('Menu','Check','Status')){throw 'Invalid launcher mode.'}
    $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $admin=([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if($mode -ne 'Check' -and -not $admin){
        Write-Host 'Approve the Windows administrator prompt to continue.'
        $script='$env:GPU_IDLE_CPU_SOURCE='''+$env:GPU_IDLE_CPU_SOURCE.Replace("'","''")+"';"+
            '$env:GPU_IDLE_CPU_MODE='''+$mode+"';"+[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($env:GPU_IDLE_CPU_LOADER))
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        # A visible window is intentional: this is the user's interactive utility.
        $child=Start-Process -FilePath $psExe -Verb RunAs -WindowStyle Normal -Wait -PassThru -ArgumentList @('-NoProfile','-OutputFormat','Text','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
        exit $child.ExitCode
    }
    if([IntPtr]::Size -ne 8){throw '64-bit Windows PowerShell is required.'}
    $extract=Join-Path ([IO.Path]::GetTempPath()) ('GpuIdleCpu-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($extract)|Out-Null
    foreach($file in $package.Files){
        if([IO.Path]::GetFileName($file.Name) -ne $file.Name){throw 'Invalid package file name.'}
        $bytes=[Convert]::FromBase64String($file.Data)
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
        if($hash -ne $file.Hash){throw ('Corrupt package content: '+$file.Name)}
        [IO.File]::WriteAllBytes((Join-Path $extract $file.Name),$bytes)
    }
    if($mode -eq 'Check'){
        & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extract 'Menu.ps1') -CheckOnly
        if($LASTEXITCODE -ne 0){throw 'Package dependency check failed.'}
        & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extract 'Set-Workaround.ps1') -CompileOnly
        if($LASTEXITCODE -ne 0){throw 'Native helper compilation failed.'}
        Write-Host 'Standalone package verified. No system configuration changes.'
        exit 0
    }
    . (Join-Path $extract 'WorkaroundData.ps1')
    $mutex=[Threading.Mutex]::new($false,('Local\GpuIdleCpuWorkaround-'+(Get-WorkaroundMachineId)))
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Another instance is already running.'}
    Write-Host ('Local backup and reports: '+(Get-WorkaroundDataDirectory))
    if($mode -eq 'Status'){& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extract 'Set-Workaround.ps1') -Mode Status}
    else{& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extract 'Menu.ps1')}
    exit $LASTEXITCODE
}catch{Write-Host ('Error: '+$_.Exception.Message) -ForegroundColor Red;exit 1}
finally{
    if($locked){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
    if($extract -and (Test-Path -LiteralPath $extract)){
        $resolved=(Resolve-Path -LiteralPath $extract).ProviderPath
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -eq $tempRoot -and [IO.Path]::GetFileName($resolved) -match '^GpuIdleCpu-[0-9a-f]{32}$'){
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Continue
        }
    }
}
