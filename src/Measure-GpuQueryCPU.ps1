param([string]$OutputFile,[string]$ExpectedAdapterId,[switch]$CompileOnly)
$ErrorActionPreference='Stop'
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'GpuQueryProbe.cs')
    [GpuQueryProbe]::ValidateLayout()
    if ($CompileOnly) { return }
    if (-not $OutputFile) { throw 'A measurement output path is required.' }
    $measurement=[GpuQueryProbe]::Measure($ExpectedAdapterId)
    $cpu=$measurement.Samples|Measure-Object SystemCPU -Average -Maximum
    $query=$measurement.Samples|Measure-Object QueryMilliseconds -Average
    if ($cpu.Count -ne [GpuQueryProbe]::SampleCount) { throw 'The CPU sample set is incomplete.' }
    [ordered]@{
        Adapter=$measurement.Adapter
        AdapterId=$measurement.AdapterId
        SampleCount=$cpu.Count
        AveragePercent=$cpu.Average
        PeakPercent=$cpu.Maximum
        AverageQueryMilliseconds=$query.Average
        Samples=$measurement.Samples
    }|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $OutputFile -Encoding UTF8
} catch {
    [Console]::Error.WriteLine($_.Exception.GetBaseException().Message)
    exit 1
}
