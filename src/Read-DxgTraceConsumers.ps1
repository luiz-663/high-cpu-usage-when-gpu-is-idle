param(
    [Guid]$ProviderGuid = '802ec45a-1e99-4b83-9920-87c98277ba9d',
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dxg-trace-consumers-current.json'),
    [switch]$CompileOnly
)
$ErrorActionPreference = 'Stop'
# Read-only ETW enumeration. No StartTrace, EnableTrace, ControlTrace or StopTrace.
# Sources:
# https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-enumeratetraceguidsex
# https://learn.microsoft.com/en-us/windows/win32/api/evntrace/ns-evntrace-trace_enable_info
# https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-queryalltracesw
if (-not ('DxgEtwReadOnly' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class DxgEtwReadOnly {
    [StructLayout(LayoutKind.Sequential)] public struct WNODE_HEADER {
        public uint BufferSize, ProviderId;
        public ulong HistoricalContext, TimeStamp;
        public Guid Guid;
        public uint ClientContext, Flags;
    }
    [StructLayout(LayoutKind.Sequential)] public struct EVENT_TRACE_PROPERTIES {
        public WNODE_HEADER Wnode;
        public uint BufferSize, MinimumBuffers, MaximumBuffers, MaximumFileSize;
        public uint LogFileMode, FlushTimer, EnableFlags;
        public int AgeLimit;
        public uint NumberOfBuffers, FreeBuffers, EventsLost, BuffersWritten;
        public uint LogBuffersLost, RealTimeBuffersLost;
        public IntPtr LoggerThreadId;
        public uint LogFileNameOffset, LoggerNameOffset;
    }
    [StructLayout(LayoutKind.Sequential)] public struct TRACE_GUID_INFO {
        public uint InstanceCount, Reserved;
    }
    [StructLayout(LayoutKind.Sequential)] public struct TRACE_PROVIDER_INSTANCE_INFO {
        public uint NextOffset, EnableCount, Pid, Flags;
    }
    [StructLayout(LayoutKind.Sequential)] public struct TRACE_ENABLE_INFO {
        public uint IsEnabled;
        public byte Level, Reserved1;
        public ushort LoggerId;
        public uint EnableProperty, Reserved2;
        public ulong MatchAnyKeyword, MatchAllKeyword;
    }
    [DllImport("advapi32.dll", ExactSpelling=true)]
    static extern uint EnumerateTraceGuidsEx(uint queryClass, ref Guid input, uint inputSize, IntPtr output, uint outputSize, out uint returnLength);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    static extern uint QueryAllTracesW([In,Out,MarshalAs(UnmanagedType.LPArray,SizeParamIndex=1)] IntPtr[] properties, uint count, out uint loggerCount);
    public sealed class Session {
        public ulong HistoricalContext;
        public string HistoricalContextHex, Name, Guid, LogFileName, LogFileModeHex;
        public ushort HistoricalContextLow16;
        public uint EventsLost, BuffersWritten;
    }
    public sealed class Consumer {
        public uint ProviderInstanceIndex, ProviderProcessId, ProviderInstanceFlags, IsEnabled;
        public ushort LoggerId;
        public byte Level;
        public uint EnableProperty;
        public string EnablePropertyHex, MatchAnyKeyword, MatchAllKeyword;
        public string SessionName, SessionIdHex, SessionMatch;
    }
    public sealed class Result {
        public string CapturedUtc, ProviderGuid, Note;
        public uint SessionQueryStatus, ProviderQueryStatus, ProviderInstanceCount;
        public string SessionQueryMessage, ProviderQueryMessage;
        public List<Session> Sessions = new List<Session>();
        public List<Consumer> Consumers = new List<Consumer>();
    }
    static string Hex(ulong n) { return "0x" + n.ToString("X16"); }
    static string Error(uint n) { return n == 0 ? "Success" : new Win32Exception(unchecked((int)n)).Message; }
    public static string ValidateLayout() {
        if (IntPtr.Size != 8) throw new InvalidOperationException("Use a 64-bit PowerShell process.");
        if (Marshal.SizeOf(typeof(WNODE_HEADER)) != 48 || Marshal.SizeOf(typeof(EVENT_TRACE_PROPERTIES)) != 120 ||
            Marshal.SizeOf(typeof(TRACE_GUID_INFO)) != 8 || Marshal.SizeOf(typeof(TRACE_PROVIDER_INSTANCE_INFO)) != 16 ||
            Marshal.SizeOf(typeof(TRACE_ENABLE_INFO)) != 32 ||
            Marshal.OffsetOf(typeof(TRACE_ENABLE_INFO), "LoggerId").ToInt32() != 6 ||
            Marshal.OffsetOf(typeof(TRACE_ENABLE_INFO), "MatchAnyKeyword").ToInt32() != 16 ||
            Marshal.OffsetOf(typeof(EVENT_TRACE_PROPERTIES), "LoggerNameOffset").ToInt32() != 116)
            throw new InvalidOperationException("Unexpected native structure layout.");
        return "x64 native layouts verified: WNODE_HEADER=48, EVENT_TRACE_PROPERTIES=120, TRACE_GUID_INFO=8, TRACE_PROVIDER_INSTANCE_INFO=16, TRACE_ENABLE_INFO=32 bytes.";
    }
    static string ReadString(IntPtr p, uint offset, int totalBytes) {
        if (offset == 0 || offset >= totalBytes || (offset & 1) != 0) return null;
        string value = Marshal.PtrToStringUni(IntPtr.Add(p, checked((int)offset)), (totalBytes-checked((int)offset))/2);
        int end = value.IndexOf('\0');
        return end >= 0 ? value.Substring(0,end) : value;
    }
    static void ReadSessions(Result r) {
        int capacity = 64;
        const int nameBytes = 4096;
        int baseSize = Marshal.SizeOf(typeof(EVENT_TRACE_PROPERTIES));
        int totalSize = baseSize + nameBytes*2;
        for (int attempt=0; attempt<8; attempt++) {
            IntPtr[] buffers = new IntPtr[capacity];
            uint needed;
            try {
                for (int i=0;i<capacity;i++) {
                    buffers[i]=Marshal.AllocHGlobal(totalSize);
                    Marshal.Copy(new byte[totalSize],0,buffers[i],totalSize);
                    EVENT_TRACE_PROPERTIES prop = new EVENT_TRACE_PROPERTIES();
                    prop.Wnode.BufferSize=(uint)totalSize;
                    prop.LoggerNameOffset=(uint)baseSize;
                    prop.LogFileNameOffset=(uint)(baseSize+nameBytes);
                    Marshal.StructureToPtr(prop,buffers[i],false);
                }
                r.SessionQueryStatus=QueryAllTracesW(buffers,(uint)capacity,out needed);
                r.SessionQueryMessage=Error(r.SessionQueryStatus);
                if (r.SessionQueryStatus==234) {
                    if (needed>1024) throw new InvalidOperationException("Unexpected ETW session count.");
                    capacity=Math.Max(capacity+16,checked((int)needed)+8);
                    continue;
                }
                if (r.SessionQueryStatus!=0) return;
                if (needed>capacity) throw new InvalidOperationException("ETW session count exceeds allocation.");
                for (int i=0;i<needed;i++) {
                    EVENT_TRACE_PROPERTIES prop=(EVENT_TRACE_PROPERTIES)Marshal.PtrToStructure(buffers[i],typeof(EVENT_TRACE_PROPERTIES));
                    Session s=new Session();
                    s.HistoricalContext=prop.Wnode.HistoricalContext;
                    s.HistoricalContextHex=Hex(s.HistoricalContext);
                    s.HistoricalContextLow16=unchecked((ushort)(s.HistoricalContext&0xffff));
                    s.Name=ReadString(buffers[i],prop.LoggerNameOffset,totalSize);
                    s.LogFileName=ReadString(buffers[i],prop.LogFileNameOffset,totalSize);
                    s.Guid=prop.Wnode.Guid.ToString();
                    s.LogFileModeHex="0x"+prop.LogFileMode.ToString("X8");
                    s.EventsLost=prop.EventsLost;s.BuffersWritten=prop.BuffersWritten;
                    r.Sessions.Add(s);
                }
                return;
            } finally {
                foreach (IntPtr p in buffers) if (p!=IntPtr.Zero) Marshal.FreeHGlobal(p);
            }
        }
        throw new InvalidOperationException("ETW sessions changed repeatedly during enumeration.");
    }
    static void ReadProvider(Result r, Guid provider) {
        uint bytes=0, needed=0;
        IntPtr buffer=IntPtr.Zero;
        try {
            for (int attempt=0;attempt<8;attempt++) {
                r.ProviderQueryStatus=EnumerateTraceGuidsEx(1,ref provider,16,buffer,bytes,out needed);
                r.ProviderQueryMessage=Error(r.ProviderQueryStatus);
                if (r.ProviderQueryStatus==122 || (r.ProviderQueryStatus==0 && buffer==IntPtr.Zero && needed>0)) {
                    if (needed>1024*1024 || needed<8) throw new InvalidOperationException("Unexpected provider buffer size.");
                    if (buffer!=IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                    bytes=needed;
                    buffer=Marshal.AllocHGlobal(checked((int)bytes));
                    continue;
                }
                if (r.ProviderQueryStatus!=0) return;
                if (needed<8 || needed>bytes) throw new InvalidOperationException("Invalid provider result length.");
                TRACE_GUID_INFO guid=(TRACE_GUID_INFO)Marshal.PtrToStructure(buffer,typeof(TRACE_GUID_INFO));
                r.ProviderInstanceCount=guid.InstanceCount;
                int pos=8;
                for (uint i=0;i<guid.InstanceCount;i++) {
                    if ((long)pos+16>needed) throw new InvalidOperationException("Truncated provider instance.");
                    TRACE_PROVIDER_INSTANCE_INFO instance=(TRACE_PROVIDER_INSTANCE_INFO)Marshal.PtrToStructure(IntPtr.Add(buffer,pos),typeof(TRACE_PROVIDER_INSTANCE_INFO));
                    if ((long)pos+16+(long)instance.EnableCount*32>needed) throw new InvalidOperationException("Truncated provider enable records.");
                    for (uint j=0;j<instance.EnableCount;j++) {
                        TRACE_ENABLE_INFO en=(TRACE_ENABLE_INFO)Marshal.PtrToStructure(IntPtr.Add(buffer,checked(pos+16+(int)j*32)),typeof(TRACE_ENABLE_INFO));
                        Consumer c=new Consumer();
                        c.ProviderInstanceIndex=i;c.ProviderProcessId=instance.Pid;c.ProviderInstanceFlags=instance.Flags;
                        c.IsEnabled=en.IsEnabled;c.LoggerId=en.LoggerId;c.Level=en.Level;c.EnableProperty=en.EnableProperty;
                        c.EnablePropertyHex="0x"+en.EnableProperty.ToString("X8");c.MatchAnyKeyword=Hex(en.MatchAnyKeyword);c.MatchAllKeyword=Hex(en.MatchAllKeyword);
                        c.SessionMatch="unmatched (permission, private session, or concurrent change possible)";
                        List<Session> exact=r.Sessions.FindAll(delegate(Session s) { return s.HistoricalContext==en.LoggerId; });
                        if (exact.Count==1) { c.SessionName=exact[0].Name;c.SessionIdHex=exact[0].HistoricalContextHex;c.SessionMatch="exact HistoricalContext = LoggerId"; }
                        else {
                            List<Session> low=r.Sessions.FindAll(delegate(Session s) { return s.HistoricalContextLow16==en.LoggerId; });
                            if (low.Count==1) { c.SessionName=low[0].Name;c.SessionIdHex=low[0].HistoricalContextHex;c.SessionMatch="unique low-16-bit candidate; full HistoricalContext retained"; }
                        }
                        r.Consumers.Add(c);
                    }
                    if (i+1<guid.InstanceCount) {
                        if (instance.NextOffset<16+instance.EnableCount*32 || (long)pos+instance.NextOffset>needed)
                            throw new InvalidOperationException("Invalid next provider instance offset.");
                        pos=checked(pos+(int)instance.NextOffset);
                    }
                }
                return;
            }
            throw new InvalidOperationException("Provider registrations changed repeatedly during enumeration.");
        } finally { if (buffer!=IntPtr.Zero) Marshal.FreeHGlobal(buffer); }
    }
    public static Result Read(Guid provider) {
        ValidateLayout();
        Result r=new Result();r.CapturedUtc=DateTime.UtcNow.ToString("o");r.ProviderGuid=provider.ToString();
        r.Note="Read-only enumeration. ProviderProcessId identifies the registering provider instance, NOT the process that created/enabled the session. QueryAllTraces visibility depends on permissions and excludes private sessions. These sequential snapshots are not atomic; unmatched sessions do not imply absence. A session name alone does not prove which service owns it.";
        ReadSessions(r);ReadProvider(r,provider);return r;
    }
}
'@
}
if ($CompileOnly) {
    [DxgEtwReadOnly]::ValidateLayout()
    return
}
$result = [DxgEtwReadOnly]::Read($ProviderGuid)
$result | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result.Consumers | Format-Table LoggerId,SessionName,Level,MatchAnyKeyword,MatchAllKeyword,EnablePropertyHex,SessionMatch -AutoSize
[pscustomobject]@{ OutputPath=$OutputPath; SessionQueryStatus=$result.SessionQueryStatus; ProviderQueryStatus=$result.ProviderQueryStatus; ProviderInstances=$result.ProviderInstanceCount; EnabledRecords=$result.Consumers.Count; SessionsVisible=$result.Sessions.Count }
