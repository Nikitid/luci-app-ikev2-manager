using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Linq;
using System.Web.Script.Serialization;

namespace IkeV2Manager.Client
{
    public sealed class ClientView
    {
        public string State { get; private set; }
        public bool GuardInstalled { get; private set; }
        // Derived, never stored: the one state the service publishes only
        // while the router's readiness for this tunnel is fresh.
        public bool Protected { get { return State == "protected"; } }
        public string ConnectionError { get; private set; }
        public string[] Services { get; private set; }
        public int Domains { get; private set; }
        public int Revision { get; private set; }
        public bool Wanted { get; private set; }
        // The tunnel and the selected routes through it are confirmed in both.
        public bool Routed { get { return State == "tunnel_connected" || State == "protected"; } }
        internal ClientView(string state, bool installed = false, string connectionError = "none",
            string[] services = null, int domains = 0, int revision = 0, bool wanted = false, string[] available = null)
        {
            State = state; GuardInstalled = installed; ConnectionError = connectionError;
            Services = services ?? new string[0]; Available = available ?? new string[0]; Domains = domains; Revision = revision; Wanted = wanted;
        }
        public string[] Available { get; private set; }

        public string Report()
        {
            return new JavaScriptSerializer().Serialize(new { Version = 3, State = State,
                GuardInstalled = GuardInstalled, Protected = Protected, Routed = Routed, ConnectionWanted = Wanted,
                ConnectionError = ConnectionError, Services = Services, AvailableServices = Available, Domains = Domains, PolicyRevision = Revision, CreatedAtUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) });
        }
    }

    public static class ClientStatusReader
    {
        public static ClientView Read(string name = "IKEv2ManagerClient")
        {
            if (name != "IKEv2ManagerClient" && !Regex.IsMatch(name ?? "", @"\AIKEv2Manager-Test-[a-f0-9]{32}\z"))
                throw new ArgumentException("Unknown client installation");
            IntPtr manager = IntPtr.Zero, service = IntPtr.Zero;
            try
            {
                manager = Native.OpenSCManagerW(null, null, 1);
                if (manager == IntPtr.Zero) return new ClientView("service_unavailable");
                service = Native.OpenServiceW(manager, name, 4);
                if (service == IntPtr.Zero)
                    return new ClientView(Marshal.GetLastWin32Error() == 1060 ? "service_missing" : "service_unavailable");
                Native.Status status;
                uint required;
                if (!Native.QueryServiceStatusEx(service, 0, out status, (uint)Marshal.SizeOf(typeof(Native.Status)), out required))
                    return new ClientView("service_unavailable");
                if (status.State != 4 || status.Process == 0) return new ClientView("service_stopped");
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name, "status.json");
                if (!File.Exists(path)) return new ClientView("status_missing");
                if (!TrustedFile(path)) return new ClientView("status_untrusted");
                using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (file.Length == 0 || file.Length > 8192) return new ClientView("status_invalid");
                    using (var reader = new StreamReader(file, new UTF8Encoding(false, true), false))
                        return Evaluate(reader.ReadToEnd(), status.Process, DateTime.UtcNow);
                }
            }
            catch (UnauthorizedAccessException) { return new ClientView("status_untrusted"); }
            catch (IOException) { return new ClientView("status_unavailable"); }
            catch (ArgumentException) { return new ClientView("status_invalid"); }
            finally
            {
                if (service != IntPtr.Zero) Native.CloseServiceHandle(service);
                if (manager != IntPtr.Zero) Native.CloseServiceHandle(manager);
            }
        }

        internal static ClientView Evaluate(string json, uint servicePid, DateTime now)
        {
            try
            {
                var serializer = new JavaScriptSerializer { MaxJsonLength = 8192, RecursionLimit = 4 };
                var data = serializer.DeserializeObject(json) as Dictionary<string, object>;
                if (data == null || !data.ContainsKey("Version") || !(data["Version"] is int)) return new ClientView("status_invalid");
                int version = (int)data["Version"];
                if (version < 1 || version > 3 || data.Count != (version == 1 ? 6 : version == 2 ? 7 : 12) || !data.ContainsKey("State") ||
                    !data.ContainsKey("GuardInstalled") || !data.ContainsKey("Protected") ||
                    !data.ContainsKey("UpdatedAtUtc") || !data.ContainsKey("ProcessId") ||
                    !(data["ProcessId"] is int) ||
                    !(data["State"] is string) || !(data["GuardInstalled"] is bool) || !(data["Protected"] is bool) ||
                    !(data["UpdatedAtUtc"] is string)) return new ClientView("status_invalid");
                string connectionError = "none";
                if (version >= 2)
                {
                    if (!data.ContainsKey("ConnectionError") || !(data["ConnectionError"] is string) ||
                        !Regex.IsMatch((string)data["ConnectionError"], @"\A(?:none|route_or_identity|interface_missing|route_mismatch|route_loopback|route_interface|route_source|route_prefix|route_fields_[0-9]{1,3}|projection_missing|native_[0-9]{1,5}|path_unavailable|path_connection_failed|path_response_invalid|path_different_policy|device_access_revoked)\z")) return new ClientView("status_invalid");
                    connectionError = (string)data["ConnectionError"];
                }
                if (servicePid == 0 || (int)data["ProcessId"] <= 0 || (int)data["ProcessId"] != servicePid)
                    return new ClientView("status_process_mismatch");
                DateTime updated;
                if (!DateTime.TryParseExact((string)data["UpdatedAtUtc"], "o", CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out updated) || updated.Kind != DateTimeKind.Utc)
                    return new ClientView("status_invalid");
                if (now.Kind != DateTimeKind.Utc || now - updated > TimeSpan.FromSeconds(15) || updated - now > TimeSpan.FromSeconds(2))
                    return new ClientView("status_stale");
                string state = (string)data["State"];
                bool guard = (bool)data["GuardInstalled"];
                // "Protected" and the state must say the same thing, and a
                // protected status carries no error: anything else is not ours.
                if ((bool)data["Protected"] != (state == "protected") || (state == "protected" && connectionError != "none") ||
                    (state != "blocked" && state != "enrollment_required" && state != "error" && state != "access_closed" &&
                    state != "registration_pending" && state != "registration_error" && state != "connecting" &&
                    state != "tunnel_connected" && state != "connection_error" && state != "protected") ||
                    ((state == "blocked" || state == "connecting" || state == "tunnel_connected" || state == "connection_error" || state == "protected") && !guard) || (state == "enrollment_required" && guard))
                    return new ClientView("status_invalid");
                // Older statuses never carried protection; they cannot claim it.
                if (version < 3) return new ClientView(state == "protected" ? "status_invalid" : state, guard, connectionError);
                object[] listed = data.ContainsKey("Services") ? data["Services"] as object[] : null;
                object[] offered = data.ContainsKey("Available") ? data["Available"] as object[] : null;
                if (listed == null || listed.Length > 64 || offered == null || offered.Length > 64 ||
                    offered.Any(item => !(item is string) || !Regex.IsMatch((string)item, @"\A[a-z0-9][a-z0-9_-]{0,47}\z")) || !(data.ContainsKey("Domains") && data["Domains"] is int) ||
                    !(data.ContainsKey("Revision") && data["Revision"] is int) || !(data.ContainsKey("Wanted") && data["Wanted"] is bool) ||
                    (int)data["Domains"] < 0 || (int)data["Revision"] < 0 ||
                    listed.Any(item => !(item is string) || !Regex.IsMatch((string)item, @"\A[a-z0-9][a-z0-9_-]{0,47}\z")) ||
                    ((state == "protected" || state == "tunnel_connected") && !(bool)data["Wanted"]))
                    return new ClientView("status_invalid");
                return new ClientView(state, guard, connectionError, listed.Cast<string>().ToArray(), (int)data["Domains"], (int)data["Revision"], (bool)data["Wanted"], offered.Cast<string>().ToArray());
            }
            catch (ArgumentException) { return new ClientView("status_invalid"); }
            catch (InvalidOperationException) { return new ClientView("status_invalid"); }
        }

        private static bool TrustedFile(string path)
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return false;
            var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            var users = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
            var security = File.GetAccessControl(path, AccessControlSections.Owner | AccessControlSections.Access);
            var owner = (SecurityIdentifier)security.GetOwner(typeof(SecurityIdentifier));
            if ((!owner.Equals(administrators) && !owner.Equals(system)) || !security.AreAccessRulesProtected) return false;
            var granted = new HashSet<string>();
            foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType != AccessControlType.Allow || rule.IsInherited) return false;
                if (rule.IdentityReference.Equals(administrators) || rule.IdentityReference.Equals(system))
                {
                    if (rule.FileSystemRights != FileSystemRights.FullControl) return false;
                }
                else if (!rule.IdentityReference.Equals(users) ||
                    (rule.FileSystemRights & ~(FileSystemRights.Read | FileSystemRights.Synchronize)) != 0 ||
                    (rule.FileSystemRights & FileSystemRights.Read) != FileSystemRights.Read) return false;
                granted.Add(rule.IdentityReference.Value);
            }
            return granted.Count == 3;
        }

        private static class Native
        {
            [StructLayout(LayoutKind.Sequential)] internal struct Status
            {
                internal uint Type, State, Accepted, Win32ExitCode, ServiceExitCode, CheckPoint, WaitHint, Process, Flags;
            }
            [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
            internal static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
            [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
            internal static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
            [DllImport("advapi32.dll", SetLastError = true)]
            internal static extern bool QueryServiceStatusEx(IntPtr service, uint level, out Status status, uint bytes, out uint required);
            [DllImport("advapi32.dll")] internal static extern bool CloseServiceHandle(IntPtr handle);
        }
    }
}
