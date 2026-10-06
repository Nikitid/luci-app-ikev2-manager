using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;

internal static class RestrictedAccessTests
{
    internal static void CheckControl(Func<string> command)
    {
        IntPtr admin = Sid(WellKnownSidType.BuiltinAdministratorsSid), users = Sid(WellKnownSidType.BuiltinUsersSid), token = IntPtr.Zero;
        try
        {
            var disabled = new SidAndAttributes { Sid = admin };
            var restricted = new SidAndAttributes { Sid = users };
            using (var current = WindowsIdentity.GetCurrent())
                if (!CreateRestrictedToken(current.Token, 1, 1, ref disabled, 0, IntPtr.Zero, 1, ref restricted, out token))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            using (WindowsIdentity.Impersonate(token))
                if (command() != "administrator_required") throw new Exception("Restricted client can replace registration ownership");
            Console.WriteLine("PASS restricted client cannot begin machine registration");
        }
        finally { if (token != IntPtr.Zero) CloseHandle(token); Marshal.FreeHGlobal(admin); Marshal.FreeHGlobal(users); }
    }
    internal static void Run(string directory, params string[] journals)
    {
        IntPtr admin = Sid(WellKnownSidType.BuiltinAdministratorsSid);
        IntPtr users = Sid(WellKnownSidType.BuiltinUsersSid);
        IntPtr token = IntPtr.Zero;
        try
        {
            var disabled = new SidAndAttributes { Sid = admin };
            var restricted = new SidAndAttributes { Sid = users };
            using (var current = WindowsIdentity.GetCurrent())
                if (!CreateRestrictedToken(current.Token, 1, 1, ref disabled, 0, IntPtr.Zero, 1, ref restricted, out token))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            if (journals.Length == 0) journals = new[] { "guard.json" };
            bool journalReadDenied = true, journalWriteDenied = true, statusWriteDenied, statusReadable;
            using (WindowsIdentity.Impersonate(token))
            {
                foreach (string name in journals)
                {
                    journalReadDenied &= Denied(() => File.ReadAllText(Path.Combine(directory, name)));
                    journalWriteDenied &= Denied(() => OpenForWrite(Path.Combine(directory, name)));
                }
                statusWriteDenied = Denied(() => OpenForWrite(Path.Combine(directory, "status.json")));
                statusReadable = File.ReadAllText(Path.Combine(directory, "status.json")).Length > 0;
            }
            if (!journalReadDenied || !journalWriteDenied || !statusWriteDenied || !statusReadable)
                throw new Exception("Restricted token can access protected state or cannot read status");
            Console.WriteLine("PASS restricted client can read status but cannot access journal or change status");
        }
        finally
        {
            if (token != IntPtr.Zero) CloseHandle(token);
            Marshal.FreeHGlobal(admin);
            Marshal.FreeHGlobal(users);
        }
    }

    private static void OpenForWrite(string path)
    {
        // Check access without changing bytes even if the ACL regresses.
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) { }
    }

    private static bool Denied(Action action)
    {
        try { action(); return false; }
        catch (UnauthorizedAccessException) { return true; }
    }

    private static IntPtr Sid(WellKnownSidType type)
    {
        var value = new SecurityIdentifier(type, null);
        var bytes = new byte[value.BinaryLength];
        value.GetBinaryForm(bytes, 0);
        IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        return pointer;
    }

    [StructLayout(LayoutKind.Sequential)] private struct SidAndAttributes { internal IntPtr Sid; internal uint Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool CreateRestrictedToken(IntPtr existing, uint flags, uint disableCount, ref SidAndAttributes disable,
        uint deleteCount, IntPtr delete, uint restrictCount, ref SidAndAttributes restrict, out IntPtr token);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
