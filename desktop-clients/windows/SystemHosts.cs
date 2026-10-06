using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.InteropServices;

namespace IkeV2Manager.Client
{
    public static class SystemHosts
    {
        private static readonly SecurityIdentifier Administrators = new SecurityIdentifier("S-1-5-32-544");
        private static readonly SecurityIdentifier SystemAccount = new SecurityIdentifier("S-1-5-18");
        private static readonly Encoding Bytes = Encoding.GetEncoding(28591);
        private static bool initialized;
        private static string PathName { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"drivers\etc\hosts"); } }

        public static void Apply(GuardStore store, PolicyHistory policy)
        {
            if (store == null || policy == null) throw new ArgumentNullException();
            var plan = store.LoadPlan();
            if (plan == null || policy.ProtectedAddresses().Any(a => !plan.Addresses.Contains(a)))
                throw new InvalidOperationException("Host mappings require persistent guard coverage");
            using (var guard = WfpGuard.Recover(plan)) guard.VerifyProtection();
            Replace(store, text => policy.ReconcileHosts(text));
        }

        // Explicit privileged removal only; ordinary disconnect retains mappings.
        public static void Remove(GuardStore store)
        { Replace(store, text => ManagedHosts.Reconcile(text, new HostEntry[0])); }

        private static void Verify(string path)
        {
            if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                throw new InvalidOperationException("Redirected hosts path refused");
            var permissions = File.GetAccessControl(path, AccessControlSections.Owner | AccessControlSections.Access);
            var installer = (SecurityIdentifier)new NTAccount("NT SERVICE", "TrustedInstaller").Translate(typeof(SecurityIdentifier));
            var owner = (SecurityIdentifier)permissions.GetOwner(typeof(SecurityIdentifier));
            if (!owner.Equals(Administrators) && !owner.Equals(SystemAccount) && !owner.Equals(installer))
                throw new InvalidOperationException("Untrusted hosts owner");
            const FileSystemRights writes = FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
            foreach (FileSystemAccessRule rule in permissions.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                if (rule.AccessControlType == AccessControlType.Allow && (rule.FileSystemRights & writes) != 0 &&
                    !rule.IdentityReference.Equals(Administrators) && !rule.IdentityReference.Equals(SystemAccount) && !rule.IdentityReference.Equals(installer))
                    throw new InvalidOperationException("Untrusted hosts writer");
        }

        private static byte[] Read(string path)
        {
            Verify(path);
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (file.Length > 1048576) throw new InvalidOperationException("Hosts file exceeds limit");
                var data = new byte[(int)file.Length]; int offset = 0;
                while (offset < data.Length) { int read = file.Read(data, offset, data.Length-offset); if (read == 0) throw new IOException(); offset += read; }
                return data;
            }
        }

        private static void Replace(GuardStore store, Func<string,string> transform)
        {
            string path = PathName;
            for (string parent = Path.GetDirectoryName(path); parent != null; parent = Path.GetDirectoryName(parent))
                if ((File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("Redirected hosts ancestor refused");
            byte[] original = Read(path), output = Bytes.GetBytes(transform(Bytes.GetString(original)));
            if (original.SequenceEqual(output)) { if (!initialized) Flush(); initialized = true; return; }
            string temporary = Path.Combine(Path.GetDirectoryName(path), "hosts-ikev2-" + Guid.NewGuid().ToString("N") + ".tmp");
            string backup = Path.Combine(store.DirectoryPath, "hosts-backup-" + Guid.NewGuid().ToString("N"));
            var security = new FileSecurity(); security.SetAccessRuleProtection(true,false); security.SetOwner(Administrators);
            foreach (var sid in new[] {Administrators,SystemAccount}) security.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,AccessControlType.Allow));
            try
            {
                using (var file = new FileStream(temporary,FileMode.CreateNew,FileSystemRights.Write,FileShare.None,4096,FileOptions.WriteThrough,security))
                { file.Write(output,0,output.Length); file.Flush(true); }
                if (!Read(path).SequenceEqual(original)) throw new InvalidOperationException("Concurrent hosts edit; retry required");
                // Native replacement preserves original DACL and keeps a private
                // recovery copy. No partial hosts document becomes visible.
                File.Replace(temporary,path,backup,false);
                if (!Read(backup).SequenceEqual(original)) throw new InvalidOperationException("Concurrent hosts edit; private backup retained for recovery");
                if (!Read(path).SequenceEqual(output)) throw new InvalidOperationException("Hosts mapping verification failed; private backup retained");
                Flush();
                initialized = true;
                File.Delete(backup);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }

        private static void Flush()
        {
            if (!DnsFlushResolverCache()) throw new InvalidOperationException("System DNS cache could not be refreshed");
        }
        [DllImport("dnsapi.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DnsFlushResolverCache();
    }
}
