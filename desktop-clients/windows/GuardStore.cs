using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using System.Linq;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace IkeV2Manager.Client
{
    // One controller owns the store for its entire lifetime. The directory and
    // journal are unavailable to unelevated processes, including the desktop UI.
    public sealed class GuardStore : IDisposable
    {
        private static readonly SecurityIdentifier Administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        private static readonly SecurityIdentifier SystemAccount = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        private readonly string directory;
        private readonly FileStream controllerLock;
        private const int Limit = 1024 * 1024;
        internal string DirectoryPath { get { CheckOpen(); VerifyDirectory(); return directory; } }

        public GuardStore(string directoryName)
        {
            if (directoryName == null || !Regex.IsMatch(directoryName, @"\A[A-Za-z0-9][A-Za-z0-9.-]{0,63}\z"))
                throw new ArgumentException("A single store directory name is required");
            string parent = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            RejectLink(parent);
            directory = Path.Combine(parent, directoryName);
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(Administrators);
            foreach (SecurityIdentifier sid in new[] { Administrators, SystemAccount })
                security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                    PropagationFlags.None, AccessControlType.Allow));
            Directory.CreateDirectory(directory, security);
            VerifyDirectory();
            string lockPath = Path.Combine(directory, "controller.lock");
            if (File.Exists(lockPath)) VerifyFile(lockPath);
            controllerLock = new FileStream(lockPath, FileMode.OpenOrCreate, FileSystemRights.Read | FileSystemRights.Write,
                FileShare.None, 4096, FileOptions.WriteThrough, FileSecurity());
        }

        public void SavePlan(GuardReceipt plan)
        {
            CheckOpen();
            VerifyDirectory();
            string destination = Path.Combine(directory, "guard.json");
            if (File.Exists(destination)) throw new InvalidOperationException("A protection plan already exists");
            WritePlan(WfpGuard.ExtendPlan(plan, new System.Net.IPAddress[0]), false);
        }

        public void ExtendPlan(GuardReceipt plan)
        {
            CheckOpen();
            GuardReceipt previous = LoadPlan();
            if (previous == null || plan == null || plan.Version != previous.Version || plan.Owner != previous.Owner ||
                plan.Addresses == null || plan.Filters == null || plan.Addresses.Length < previous.Addresses.Length ||
                plan.Filters.Length != plan.Addresses.Length * 5 ||
                !previous.Addresses.SequenceEqual(plan.Addresses.Take(previous.Addresses.Length)) ||
                !previous.Filters.SequenceEqual(plan.Filters.Take(previous.Filters.Length)))
                throw new InvalidOperationException("Protection updates must preserve previous destinations and identities");
            // Validate the complete union before publishing it. This opens a WFP
            // management session but installs no rules and grants no permission.
            GuardReceipt validated = WfpGuard.ExtendPlan(plan, new System.Net.IPAddress[0]);
            WritePlan(validated, true);
        }

        private void WritePlan(GuardReceipt plan, bool replace)
        {
            WriteProtectedJson("guard.json", new JavaScriptSerializer().Serialize(plan), Limit, replace);
        }

        private void WriteProtectedJson(string name, string json, int maximum, bool replace)
        {
            string destination = Path.Combine(directory, name);
            byte[] data = new UTF8Encoding(false, true).GetBytes(json);
            if (data.Length > maximum) throw new InvalidOperationException("Protection journal exceeds limit");
            string temporary = Path.Combine(directory, "journal-" + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileSystemRights.Write, FileShare.None,
                    4096, FileOptions.WriteThrough, FileSecurity()))
                {
                    stream.Write(data, 0, data.Length);
                    stream.Flush(true);
                }
                // Same-volume rename publishes only a completely flushed file.
                if (!MoveFileExW(temporary, destination, replace ? 9u : 8u)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Protection plan publication failed");
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }

        // Whether the user last asked for the tunnel. It outlives the service
        // so a restart or reboot returns to the state the user left.
        public bool LoadConnectionIntent()
        {
            CheckOpen(); VerifyDirectory();
            string path = Path.Combine(directory, "connection.json");
            if (!File.Exists(path)) return false;
            VerifyFile(path);
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (stream.Length < 1 || stream.Length > 64) throw new InvalidOperationException("Invalid connection journal");
                using (var reader = new StreamReader(stream, new UTF8Encoding(false, true), false))
                {
                    var fields = ClientPolicy.Object(new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()));
                    ClientPolicy.Fields(fields, "version", "wanted");
                    ClientPolicy.Integer(fields["version"], 1, 1);
                    if (!(fields["wanted"] is bool)) throw new InvalidOperationException("Invalid connection journal");
                    return (bool)fields["wanted"];
                }
            }
        }

        public void SaveConnectionIntent(bool wanted)
        {
            CheckOpen(); VerifyDirectory();
            WriteProtectedJson("connection.json", wanted ? "{\"version\":1,\"wanted\":true}" : "{\"version\":1,\"wanted\":false}",
                64, File.Exists(Path.Combine(directory, "connection.json")));
        }

        public GuardReceipt LoadPlan()
        {
            CheckOpen();
            VerifyDirectory();
            string path = Path.Combine(directory, "guard.json");
            if (!File.Exists(path)) return null;
            VerifyFile(path);
            var serializer = new JavaScriptSerializer { MaxJsonLength = Limit, RecursionLimit = 16 };
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (stream.Length <= 0 || stream.Length > Limit) throw new InvalidOperationException("Invalid protection plan size");
                using (var reader = new StreamReader(stream, new UTF8Encoding(false, true), false))
                {
                    string json = reader.ReadToEnd();
                    var fields = serializer.DeserializeObject(json) as Dictionary<string, object>;
                    if (fields == null || fields.Count != 4 || !fields.ContainsKey("Version") ||
                        !fields.ContainsKey("Owner") || !fields.ContainsKey("Addresses") || !fields.ContainsKey("Filters"))
                        throw new InvalidOperationException("Invalid protection plan fields");
                    return serializer.Deserialize<GuardReceipt>(json);
                }
            }
        }

        public PolicyHistory LoadPolicyHistory()
        {
            CheckOpen();
            VerifyDirectory();
            string path = Path.Combine(directory, "policy.json");
            if (!File.Exists(path)) return null;
            VerifyFile(path);
            PolicyHistory history;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (stream.Length <= 0 || stream.Length > 2097152) throw new InvalidOperationException("Invalid policy journal size");
                using (var reader = new StreamReader(stream, new UTF8Encoding(false, true), false))
                    history = PolicyHistory.Restore(reader.ReadToEnd());
            }
            VerifyPolicyCoverage(history, LoadPlan());
            return history;
        }

        public Guid LoadVpnEntry()
        {
            CheckOpen(); VerifyDirectory();
            string path = Path.Combine(directory, "vpn-profile.json"), marker = Path.Combine(directory, "vpn-profile-initialized");
            if (!File.Exists(path))
            {
                if (File.Exists(marker)) throw new InvalidOperationException("VPN profile history requires recovery");
                return Guid.Empty;
            }
            VerifyFile(path);
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (stream.Length < 1 || stream.Length > 1024) throw new InvalidOperationException("Invalid VPN profile journal");
                using (var reader = new StreamReader(stream, new UTF8Encoding(false, true), false))
                {
                    var fields = ClientPolicy.Object(new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()));
                    ClientPolicy.Fields(fields, "version", "owner", "entry_id");
                    ClientPolicy.Integer(fields["version"], 1, 1);
                    Guid owner, entry;
                    if (!Guid.TryParseExact(ClientPolicy.Text(fields["owner"]), "D", out owner) ||
                        !Guid.TryParseExact(ClientPolicy.Text(fields["entry_id"]), "D", out entry) ||
                        entry == Guid.Empty || LoadPlan() == null || owner != LoadPlan().Owner)
                        throw new InvalidOperationException("VPN profile ownership changed");
                    if (!File.Exists(marker)) WriteProtectedJson("vpn-profile-initialized", "1", 1, false);
                    VerifyFile(marker);
                    if (File.ReadAllText(marker) != "1") throw new InvalidOperationException("Invalid VPN profile marker");
                    return entry;
                }
            }
        }

        public void SaveVpnEntry(Guid entry)
        {
            Guid previous = LoadVpnEntry(); GuardReceipt plan = LoadPlan();
            if (plan == null || entry == Guid.Empty || (previous != Guid.Empty && previous != entry))
                throw new InvalidOperationException("VPN profile identity changed");
            if (previous == entry) return;
            WriteProtectedJson("vpn-profile.json", new JavaScriptSerializer().Serialize(new Dictionary<string,object> {
                {"version",1}, {"owner",plan.Owner.ToString("D")}, {"entry_id",entry.ToString("D")}
            }), 1024, false);
            if (LoadVpnEntry() != entry) throw new InvalidOperationException("VPN profile journal unavailable");
        }

        // The service must authenticate the source before proposing history.
        // This records protected intent, not successful hosts/route activation.
        public void SavePolicyHistory(PolicyHistory next)
        {
            CheckOpen();
            VerifyDirectory();
            if (next == null) throw new ArgumentNullException("next");
            PolicyHistory previous = LoadPolicyHistory();
            if (previous != null && previous.Propose(next.Current).Export() != next.Export())
                throw new InvalidOperationException("Policy journal update discarded or changed allocation history");
            GuardReceipt plan = LoadPlan();
            VerifyPolicyCoverage(next, plan);
            // A written plan is not proof that WFP installed it. Never publish
            // new intent while its persistent denials are only planned.
            using (var installed = WfpGuard.Recover(plan)) installed.VerifyProtection();
            WriteProtectedJson("policy.json", next.Export(), 2097152, previous != null);
        }

        private static void VerifyPolicyCoverage(PolicyHistory history, GuardReceipt plan)
        {
            if (plan == null || plan.Addresses == null ||
                history.ProtectedAddresses().Any(address => !plan.Addresses.Contains(address)))
                throw new InvalidOperationException("Policy journal is not covered by the protection plan");
        }

        internal string LoadEnrollmentDocument()
        {
            CheckOpen(); VerifyDirectory();
            string path = Path.Combine(directory, "enrollment.json");
            string staged = Path.Combine(directory, "enrollment.pending");
            string marker = Path.Combine(directory, "enrollment-initialized");
            if (!File.Exists(path) && File.Exists(staged))
            {
                // Validate before recovering an interrupted first publication.
                ReadEnrollmentDocument(staged);
                if (!File.Exists(marker)) WriteProtectedJson("enrollment-initialized", "1", 1, false);
                VerifyFile(marker);
                if (!MoveFileExW(staged, path, 8)) throw new InvalidOperationException("Enrollment recovery failed");
            }
            if (!File.Exists(path))
            {
                if (File.Exists(marker)) throw new InvalidOperationException("Enrollment history requires recovery");
                return null;
            }
            if (!File.Exists(marker) || File.Exists(staged)) throw new InvalidOperationException("Enrollment history is inconsistent");
            VerifyFile(marker);
            if (File.ReadAllText(marker) != "1") throw new InvalidOperationException("Enrollment marker is invalid");
            return ReadEnrollmentDocument(path);
        }

        private string ReadEnrollmentDocument(string path)
        {
            VerifyFile(path);
            byte[] plain = null;
            try
            {
                using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    if (file.Length < 1 || file.Length > 2097152) throw new InvalidOperationException();
                    using (var reader = new StreamReader(file, new UTF8Encoding(false, true), false))
                    {
                        byte[] cipher = Convert.FromBase64String(reader.ReadToEnd());
                        plain = ProtectedData.Unprotect(cipher, EnrollmentEntropy(), DataProtectionScope.LocalMachine);
                    }
                }
                if (plain.Length < 1 || plain.Length > Limit) throw new InvalidOperationException();
                return new UTF8Encoding(false, true).GetString(plain);
            }
            catch (CryptographicException) { throw new InvalidOperationException("Enrollment credentials cannot be decrypted"); }
            catch (FormatException) { throw new InvalidOperationException("Enrollment credentials are invalid"); }
            finally { if (plain != null) Array.Clear(plain, 0, plain.Length); }
        }

        private byte[] EnrollmentEntropy()
        {
            // LocalMachine allows the installed LocalSystem service to resume
            // registration initiated by an administrator. ACLs remain mandatory.
            return Encoding.UTF8.GetBytes("IKEv2Manager.Enrollment.v1:" + directory.ToLowerInvariant());
        }

        internal void SaveEnrollmentDocument(string document, bool replace)
        {
            CheckOpen(); VerifyDirectory();
            string previous = LoadEnrollmentDocument();
            if (replace != (previous != null)) throw new InvalidOperationException("Enrollment publication conflicts with history");
            byte[] plain = new UTF8Encoding(false, true).GetBytes(document);
            try
            {
                if (plain.Length == 0 || plain.Length > Limit) throw new InvalidOperationException("Enrollment document exceeds limit");
                string cipher = Convert.ToBase64String(ProtectedData.Protect(plain, EnrollmentEntropy(), DataProtectionScope.LocalMachine));
                if (replace) WriteProtectedJson("enrollment.json", cipher, 2097152, true);
                else
                {
                    WriteProtectedJson("enrollment.pending", cipher, 2097152, false);
                    WriteProtectedJson("enrollment-initialized", "1", 1, false);
                    if (!MoveFileExW(Path.Combine(directory, "enrollment.pending"), Path.Combine(directory, "enrollment.json"), 8))
                        throw new InvalidOperationException("Enrollment publication failed");
                }
            }
            finally { Array.Clear(plain, 0, plain.Length); }
        }

        private string lastFault = "";
        private DateTime lastFaultAt;

        // What went wrong, for the report a user hands to the administrator:
        // when, where, the kind of failure and its code. Messages are kept
        // only for failures this program names itself, so no path, address or
        // secret of the system's own wording gets in. Never throws.
        public void RecordFault(string where, Exception error)
        {
            try
            {
                var native = error as Win32Exception;
                var connection = error as NativeConnectionException;
                var named = error as PolicyFetchException;
                bool own = error.TargetSite != null && error.TargetSite.Module.Assembly == typeof(GuardStore).Assembly;
                string detail = connection != null ? "code " + connection.Code : native != null ? "code " + native.NativeErrorCode :
                    named != null ? named.Code : own ? System.Text.RegularExpressions.Regex.Replace(error.Message ?? "", @"[^A-Za-z0-9 ._-]", "") :
                    "0x" + error.HResult.ToString("x8");
                if (detail.Length > 100) detail = detail.Substring(0, 100);
                string fault = where + " " + error.GetType().Name + " " + detail;
                // A failure that repeats every two seconds is one entry an hour.
                if (fault == lastFault && DateTime.UtcNow - lastFaultAt < TimeSpan.FromHours(1)) return;
                lastFault = fault; lastFaultAt = DateTime.UtcNow;
                CheckOpen();
                VerifyDirectory();
                string path = Path.Combine(directory, "faults.log");
                var lines = new System.Collections.Generic.List<string>();
                if (File.Exists(path)) { RejectLink(path); lines.AddRange(File.ReadAllLines(path, Encoding.UTF8)); }
                lines.Add(DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + " " + fault);
                if (lines.Count > 40) lines.RemoveRange(0, lines.Count - 40);
                WriteShared(path, new UTF8Encoding(false, true).GetBytes(String.Join("\n", lines) + "\n"), "faults");
            }
            catch { }
        }

        // The journal as written, for the report the administrator asks for.
        public string[] ReadFaults()
        {
            try
            {
                CheckOpen();
                string path = Path.Combine(directory, "faults.log");
                if (!File.Exists(path)) return new string[0];
                RejectLink(path);
                return File.ReadAllLines(path, Encoding.UTF8).Reverse().Take(40).Reverse().ToArray();
            }
            catch { return new string[0]; }
        }

        public void PublishStatus(ClientStatus status)
        {
            CheckOpen();
            VerifyDirectory();
            string path = Path.Combine(directory, "status.json");
            if (File.Exists(path)) RejectLink(path);
            WriteShared(path, new UTF8Encoding(false, true).GetBytes(new JavaScriptSerializer().Serialize(status)), "status");
        }

        // Written by the service alone, readable by the window of any user.
        private void WriteShared(string path, byte[] data, string kind)
        {
            string temporary = Path.Combine(directory, kind + "-" + Guid.NewGuid().ToString("N") + ".tmp");
            var security = FileSecurity();
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                FileSystemRights.Read, AccessControlType.Allow));
            try
            {
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileSystemRights.Write, FileShare.None,
                    4096, FileOptions.WriteThrough, security))
                {
                    stream.Write(data, 0, data.Length);
                    stream.Flush(true);
                }
                if (!MoveFileExW(temporary, path, 9)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Status publication failed");
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }

        private void CheckOpen()
        {
            if (!controllerLock.CanRead) throw new ObjectDisposedException("GuardStore");
        }

        private void VerifyDirectory()
        {
            RejectLink(directory);
            DirectorySecurity security = Directory.GetAccessControl(directory, AccessControlSections.Access | AccessControlSections.Owner);
            var owner = (SecurityIdentifier)security.GetOwner(typeof(SecurityIdentifier));
            if ((!owner.Equals(Administrators) && !owner.Equals(SystemAccount)) || !security.AreAccessRulesProtected)
                throw new InvalidOperationException("Protection store ownership is unsafe");
            var granted = new HashSet<string>();
            foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            {
                if ((!rule.IdentityReference.Equals(Administrators) && !rule.IdentityReference.Equals(SystemAccount)) ||
                    rule.AccessControlType != AccessControlType.Allow || rule.IsInherited ||
                    rule.FileSystemRights != FileSystemRights.FullControl ||
                    rule.InheritanceFlags != (InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit) ||
                    rule.PropagationFlags != PropagationFlags.None)
                    throw new InvalidOperationException("Protection store permissions are unsafe");
                granted.Add(rule.IdentityReference.Value);
            }
            if (granted.Count != 2) throw new InvalidOperationException("Protection store permissions are incomplete");
        }

        private static void RejectLink(string path)
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Protection store cannot use a filesystem link");
        }

        private static FileSecurity FileSecurity()
        {
            var security = new FileSecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(Administrators);
            foreach (SecurityIdentifier sid in new[] { Administrators, SystemAccount })
                security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
            return security;
        }

        private static void VerifyFile(string path)
        {
            RejectLink(path);
            var security = File.GetAccessControl(path, AccessControlSections.Access | AccessControlSections.Owner);
            var owner = (SecurityIdentifier)security.GetOwner(typeof(SecurityIdentifier));
            if ((!owner.Equals(Administrators) && !owner.Equals(SystemAccount)) || !security.AreAccessRulesProtected)
                throw new InvalidOperationException("Protection file ownership is unsafe");
            var granted = new HashSet<string>();
            foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            {
                if ((!rule.IdentityReference.Equals(Administrators) && !rule.IdentityReference.Equals(SystemAccount)) ||
                    rule.AccessControlType != AccessControlType.Allow || rule.IsInherited ||
                    rule.FileSystemRights != FileSystemRights.FullControl || rule.PropagationFlags != PropagationFlags.None)
                    throw new InvalidOperationException("Protection file permissions are unsafe");
                granted.Add(rule.IdentityReference.Value);
            }
            if (granted.Count != 2) throw new InvalidOperationException("Protection file permissions are incomplete");
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern bool MoveFileExW(string existing, string destination, uint flags);

        public void Dispose() { controllerLock.Dispose(); }
    }
}
