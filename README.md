# High CPU Usage When the GPU Is Idle

*Experimental Windows workaround*

A reversible Windows workaround for **sustained System (PID 4) CPU usage from the interaction between DxgKrnl performance queries and DiagLog tracing** in the investigated configuration. Querying an inactive discrete GPU exposed the problem; GPU inactivity alone was not the cause. The workaround preserves existing GPU sleep and power settings.

**Experimental, configuration-specific, and validated on one notebook.** This is not an official Microsoft/NVIDIA fix or a general cure for DPC latency. The tool refuses configurations outside the values examined in the original investigation.

## Download and use

Download **[High-CPU-Usage-When-GPU-Is-Idle.cmd](https://github.com/luiz-663/high-cpu-usage-when-gpu-is-idle/releases/download/v0.1.2/High-CPU-Usage-When-GPU-Is-Idle.cmd)** from the [v0.1.2 release](https://github.com/luiz-663/high-cpu-usage-when-gpu-is-idle/releases/tag/v0.1.2). Only this file is needed to run the tool. Source code is included in this repository; [SHA256SUMS.txt](dist/SHA256SUMS.txt) records the distributed file's hash.

1. Double-click the `.cmd` and approve the administrator prompt.
2. Choose **1 — Check configuration** first.
3. If the symptom and configuration match, choose **2 — Apply workaround**. Allow about 30 seconds.
4. Leave Task Manager updating normally, with games and GPU sensor tools closed, and compare **System** CPU usage.
5. Restart Windows, then **check before reapplying** to confirm that the setting persisted.

Choose **3 — Restore original configuration** to undo. Restoring may bring back the CPU symptom. Opening the menu does not automatically apply anything.

The title, menu, and tool messages are in English. Validation uses native ETW data and the Windows PLA API's structured XML fields, rather than translated `logman` output. Windows-generated error messages may still follow the OS language.

### Requirements and compatibility

- Windows 11 on x64, built-in **Windows PowerShell 5.1**, administrator access, and the Windows PLA COM API.
- The exact WDI registry entry, DiagLog session identity, keyword masks, level, and filter settings checked by the tool must match.
- Having the same GPU or similar hardware does not prove the same cause. The tool checks configuration; it does not diagnose the origin of every System CPU problem.
- Windows on ARM and other hardware/build combinations have not been validated.

## The problem investigated

On a **Lenovo Legion Y530-15ICH**, with **Core i7-8750H, Intel UHD 630, and GTX 1050 Ti**, System consumed roughly **3–4% of total CPU capacity** while the NVIDIA GPU was without a graphics workload and Task Manager was refreshing. Briefly activating the NVIDIA GPU reduced that work. Closing or pausing Task Manager also reduced it.

An independent program reproduced the sustained CPU cost by querying WDDM **NODEPERFDATA**, without creating a Direct3D workload. This established that Task Manager was one trigger, rather than the only application capable of reaching the costly path.

In the examined configuration, the default **DiagLog** ETW session enabled a DxgKrnl keyword called **MixedReality**. Kernel code analysis indicated that this enabled a tracing path which bypassed the NodePerfData cache, including a guard associated with D3 synchronization. Repeated queries then involved NVIDIA driver work and power activation. Removing only that keyword allowed the normal cache path to be used again.

The keyword name does not establish that a mixed-reality application was running. The sustained CPU cost was mainly in System threads; measured DPC/ISR time did not account for the whole 3–4%.

## Related NVIDIA forum reports

The NVIDIA Developer Forums thread **[10% CPU utilization at idle](https://forums.developer.nvidia.com/t/10-cpu-utilization-at-idle/319659)** contains user reports of elevated System CPU on NVIDIA-equipped Windows 11 24H2 laptops. A **[follow-up post specifically reports that closing Task Manager returns System CPU to normal](https://forums.developer.nvidia.com/t/10-cpu-utilization-at-idle/319659/9)**.

These are community observations with overlapping symptoms, not an NVIDIA confirmation of this project's diagnosis. They do not establish that every report has the same DiagLog/cache mechanism, that this workaround fixes those machines, or that the behavior was introduced in 24H2. The controlled measurements and kernel analysis described here are separate evidence from the notebook investigated for this project.

## What the tool changes

It changes **one `Keyword` value, REG_QWORD**, in this existing key:

```text
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\WDI\Scenarios\{186f47ef-626c-4670-800a-4a30756babad}\Instrumentation\{802ec45a-1e99-4b83-9920-87c98277ba9d};2
```

| Setting | Original examined value | Workaround |
|---|---|---|
| Registry `Keyword` | `0x02000000` / 33554432 | `0x00010000` / 65536 |
| Combined DxgKrnl keywords in DiagLog | `0x02030000` | `0x00030000` |
| Entry's `Level` | 4 | Preserved |
| Registry owner and permissions | Existing descriptor | Preserved and checked |

The replacement repeats a DxgKrnl category already enabled by another WDI entry. **Zero is not used**, because a zero keyword mask can mean all categories. The live provider configuration is updated through `EnableTraceEx2`, so the change can take effect in the current session as well as be checked after a restart.

The tool does not disable the whole DiagLog session or EventLog-System. It does not modify D3cold policy, HAGS, ASPM, MSI, TDR, boot configuration, or Windows/NVIDIA binaries. It installs no service, scheduled task, or workload to keep the GPU awake.

The protected registry entry is accessed through Windows' documented `REG_OPTION_BACKUP_RESTORE` mechanism. Backup/restore privileges are enabled temporarily on the process and restored after obtaining the handle. Ownership and ACLs are not changed.

## Results and limits

The original investigation used reversible A/B/A comparisons: original keywords, selective removal, original keywords restored.

| Test | Original | Workaround | Original restored |
|---|---:|---:|---:|
| Independent NodePerfData query, System mean CPU | 3.316% | 0.275% | 3.307% |
| Independent query mean duration | 346.205 ms | 0.01656 ms | 344.755 ms |
| Task Manager at Normal update speed, System mean CPU | 3.38% | 0.30% | 3.78% |

After final application, mean System CPU was **0.219%** over 20 intervals. After restarting without reapplying, the registry and live session retained the adjusted values and mean System CPU was **0.305%** over 30 intervals, maximum **0.648%**. The observer used PID 4's CPU time divided by wall time and 12 logical processors, independently of Task Manager's display.

A brief Direct3D 11 device/render-target test on the NVIDIA GPU succeeded, and System CPU stayed low after releasing the graphics resources. This was not a full application compatibility or stability test.

The behavioral tests were performed with Windows 11 Home **26H2 build 26300.9974**, NVIDIA **582.78 / 32.0.15.8278**, Intel Graphics **27.20.100.8729**, and BIOS **8JCN56WW**. The examined dxgkrnl version was **10.0.26100.9974**. This public English package was separately checked for extraction, compilation, configuration reading, and offline guard tests. Its Apply/Undo operations were not rerun solely to validate packaging.

## Tradeoffs

- **Less diagnostic data:** DiagLog no longer collects that DxgKrnl MixedReality keyword through this configuration. Troubleshooting dependent on those events may have less information.
- **Cached information while idle:** queries may use the normal cached path rather than refreshing the driver. This is the intended mechanism; it is not proof that every sensor remains current during sleep.
- **Other collectors can reactivate tracing:** a graphics WPR capture or another ETW consumer can enable keywords which bypass the cache. A Windows update may restore or change the configuration.
- **Limited scope:** NVML and other sensor APIs may behave differently. The workaround does not guarantee elimination of unrelated ACPI DPC spikes or every source of System CPU usage.
- **Physical D3cold was not independently measured.** Existing sleep policy was preserved; low CPU by itself is not a measurement of GPU power rails.
- **A 24H2 regression was not proven.** An older Microsoft dxgkrnl image, 10.0.22621.2340, already contained the relevant cache/tracing decisions. No older Windows installation was tested behaviorally.

## Backups, logs, and undo

The single-file launcher extracts its helpers to a temporary directory and removes them on normal exit. Backup and reports are kept under:

```text
%LOCALAPPDATA%\GpuIdleCpuWorkaround\<hashed Windows installation ID>\
```

This internal directory name is retained for compatibility with existing backups after the project rename. Keep this folder to retain the backup and recovery history. The public package contains **no machine-specific backup or installation ID**. A first Apply requires the original reviewed registry and runtime values so it can save the real starting configuration. Undo requires a backup matching this installation and schema.

If the setting was already changed by a different edition/tool, Check can still inspect it, but this edition will not invent an original backup. Use the previous tool to restore its own change before migrating. Do not copy another machine's backup.

If an operation fails, read the error and local operation log before repeating it. Attempted registry/runtime changes have rollback handling, whose outcome is recorded. Reports can contain local paths, security descriptors, and session information: review and redact them before sharing.

## Command-line options

```bat
High-CPU-Usage-When-GPU-Is-Idle.cmd /check
High-CPU-Usage-When-GPU-Is-Idle.cmd /status
```

`/check` verifies embedded files and compiles the native helpers without changing system configuration or requesting elevation. `/status` requests administrator access if needed and reads the reviewed configuration. It does not measure CPU, prove physical sleep, or establish reboot persistence by itself.

## Build and contribute

Run in Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Offline.ps1
```

Output is `dist\High-CPU-Usage-When-GPU-Is-Idle.cmd` plus `dist\SHA256SUMS.txt`. No third-party build dependency is required. The launcher stores the source as Base64, a transport encoding, and checks embedded SHA-256 hashes. These hashes detect corruption; they are not a publisher signature.

See [technical notes](docs/TECHNICAL.md), [validation](docs/VALIDATION.md), and [contributing](CONTRIBUTING.md). Reports from matching systems are useful; please include measured before/after behavior and describe the configuration, while keeping raw kernel dumps and private logs off public issues.

MIT licensed. Independent project; not affiliated with or endorsed by Microsoft, NVIDIA, or Lenovo.
