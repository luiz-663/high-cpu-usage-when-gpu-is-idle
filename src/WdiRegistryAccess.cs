using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

// Opens only the existing, reviewed WDI instrumentation key using Windows backup/
// restore access. Does not change ownership, ACLs, or any registry value itself.
public static class WdiRegistryAccess {
    const string KeyPath = @"SYSTEM\CurrentControlSet\Control\WDI\Scenarios\{186f47ef-626c-4670-800a-4a30756babad}\Instrumentation\{802ec45a-1e99-4b83-9920-87c98277ba9d};2";
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_PRIVILEGES { public uint Count; public LUID Luid; public uint Attributes; }
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool OpenProcessToken(IntPtr process, uint desiredAccess, out IntPtr token);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool LookupPrivilegeValueW(string system, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState,
        uint length, out TOKEN_PRIVILEGES previous, out uint returned);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    static extern int RegCreateKeyExW(IntPtr baseKey, string subkey, uint reserved, string keyClass,
        uint options, uint desiredAccess, IntPtr security, out SafeRegistryHandle key, out uint disposition);

    static TOKEN_PRIVILEGES Enable(IntPtr token, string name) {
        LUID luid;
        if (!LookupPrivilegeValueW(null, name, out luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
        TOKEN_PRIVILEGES requested = new TOKEN_PRIVILEGES();
        requested.Count = 1; requested.Luid = luid; requested.Attributes = 2;
        TOKEN_PRIVILEGES previous; uint returned;
        if (!AdjustTokenPrivileges(token, false, ref requested, 16, out previous, out returned))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        int status = Marshal.GetLastWin32Error();
        if (status != 0) throw new Win32Exception(status, "Privilege was not assigned");
        return previous;
    }
    static void Restore(IntPtr token, TOKEN_PRIVILEGES previous) {
        if (previous.Count == 0) return;
        TOKEN_PRIVILEGES ignored; uint returned;
        if (!AdjustTokenPrivileges(token, false, ref previous, 16, out ignored, out returned))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public static RegistryKey OpenExistingReviewedKey() {
        if (IntPtr.Size != 8) throw new InvalidOperationException("64-bit process required.");
        using (RegistryKey lm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
        using (RegistryKey read = lm.OpenSubKey(KeyPath, false)) {
            if (read == null || read.GetValueKind("Keyword") != RegistryValueKind.QWord)
                throw new InvalidOperationException("The reviewed existing registry value is missing.");
            long value = Convert.ToInt64(read.GetValue("Keyword"));
            if (value != 0x02000000L && value != 0x00010000L)
                throw new InvalidOperationException("Unexpected registry value.");
        }
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        TOKEN_PRIVILEGES backup = new TOKEN_PRIVILEGES(), restore = new TOKEN_PRIVILEGES();
        bool backupEnabled = false, restoreEnabled = false;
        try {
            backup = Enable(token, "SeBackupPrivilege"); backupEnabled = true;
            restore = Enable(token, "SeRestorePrivilege"); restoreEnabled = true;
            SafeRegistryHandle handle; uint disposition;
            int status = RegCreateKeyExW(new IntPtr(unchecked((int)0x80000002)), KeyPath, 0, null, 4, 0, IntPtr.Zero, out handle, out disposition);
            if (status != 0) { if (handle != null) handle.Dispose(); throw new Win32Exception(status); }
            if (disposition != 2) { handle.Dispose(); throw new InvalidOperationException("Expected an existing key; no value was written."); }
            return RegistryKey.FromHandle(handle, RegistryView.Registry64);
        } finally {
            try { if (restoreEnabled) Restore(token, restore); }
            finally { try { if (backupEnabled) Restore(token, backup); } finally { CloseHandle(token); } }
        }
    }
}
