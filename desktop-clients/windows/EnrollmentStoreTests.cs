using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using IkeV2Manager.Client;

internal static class EnrollmentStoreTests
{
    private static int Main(string[] args)
    {
        string name = "IKEv2Manager-Test-" + Guid.NewGuid().ToString("N");
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name);
        try
        {
            var principal = new WindowsPrincipal(WindowsIdentity.GetCurrent());
            if (!principal.IsInRole(WindowsBuiltInRole.Administrator)) throw new Exception("Enrollment storage tests require elevation");
            const string invite = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
            const string password = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
            var endpoint = new Uri("https://vpn.example.com/client/v1/enroll");
            var serializer = new JavaScriptSerializer();
            var fixtures = (object[])serializer.DeserializeObject(File.ReadAllText(args[0]));
            var policy = ClientPolicy.Parse(serializer.Serialize(((Dictionary<string, object>)fixtures[0])["policy"]));
            string token, path = Path.Combine(directory, "enrollment.json");
            using (var store = new GuardStore(name))
            {
                if (EnrollmentRegistration.Load(store) != null) throw new Exception("Fresh store already registered");
                var initial = EnrollmentRegistration.Begin(store, endpoint, invite);
                token = initial.DeviceToken;
                if (token.Length != 64 || token == invite || EnrollmentRegistration.Begin(store, endpoint, invite).DeviceToken != token)
                    throw new Exception("Retry changed the independent device key");
                string cipher = File.ReadAllText(path);
                string decodedCipher = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(cipher));
                if (cipher.Contains(invite) || cipher.Contains(token) || cipher.Contains("device_token") ||
                    decodedCipher.Contains(invite) || decodedCipher.Contains(token))
                    throw new Exception("Registration was stored in plaintext");
                Reject(() => EnrollmentRegistration.Begin(store, new Uri("https://other.example.com/client/v1/enroll"), invite));
                Reject(() => EnrollmentRegistration.Begin(store, endpoint, password));
                EnrollmentRegistration.Accept(store, new EnrollmentResult(policy.Id, null, null));
                string before = File.ReadAllText(path);
                Reject(() => EnrollmentRegistration.Accept(store, new EnrollmentResult("other", null, null)));
                Reject(() => EnrollmentRegistration.Accept(store, new EnrollmentResult(policy.Id, policy, "invalid")));
                if (File.ReadAllText(path) != before) throw new Exception("Rejected response modified durable registration");
            }
            using (var restarted = new GuardStore(name))
            {
                var pending = EnrollmentRegistration.Load(restarted);
                if (pending.DeviceToken != token || pending.Id != policy.Id || pending.Policy != null)
                    throw new Exception("Restart lost pending registration");
                EnrollmentRegistration.Accept(restarted, new EnrollmentResult(policy.Id, policy, password));
                var complete = EnrollmentRegistration.Resume(restarted);
                if (complete.DeviceToken != token || complete.Password != password || complete.Policy.Canonical != policy.Canonical)
                    throw new Exception("Completed registration not recovered");
                if (restarted.LoadEnrollmentDocument().Contains(invite) || complete.ToString().Contains(password))
                    throw new Exception("Completed registration retained invitation or exposed password");
                Reject(() => EnrollmentRegistration.Accept(restarted, new EnrollmentResult(policy.Id, null, null)));
                Reject(() => EnrollmentRegistration.Accept(restarted, new EnrollmentResult(policy.Id, policy, invite)));
                restarted.PublishStatus(new ClientStatus { State = "registration_complete" });
                RestrictedAccessTests.Run(directory, "enrollment.json", "enrollment-initialized");
                var security = File.GetAccessControl(path);
                var unsafeSecurity = File.GetAccessControl(path);
                unsafeSecurity.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                    FileSystemRights.Read, AccessControlType.Allow));
                File.SetAccessControl(path, unsafeSecurity);
                try { Reject(() => EnrollmentRegistration.Load(restarted)); }
                finally { RestoreSecurity(path, security); }
                string cipher = File.ReadAllText(path);
                File.WriteAllText(path, "corrupted");
                try { Reject(() => EnrollmentRegistration.Load(restarted)); }
                finally { File.WriteAllText(path, cipher); }
                File.Delete(path);
                try
                {
                    Reject(() => EnrollmentRegistration.Load(restarted));
                    Reject(() => EnrollmentRegistration.Begin(restarted, endpoint, invite));
                }
                finally { File.WriteAllText(path, cipher); RestoreSecurity(path, security); }
            }
            // Recover first-publication interruption, with and without marker.
            File.Move(path, Path.Combine(directory, "enrollment.pending"));
            using (var recovery = new GuardStore(name))
                if (EnrollmentRegistration.Load(recovery).DeviceToken != token) throw new Exception("Staged key was rotated");
            File.Move(path, Path.Combine(directory, "enrollment.pending"));
            File.Delete(Path.Combine(directory, "enrollment-initialized"));
            using (var recovery = new GuardStore(name))
                if (EnrollmentRegistration.Load(recovery).DeviceToken != token) throw new Exception("Pre-marker staged key was rotated");
            Console.WriteLine("Enrollment storage checks passed: DPAPI, ACLs, restart, identity, recovery and lost-history refusal");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    private static void Reject(Action action)
    {
        try { action(); }
        catch (ArgumentException) { return; }
        catch (InvalidOperationException) { return; }
        throw new Exception("Unsafe enrollment state accepted");
    }

    private static void RestoreSecurity(string path, FileSecurity original)
    {
        var restored = new FileSecurity();
        restored.SetSecurityDescriptorBinaryForm(original.GetSecurityDescriptorBinaryForm(),
            AccessControlSections.Access | AccessControlSections.Owner);
        File.SetAccessControl(path, restored);
    }
}
