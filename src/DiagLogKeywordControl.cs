using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DiagLogKeywordControl {
    [StructLayout(LayoutKind.Sequential)]
    struct ENABLE_TRACE_PARAMETERS {
        public uint Version, EnableProperty, ControlFlags;
        public Guid SourceId;
        public IntPtr EnableFilterDesc;
        public uint FilterDescCount;
    }
    [DllImport("advapi32.dll", ExactSpelling=true)]
    static extern uint EnableTraceEx2(ulong traceHandle, ref Guid provider, uint controlCode,
        byte level, ulong anyKeyword, ulong allKeyword, uint timeout,
        ref ENABLE_TRACE_PARAMETERS parameters);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetSystemTimes(out long idle, out long kernel, out long user);

    public static string ValidateLayout() {
        if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(ENABLE_TRACE_PARAMETERS)) != 48 ||
            Marshal.OffsetOf(typeof(ENABLE_TRACE_PARAMETERS), "EnableFilterDesc").ToInt32() != 32)
            throw new InvalidOperationException("Unexpected ENABLE_TRACE_PARAMETERS x64 layout.");
        return "ENABLE_TRACE_PARAMETERS x64 layout verified (48 bytes).";
    }
    public static void SetKeywords(ulong handle, ulong anyKeyword) {
        ValidateLayout();
        if (handle == 0 || (anyKeyword != 0x02030000UL && anyKeyword != 0x00030000UL))
            throw new ArgumentException("Only the two reviewed DiagLog keyword masks are allowed.");
        Guid provider = new Guid("802ec45a-1e99-4b83-9920-87c98277ba9d");
        ENABLE_TRACE_PARAMETERS p = new ENABLE_TRACE_PARAMETERS();
        p.Version = 2;
        p.EnableProperty = 0x40; // Preserve the observed modern-provider enable properties.
        uint error = EnableTraceEx2(handle, ref provider, 1, 255, anyKeyword, 0, 5000, ref p);
        if (error != 0) throw new Win32Exception(unchecked((int)error), "EnableTraceEx2 failed");
    }
    public static long[] ReadCpuTimes() {
        long idle, kernel, user;
        if (!GetSystemTimes(out idle, out kernel, out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return new long[] { idle, kernel, user };
    }
}
