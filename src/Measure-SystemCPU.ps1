param([ValidateRange(5,300)][int]$Seconds=20,[string]$OutputFile)
$ErrorActionPreference='Stop'
$logical=[Environment]::ProcessorCount
$value=(Get-Process -Id 4).TotalProcessorTime
if($null -eq $value){throw 'Run this script in an administrator PowerShell to read System CPU time.'}
$previous=$value.TotalSeconds
$timer=[Diagnostics.Stopwatch]::StartNew();$previousTime=$timer.Elapsed.TotalSeconds
$rows=for($i=0;$i -lt $Seconds;$i++){
 Start-Sleep -Seconds 1
 $current=(Get-Process -Id 4).TotalProcessorTime.TotalSeconds;$time=$timer.Elapsed.TotalSeconds
 [pscustomobject]@{Time=(Get-Date -Format o);SystemCPU=100*($current-$previous)/($time-$previousTime)/$logical}
 $previous=$current;$previousTime=$time
}
if($OutputFile){$rows | ConvertTo-Json | Set-Content $OutputFile}
$rows | Format-Table
$rows | Measure-Object SystemCPU -Average -Minimum -Maximum | Format-List
