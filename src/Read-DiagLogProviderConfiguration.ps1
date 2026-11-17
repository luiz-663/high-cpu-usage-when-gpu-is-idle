# Read-only PLA query. No Commit, Start, Stop, SetXml or property assignments.
# XML element names and numeric values are part of the Windows PLA schema.
# Localized DisplayName, Description and error text never control decisions.
# https://learn.microsoft.com/en-us/windows/win32/api/pla/nf-pla-idatacollectorset-query
# https://learn.microsoft.com/en-us/windows/win32/api/pla/nn-pla-idatacollectorset
# https://learn.microsoft.com/en-us/windows/win32/api/pla/nf-pla-itracedataprovider-get_filtertype
function Convert-DiagLogXmlUInt64([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Missing numeric PLA value.' }
    if ($Text -match '^0[xX][0-9a-fA-F]+$') {
        return [Convert]::ToUInt64($Text.Substring(2),16)
    }
    return [UInt64]::Parse($Text,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture)
}
function Get-DiagLogXmlText([System.Xml.XmlNode]$Node,[string]$Path) {
    $matches = $Node.SelectNodes($Path)
    if ($matches.Count -ne 1) { throw ('Expected exactly one PLA field: ' + $Path) }
    return $matches[0].InnerText
}
function ConvertFrom-DiagLogProviderXml([string]$Xml,[UInt64]$SessionHandle) {
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 4194304
    $textReader = [IO.StringReader]::new($Xml)
    $reader = $null
    try {
        $reader = [Xml.XmlReader]::Create($textReader,$settings)
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
    } finally {
        if ($reader) { $reader.Dispose() }
        $textReader.Dispose()
    }
    $root = $document.DocumentElement
    if ($root.LocalName -ne 'DataCollectorSet') { throw 'Unexpected PLA document.' }
    $collectors = $root.SelectNodes('TraceDataCollector')
    if ($collectors.Count -ne 1) { throw 'Expected exactly one trace collector.' }
    $collector = $collectors[0]
    $target = [Guid]'802ec45a-1e99-4b83-9920-87c98277ba9d'
    $providers = @($collector.SelectNodes('TraceDataProvider') | Where-Object {
        ([Guid](Get-DiagLogXmlText $_ 'Guid')) -eq $target
    })
    if ($providers.Count -ne 1) { throw 'Expected exactly one DxgKrnl provider in PLA.' }
    $provider = $providers[0]
    $filterNodes = $provider.SelectNodes('FilterData')
    if ($filterNodes.Count -gt 1) { throw 'Unexpected repeated FilterData.' }
    $filterLength = 0
    if ($filterNodes.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($filterNodes[0].InnerText)) {
        # No need to decode or interpret custom filters; their presence blocks writes.
        $filterLength = $filterNodes[0].InnerText.Trim().Length
    }
    [pscustomobject]@{
        ReadMethod = 'PLA IDataCollectorSet.Query Session\DiagLog and invariant XML schema'
        CapturedUtc = [DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        SetName = Get-DiagLogXmlText $root 'Name'
        SetStatus = Convert-DiagLogXmlUInt64 (Get-DiagLogXmlText $root 'Status')
        SessionName = Get-DiagLogXmlText $collector 'SessionName'
        SessionGuid = ([Guid](Get-DiagLogXmlText $collector 'Guid')).ToString()
        # SessionId is a read-only COM property and is not serialized in PLA XML.
        SessionHandle = $SessionHandle
        ProviderGuid = $target.ToString()
        FilterType = Convert-DiagLogXmlUInt64 (Get-DiagLogXmlText $provider 'FilterType')
        FilterEnabled = [Int32]::Parse((Get-DiagLogXmlText $provider 'FilterEnabled'),[Globalization.CultureInfo]::InvariantCulture)
        FilterDataTextLength = $filterLength
        Level = Convert-DiagLogXmlUInt64 (Get-DiagLogXmlText $provider 'Level/Value')
        MatchAnyKeyword = Convert-DiagLogXmlUInt64 (Get-DiagLogXmlText $provider 'KeywordsAny/Value')
        MatchAllKeyword = Convert-DiagLogXmlUInt64 (Get-DiagLogXmlText $provider 'KeywordsAll/Value')
        EnableProperty = Convert-DiagLogXmlUInt64 (Get-DiagLogXmlText $provider 'Properties/Value')
    }
}
function Read-DiagLogProviderConfiguration {
    $set = $null
    try {
        $set = New-Object -ComObject Pla.DataCollectorSet
        $set.Query('Session\DiagLog',$null)
        if ($set.DataCollectors.Count -ne 1) { throw 'Expected exactly one PLA collector.' }
        $sessionHandle = [UInt64]$set.DataCollectors.Item(0).SessionId
        return ConvertFrom-DiagLogProviderXml ([string]$set.Xml) $sessionHandle
    } finally {
        if ($set) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($set) }
    }
}
function Assert-DiagLogProviderConfiguration($Configuration,[UInt64]$ExpectedHandle,[UInt64]$ExpectedMask) {
    if ($Configuration.SetName -ne 'DiagLog' -or $Configuration.SessionName -ne 'DiagLog' -or
        $Configuration.SetStatus -ne 1 -or $Configuration.SessionGuid -ne '08b524eb-a2bf-47eb-aef1-dbd871741d7a' -or
        $Configuration.SessionHandle -ne $ExpectedHandle -or $ExpectedHandle -eq 0 -or
        $Configuration.ProviderGuid -ne '802ec45a-1e99-4b83-9920-87c98277ba9d') {
        throw 'PLA session identity does not match the native ETW snapshot.'
    }
    if ($Configuration.Level -ne 255 -or $Configuration.MatchAnyKeyword -ne $ExpectedMask -or
        $Configuration.MatchAllKeyword -ne 0 -or $Configuration.EnableProperty -ne 64) {
        throw 'PLA provider settings do not match the reviewed ETW configuration.'
    }
    if ($Configuration.FilterType -ne 0 -or $Configuration.FilterEnabled -ne 0 -or $Configuration.FilterDataTextLength -ne 0) {
        throw 'Provider filters are present or unexpected; no overwrite is allowed.'
    }
}
