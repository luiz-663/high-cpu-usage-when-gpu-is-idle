# Technical notes

## Observed query paths

With matching Microsoft symbols, the saved Task Manager trace showed:

```text
WdcGpuMonitor::Query
  -> DXCoreAdapter::GetAdapterEngineRunningTimeMicroseconds
  -> NtGdiDdDDIQueryStatistics
  -> DxgkQueryStatisticsInternal
  -> DXGADAPTER::GetNodePerfData
  -> DdiQueryAdapterInfo -> nvlddmkm
  -> power callbacks -> PoFxActivateComponent -> waits
```

The independent reproduction entered through QueryAdapterInfo rather than QueryStatistics. Both converged on GetNodePerfData. A hook covering only the former entry in Task Manager would not cover the observed path. Wait records are not a count of distinct calls, and not all waiting time was exclusively PoFx.

## Cache and tracing

Disassembly of the corresponding dxgkrnl image found a normal 450 ms NodePerfData cache interval and a field at DXGADAPTER+0xA0 which can select cached data without checking its age. Writes in AcquireLocksForPowerStateD3transition and ReleaseCoreSync associate the field with D3 synchronization. The private field name/enum was not recovered, and it is not a validated physical D3cold indicator.

When bTracingEnabled is nonzero, the examined path bypasses those cache checks and calls the driver. The saved live-kernel snapshot had bTracingEnabled=1 despite no WPR session being used for that capture. Enumerating current ETW consumers identified DiagLog's combined keyword mask 0x02030000. Its MixedReality bit 0x02000000 intersected the relevant callback mask 0x461c8ed7; the remaining 0x30000 did not. EventLog-System's observed 0x0C00000000000000 mask also did not intersect it and was left unchanged.

Code analysis supports the proposed mechanism. The reversible selective-keyword experiments establish the intervention's effect on this machine. No post-change live dump was taken merely to reread bTracingEnabled, and private NVIDIA symbols were not obtained.

An older, Microsoft-signed dxgkrnl 10.0.22621.2340 image also contained the cache, D3 guard, tracing bypass, and relevant callback mask. This does not identify when the symptom began or exclude regressions elsewhere.

## Language-independent preflight

The tool uses:

1. EnumerateTraceGuidsEx and QueryAllTracesW for provider enables and session identity.
2. PLA IDataCollectorSet.Query with `Session\DiagLog`, followed by its documented XML schema and read-only SessionId property.
3. Numeric/GUID comparisons across both views before a write.

Display names, translated descriptions, and translated error messages do not drive validation. Missing data, active/custom filter information, mismatched masks, and unexpected session identity cause refusal. Sequential API reads are not an atomic snapshot; concurrent trace controllers remain a limitation.

The native controller changes only the two reviewed keyword masks, with level 255, MatchAllKeyword zero, EnableProperty 0x40, and no filter descriptor. Existing filters must therefore be confirmed absent before invoking it. No kernel memory is patched.

## Backup and registry access

The registry helper opens only the reviewed, existing key and accepts only the original/replacement QWORD values. REG_OPTION_BACKUP_RESTORE allows an administrator with the corresponding privileges to obtain a handle without changing ownership/ACLs. The process privileges are restored after opening the handle. The operation verifies the security descriptor before completing.

The first backup records the real initial state and an installation identifier hashed locally. The public distribution does not include the original investigator's backup. Later operations validate the backup schema, installation identity, path, and reviewed values. Apply/Undo preserve local reports; if a subsequent step fails after mutation, rollback is attempted and recorded.

## Primary API documentation

- [D3DKMT_QUERYSTATISTICS_NODE_INFORMATION](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/ns-d3dkmthk-d3dkmt_querystatistics_node_information)
- [EnumerateTraceGuidsEx](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-enumeratetraceguidsex)
- [QueryAllTracesW](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-queryalltracesw)
- [IDataCollectorSet.Query](https://learn.microsoft.com/en-us/windows/win32/api/pla/nf-pla-idatacollectorset-query)
- [IDataCollectorSet XML representation](https://learn.microsoft.com/en-us/windows/win32/api/pla/nn-pla-idatacollectorset)
- [ITraceDataProvider.FilterType](https://learn.microsoft.com/en-us/windows/win32/api/pla/nf-pla-itracedataprovider-get_filtertype)
- [EnableTraceEx2](https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-enabletraceex2)
- [RegCreateKeyExW](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regcreatekeyexw)
- [Component-level power management](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/component-level-power-management)

These documents describe the mechanisms used. They do not endorse this specific WDI workaround.
