using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

// Read-only NodePerfData query, modeled on the original reproduction.
// This code does not create a Direct3D device or submit graphics work.
public static class GpuQueryProbe
{
    const int DxgiNotFound = unchecked((int)0x887A0002);
    const uint NvidiaVendorId = 0x10DE;
    const uint NodePerfData = 61;
    const int NodePerfDataSize = 56;
    public const int SampleCount = 20;
    const int WarmupCount = 3;

    [StructLayout(LayoutKind.Sequential)]
    struct Luid
    {
        public uint Low;
        public int High;
        public override string ToString() { return High.ToString("X8") + Low.ToString("X8"); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct AdapterDescription
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Name;
        public uint VendorId, DeviceId, SubsystemId, Revision;
        public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
        public Luid Id;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct OpenArgs
    {
        public Luid Id;
        public uint Handle;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct QueryArgs
    {
        public uint Handle, Type;
        public IntPtr Data;
        public uint Size;
    }

    [DllImport("dxgi.dll", ExactSpelling = true)]
    static extern int CreateDXGIFactory1(ref Guid id, out IntPtr factory);
    [DllImport("gdi32.dll", ExactSpelling = true)]
    static extern int D3DKMTOpenAdapterFromLuid(ref OpenArgs args);
    [DllImport("gdi32.dll", ExactSpelling = true)]
    static extern int D3DKMTCloseAdapter(ref uint handle);
    [DllImport("gdi32.dll", ExactSpelling = true)]
    static extern int D3DKMTQueryAdapterInfo(ref QueryArgs args);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int EnumAdapters1(IntPtr factory, uint index, out IntPtr adapter);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetDesc1(IntPtr adapter, out AdapterDescription description);

    public sealed class Sample
    {
        public double IntervalSeconds { get; set; }
        public double SystemCPU { get; set; }
        public double QueryMilliseconds { get; set; }
    }

    public sealed class Measurement
    {
        public string Adapter { get; set; }
        public string AdapterId { get; set; }
        public List<Sample> Samples { get; private set; }
        public Measurement() { Samples = new List<Sample>(); }
    }

    public static void ValidateLayout()
    {
        if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(AdapterDescription)) != 312 ||
            Marshal.OffsetOf(typeof(AdapterDescription), "Id").ToInt32() != 296 ||
            Marshal.SizeOf(typeof(OpenArgs)) != 12 || Marshal.SizeOf(typeof(QueryArgs)) != 24)
            throw new PlatformNotSupportedException("Unexpected x64 DXGI/D3DKMT structure layout.");
    }

    static T ComMethod<T>(IntPtr instance, int slot) where T : class
    {
        IntPtr address = Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), slot * IntPtr.Size);
        return Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
    }

    static AdapterDescription FindNvidiaAdapter()
    {
        Guid factoryGuid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
        IntPtr factory;
        Marshal.ThrowExceptionForHR(CreateDXGIFactory1(ref factoryGuid, out factory));
        try
        {
            var enumerate = ComMethod<EnumAdapters1>(factory, 12);
            var nvidia = new List<AdapterDescription>();
            for (uint index = 0; ; index++)
            {
                IntPtr adapter;
                int status = enumerate(factory, index, out adapter);
                if (status == DxgiNotFound) break;
                Marshal.ThrowExceptionForHR(status);
                try
                {
                    AdapterDescription description;
                    Marshal.ThrowExceptionForHR(ComMethod<GetDesc1>(adapter, 10)(adapter, out description));
                    if (description.VendorId == NvidiaVendorId && (description.Flags & 2) == 0)
                        nvidia.Add(description);
                }
                finally { Marshal.Release(adapter); }
            }
            if (nvidia.Count != 1)
                throw new InvalidOperationException("The comparison requires exactly one NVIDIA hardware adapter.");
            return nvidia[0];
        }
        finally { Marshal.Release(factory); }
    }

    static void CheckStatus(int status, string operation)
    {
        if (status != 0)
            throw new InvalidOperationException(operation + " returned NTSTATUS 0x" + status.ToString("X8") + ".");
    }

    public static Measurement Measure(string expectedAdapterId)
    {
        ValidateLayout();
        var adapter = FindNvidiaAdapter();
        var measurement = new Measurement { Adapter = adapter.Name, AdapterId = adapter.Id.ToString() };
        if (!String.IsNullOrEmpty(expectedAdapterId) &&
            !String.Equals(measurement.AdapterId, expectedAdapterId, StringComparison.Ordinal))
            throw new InvalidOperationException("The NVIDIA adapter changed between the two measurements.");

        var open = new OpenArgs { Id = adapter.Id };
        CheckStatus(D3DKMTOpenAdapterFromLuid(ref open), "Opening the NVIDIA adapter");
        try
        {
            IntPtr buffer = Marshal.AllocHGlobal(NodePerfDataSize);
            try
            {
                using (var system = Process.GetProcessById(4))
                {
                    var emptyData = new byte[NodePerfDataSize];
                    var query = new QueryArgs { Handle = open.Handle, Type = NodePerfData, Data = buffer, Size = NodePerfDataSize };
                    var timer = Stopwatch.StartNew();
                    var queryTimer = new Stopwatch();
                    system.Refresh();
                    double previousCpu = system.TotalProcessorTime.TotalSeconds;
                    double previousTime = timer.Elapsed.TotalSeconds;
                    for (int i = 0; i < WarmupCount + SampleCount; i++)
                    {
                        // A zeroed buffer requests engine 0 on the first physical adapter.
                        Marshal.Copy(emptyData, 0, buffer, emptyData.Length);
                        queryTimer.Restart();
                        int status = D3DKMTQueryAdapterInfo(ref query);
                        double queryMilliseconds = queryTimer.Elapsed.TotalMilliseconds;
                        CheckStatus(status, "Querying NVIDIA NodePerfData");
                        if (i >= WarmupCount && queryMilliseconds >= 1000)
                            throw new InvalidOperationException("The read took too long to maintain one query per second.");

                        double remaining = 1000 * (previousTime + 1 - timer.Elapsed.TotalSeconds);
                        if (remaining > 0) Thread.Sleep((int)Math.Ceiling(remaining));
                        system.Refresh();
                        double cpu = system.TotalProcessorTime.TotalSeconds;
                        double time = timer.Elapsed.TotalSeconds;
                        double interval = time - previousTime;
                        if (i >= WarmupCount && (interval < 0.98 || interval > 1.25 || cpu < previousCpu))
                            throw new InvalidOperationException("A CPU sample interval was interrupted. Repeat the comparison with the PC idle.");
                        if (i >= WarmupCount)
                            measurement.Samples.Add(new Sample {
                                IntervalSeconds = interval,
                                SystemCPU = 100 * (cpu - previousCpu) / interval / Environment.ProcessorCount,
                                QueryMilliseconds = queryMilliseconds
                            });
                        previousCpu = cpu;
                        previousTime = time;
                    }
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        finally { CheckStatus(D3DKMTCloseAdapter(ref open.Handle), "Closing the NVIDIA adapter"); }
        return measurement;
    }
}
