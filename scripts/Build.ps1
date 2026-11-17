$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'src'
$names=@('Menu.ps1','Set-Workaround.ps1','WorkaroundData.ps1','Read-DxgTraceConsumers.ps1','Read-DiagLogProviderConfiguration.ps1','DiagLogKeywordControl.cs','WdiRegistryAccess.cs','Measure-SystemCPU.ps1')
$files=foreach($name in $names){
    $text=[IO.File]::ReadAllText((Join-Path $source $name)) -replace '\r?\n',"`r`n"
    $bytes=[Text.UTF8Encoding]::new($true).GetPreamble()+[Text.Encoding]::UTF8.GetBytes($text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
    [pscustomobject]@{Name=$name;Hash=$hash;Data=[Convert]::ToBase64String($bytes)}
}
$package=[ordered]@{Version='0.1.0';Bootstrap=([IO.File]::ReadAllText((Join-Path $source 'Bootstrap.ps1')) -replace '\r?\n',"`r`n");Files=@($files)}
$payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($package|ConvertTo-Json -Depth 6 -Compress)))
$loader='$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";try{$s=[IO.File]::ReadAllText($env:GPU_IDLE_CPU_SOURCE);$m=":GPU_IDLE_CPU_PAYLOAD_V1";$i=$s.LastIndexOf($m);if($i -lt 0){throw "Missing package payload"};$package=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s.Substring($i+$m.Length).Trim()))|ConvertFrom-Json;& ([ScriptBlock]::Create($package.Bootstrap))}catch{Write-Host $_;exit 1}'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loader))
$header=@'
@echo off
setlocal
title GPU Idle CPU Workaround
set "GPU_IDLE_CPU_SOURCE=%~f0"
set "GPU_IDLE_CPU_MODE=Menu"
if /i "%~1"=="/check" set "GPU_IDLE_CPU_MODE=Check"
if /i "%~1"=="/status" set "GPU_IDLE_CPU_MODE=Status"
set "GPU_IDLE_CPU_LOADER=ENCODED_LOADER"
set "gpuPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "gpuPowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%gpuPowerShell%" -NoProfile -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand %GPU_IDLE_CPU_LOADER%
set "gpuResult=%errorlevel%"
if not "%gpuResult%"=="0" echo The operation failed. Read the message above before retrying.
if /i "%GPU_IDLE_CPU_MODE%"=="Menu" if not "%gpuResult%"=="0" pause
exit /b %gpuResult%
:GPU_IDLE_CPU_PAYLOAD_V1
'@
$header=$header.Replace('ENCODED_LOADER',$encoded) -replace '\r?\n',"`r`n"
$output=Join-Path $root 'dist\GPU-Idle-CPU-Workaround.cmd'
[IO.Directory]::CreateDirectory((Split-Path $output -Parent))|Out-Null
[IO.File]::WriteAllText($output,($header+"`r`n"+[regex]::Replace($payload,'.{1,120}','$0'+"`r`n")),[Text.Encoding]::ASCII)
$digest=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $root 'dist\SHA256SUMS.txt'),($digest+'  GPU-Idle-CPU-Workaround.cmd'+"`n"),[Text.Encoding]::ASCII)
Write-Output $output
