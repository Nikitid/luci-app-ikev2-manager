using System;
using System.IO;
using System.Linq;
using System.IO.Pipes;
using System.Threading;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace IkeV2Manager.Client
{
    internal sealed class ClientCommandServer : IDisposable
    {
        private readonly string name;
        private readonly GuardRuntime runtime;
        private readonly Thread listener;
        private NamedPipeServerStream pipe;
        private Thread job;
        private volatile bool stopped;
        private readonly object pipeGate = new object();
        private readonly object jobGate = new object();
        private readonly ManualResetEvent stop = new ManualResetEvent(false);
        private readonly AutoResetEvent wake = new AutoResetEvent(false);

        internal ClientCommandServer(string service, GuardRuntime controller)
        {
            name = ClientCommands.PipeName(service); runtime = controller;
            bool registered = runtime.HasRegistration();
            pipe = Create();
            listener = new Thread(Listen) { IsBackground = true };
            listener.Start();
            if (registered) StartRegistration();
        }

        private NamedPipeServerStream Create()
        {
            var security = new PipeSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.AnonymousSid, null), PipeAccessRights.FullControl, AccessControlType.Deny));
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
            foreach (var sid in new[] { WellKnownSidType.BuiltinAdministratorsSid, WellKnownSidType.BuiltinUsersSid })
                security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(sid, null), PipeAccessRights.ReadWrite | PipeAccessRights.Synchronize, AccessControlType.Allow));
            byte[] descriptor = security.GetSecurityDescriptorBinaryForm();
            var pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
            try
            {
                var attributes = new Attributes { Length = Marshal.SizeOf(typeof(Attributes)), Descriptor = pinned.AddrOfPinnedObject() };
                // First-instance ownership, overlapped I/O and remote-client rejection.
                var handle = CreateNamedPipeW(@"\\.\pipe\" + name, 0x40080003, 8, 1, 4096, 4096, 0, ref attributes);
                if (handle.IsInvalid) { handle.Dispose(); throw new InvalidOperationException("Client control unavailable"); }
                return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle);
            }
            finally { pinned.Free(); }
        }

        private void Listen()
        {
            while (!stopped)
            {
                bool connected = false;
                try
                {
                    pipe.WaitForConnection();
                    connected = true;
                    string response = Handle(ClientCommands.Read(pipe));
                    ClientCommands.Write(pipe, "{\"version\":1,\"state\":\"" + response + "\"}");
                    // DisconnectNamedPipe discards unread output. A bounded
                    // acknowledgement replaces an unbounded pipe-drain wait.
                    if (ClientCommands.Read(pipe) != "{}") throw new IOException("Invalid control acknowledgement");
                    pipe.Disconnect();
                }
                catch
                {
                    if (stopped) break;
                    try { lock (pipeGate) { if (stopped) break; if (!connected) throw new IOException(); pipe.Disconnect(); } }
                    catch { Environment.FailFast("Client control ownership lost"); }
                }
            }
        }

        private string Handle(string json)
        {
            try
            {
                var request = ClientCommands.Parse(json); ClientCommands.Validate(request);
                string operation = (string)request["operation"];
                if (operation == "begin")
                {
                    if (!ClientIsAdministrator()) return "administrator_required";
                    runtime.BeginEnrollment(new Uri((string)request["endpoint"]), (string)request["invitation"]);
                }
                else if (operation == "choose")
                {
                    // Any user of this computer may choose: the choices are the
                    // person's, and only what the offer leaves open is taken.
                    var on = ((object[])request["on"]).Cast<string>().ToArray();
                    var closed = ((object[])request["closed"]).Cast<string>().ToArray();
                    if (!runtime.Choose(on, closed)) return "invalid_request";
                    wake.Set(); StartRegistration(); return "accepted";
                }
                else
                {
                    if (operation == "connect" || operation == "disconnect")
                    {
                        runtime.RequestConnection(operation == "connect");
                        wake.Set(); StartRegistration(); return "accepted";
                    }
                    if (!StartRegistration()) return "busy";
                }
                return "accepted";
            }
            catch (ArgumentException) { return "invalid_request"; }
            catch (FormatException) { return "invalid_request"; }
            catch { return "operation_rejected"; }
        }

        private bool StartRegistration()
        {
            lock (jobGate)
            {
                if (stopped || (job != null && job.IsAlive)) return false;
                job = new Thread(() => {
                    while (!stopped)
                    {
                        if (!runtime.HasRegistration())
                        {
                            try { runtime.ContinueEnrollment(); } catch { }
                            break;
                        }
                        bool pending = true;
                        try
                        {
                            pending = runtime.HasPendingEnrollment();
                            if (pending) pending = !runtime.ContinueEnrollment();
                            else runtime.RefreshPolicy();
                        }
                        catch { }
                        // Asked in every registered state: a device that cannot
                        // get its policy is the one worth hearing from.
                        if (!pending) try { runtime.AnswerReportRequest(); } catch { }
                        // A choice on its way is looked after closely, as an
                        // unfinished registration is.
                        bool choosing = false;
                        try { choosing = runtime.ChoicePending(); } catch { }
                        if (WaitHandle.WaitAny(new WaitHandle[] {stop,wake}, pending || choosing ? 3000 : 30000) == 0) break;
                    }
                }) { IsBackground = true };
                job.Start();
                return true;
            }
        }

        public void Dispose()
        {
            lock (pipeGate) { stopped = true; stop.Set(); pipe.Dispose(); }
            if (!listener.Join(5000)) Environment.FailFast("Client control failed to stop");
            if (job != null && !job.Join(45000)) Environment.FailFast("Client registration failed to stop");
            stop.Dispose();
            wake.Dispose();
        }

        [StructLayout(LayoutKind.Sequential)] private struct Attributes { internal int Length; internal IntPtr Descriptor; internal bool Inherit; }
        // Whether the program at the other end of the pipe runs as an
        // administrator, read from its own token: an elevated one has the
        // Administrators group enabled, a filtered or restricted one does not.
        // Whatever cannot be read counts as no.
        private bool ClientIsAdministrator()
        {
            bool administrator = false;
            var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            var sid = new byte[administrators.BinaryLength];
            administrators.GetBinaryForm(sid, 0);
            try
            {
                pipe.RunAsClient(() =>
                {
                    SafeAccessTokenHandle token;
                    if (!OpenThreadToken(GetCurrentThread(), TokenQuery, true, out token)) return;
                    using (token)
                    {
                        bool member;
                        administrator = CheckTokenMembership(token, sid, out member) && member;
                    }
                });
            }
            catch (Exception) { return false; }
            return administrator;
        }

        private const uint TokenQuery = 0x0008;
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentThread();
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenThreadToken(IntPtr thread, uint access, bool openAsSelf, out SafeAccessTokenHandle token);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool CheckTokenMembership(SafeAccessTokenHandle token, byte[] sid, out bool member);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern SafePipeHandle CreateNamedPipeW(string name, uint openMode, uint pipeMode, uint instances,
            uint output, uint input, uint timeout, ref Attributes security);
    }
}
