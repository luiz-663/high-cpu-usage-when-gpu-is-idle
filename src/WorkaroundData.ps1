function Get-WorkaroundMachineId {
    $id = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'Windows installation identity is unavailable.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($id.ToLowerInvariant())))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-WorkaroundDataDirectory {
    $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('GpuIdleCpuWorkaround\' + (Get-WorkaroundMachineId))
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}
function Assert-WorkaroundBackup($Backup,[string]$MachineId,[string]$RegistryPath) {
    if ($Backup.SchemaVersion -ne 1 -or $Backup.MachineId -cne $MachineId -or
        $Backup.Path -ne $RegistryPath -or $Backup.ValueName -ne 'Keyword' -or $Backup.ValueKind -ne 'QWord' -or
        $Backup.OriginalValue -ne 33554432 -or $Backup.ReplacementValue -ne 65536 -or
        $Backup.OriginalRuntimeMask -ne 33751040 -or $Backup.ReplacementRuntimeMask -ne 196608 -or
        [string]::IsNullOrWhiteSpace($Backup.SecurityDescriptor)) {
        throw 'Backup does not match this installation and the reviewed configuration. No automatic overwrite.'
    }
}
