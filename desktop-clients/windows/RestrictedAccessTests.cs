using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

internal static class RestrictedAccessTests
{
    internal static void CheckControl(Func<string> command)
    {
        string answer;
        using (var token = Restricted()) answer = WindowsIdentity.RunImpersonated(token, command);
        if (answer != "administrator_required") throw new Exception("Restricted client can replace registration ownership: " + answer);
        Console.WriteLine("PASS restricted client cannot begin machine registration");
    }
    internal static void Run(string directory, params string[] journals)
    {
        if (journals.Length == 0) journals = new[] { "guard.json" };
        bool journalReadDenied = true, journalWriteDenied = true, statusWriteDenied = false, statusReadable = false;
        using (var token = Restricted())
            WindowsIdentity.RunImpersonated(token, () =>
            {
                foreach (string name in journals)
                {
                    journalReadDenied &= Denied(() => File.ReadAllText(Path.Combine(directory, name)));
                    journalWriteDenied &= Denied(() => OpenForWrite(Path.Combine(directory, name)));
                }
                statusWriteDenied = Denied(() => OpenForWrite(Path.Combine(directory, "status.json")));
                statusReadable = File.ReadAllText(Path.Combine(directory, "status.json")).Length > 0;
            });
        if (!journalReadDenied || !journalWriteDenied || !statusWriteDenied || !statusReadable)
            throw new Exception("Restricted token can access protected state or cannot read status");
        Console.WriteLine("PASS restricted client can read status but cannot access journal or change status");
    }

    // This process's token without Administrators and restricted to Users.
    private static SafeAccessTokenHandle Restricted()
    {
        IntPtr admin = Sid(WellKnownSidType.BuiltinAdministratorsSid), users = Sid(WellKnownSidType.BuiltinUsersSid);
        try
        {
            var disabled = new SidAndAttributes { Sid = admin };
            var restricted = new SidAndAttributes { Sid = users };
            SafeAccessTokenHandle token;
            using (var current = WindowsIdentity.GetCurrent())
                if (!CreateRestrictedToken(current.Token, 1, 1, ref disabled, 0, IntPtr.Zero, 1, ref restricted, out token))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            return token;
        }
        finally { Marshal.FreeHGlobal(admin); Marshal.FreeHGlobal(users); }
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
        uint deleteCount, IntPtr delete, uint restrictCount, ref SidAndAttributes restrict, out SafeAccessTokenHandle token);
}
