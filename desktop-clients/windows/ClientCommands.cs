using System;
using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Diagnostics;

namespace IkeV2Manager.Client
{
    public static class ClientCommands
    {
        internal static void ParseInvitation(string text, out string endpoint, out string invitation)
        {
            if (text == null || text.Length > 2200) throw new ArgumentException("Invalid invitation");
            var link = new Uri(text.Trim());
            invitation = link.Fragment.Length > 0 ? link.Fragment.Substring(1) : "";
            endpoint = new UriBuilder(link) { Fragment = "" }.Uri.AbsoluteUri;
            Validate(new Dictionary<string, object> { { "version", 1 }, { "operation", "begin" },
                { "endpoint", endpoint }, { "invitation", invitation } });
        }

        internal static string PipeName(string service)
        {
            if (service != "IKEv2ManagerClient" && !Regex.IsMatch(service ?? "", @"\AIKEv2Manager-Test-[a-f0-9]{32}\z"))
                throw new ArgumentException("Invalid client installation");
            return service + "-control";
        }

        public static string Send(string operation, string endpoint = null, string invitation = null,
            string service = "IKEv2ManagerClient")
        {
            var request = new Dictionary<string, object> { { "version", 1 }, { "operation", operation } };
            if (operation == "begin") { request.Add("endpoint", endpoint); request.Add("invitation", invitation); }
            Validate(request);
            uint expected = ServicePid(service);
            using (var pipe = new NamedPipeClientStream(".", PipeName(service),
                PipeAccessRights.ReadWrite | PipeAccessRights.Synchronize, PipeOptions.Asynchronous,
                TokenImpersonationLevel.Identification, HandleInheritability.None))
            {
                pipe.Connect(3000);
                uint actual;
                if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out actual) || actual != expected ||
                    ServicePid(service) != expected) throw new InvalidOperationException("Client service identity mismatch");
                Write(pipe, new JavaScriptSerializer().Serialize(request));
                var response = Parse(Read(pipe));
                if (response.Count != 2 || !response.ContainsKey("version") || !response.ContainsKey("state") ||
                    !(response["version"] is int) || (int)response["version"] != 1 || !(response["state"] is string))
                    throw new InvalidOperationException("Invalid service response");
                string state = (string)response["state"];
                if (state != "accepted" && state != "busy" && state != "administrator_required" &&
                    state != "invalid_request" && state != "operation_rejected") throw new InvalidOperationException("Invalid service response");
                Write(pipe, "{}");
                return state;
            }
        }

        internal static Dictionary<string, object> Parse(string json)
        {
            var result = new JavaScriptSerializer { MaxJsonLength = 4096, RecursionLimit = 4 }.DeserializeObject(json)
                as Dictionary<string, object>;
            if (result == null) throw new ArgumentException("Invalid control message");
            return result;
        }

        internal static void Validate(Dictionary<string, object> request)
        {
            if (!request.ContainsKey("version") || !(request["version"] is int) || (int)request["version"] != 1 ||
                !request.ContainsKey("operation") || !(request["operation"] is string)) throw new ArgumentException("Invalid control request");
            string operation = (string)request["operation"];
            if (operation == "continue" || operation == "connect" || operation == "disconnect") { if (request.Count != 2) throw new ArgumentException("Invalid control request"); return; }
            if (operation != "begin" || request.Count != 4 || !request.ContainsKey("endpoint") || !request.ContainsKey("invitation") ||
                !(request["endpoint"] is string) || !(request["invitation"] is string)) throw new ArgumentException("Invalid control request");
            EnrollmentTransportClient.ValidateEndpoint(new Uri((string)request["endpoint"]), (string)request["invitation"], true);
        }

        internal static string Read(PipeStream pipe)
        {
            byte[] header = ReadBytes(pipe, 4);
            int length = header[0] | header[1] << 8 | header[2] << 16 | header[3] << 24;
            if (length < 1 || length > 4096) throw new ArgumentException("Invalid control frame");
            return new UTF8Encoding(false, true).GetString(ReadBytes(pipe, length));
        }

        private static byte[] ReadBytes(PipeStream pipe, int count)
        {
            var bytes = new byte[count]; int offset = 0;
            var elapsed = Stopwatch.StartNew();
            while (offset < count)
            {
                var read = pipe.BeginRead(bytes, offset, count - offset, null, null);
                int received;
                using (read.AsyncWaitHandle)
                {
                    if (!read.AsyncWaitHandle.WaitOne(Math.Max(0, 3000 - (int)elapsed.ElapsedMilliseconds)))
                    {
                        CancelIoEx(pipe.SafePipeHandle.DangerousGetHandle(), IntPtr.Zero);
                        try { pipe.EndRead(read); } catch (IOException) { }
                        throw new IOException("Control request timed out");
                    }
                    received = pipe.EndRead(read);
                }
                if (received == 0) throw new IOException("Control connection closed");
                offset += received;
            }
            return bytes;
        }

        internal static void Write(PipeStream pipe, string json)
        {
            byte[] bytes = new UTF8Encoding(false, true).GetBytes(json);
            if (bytes.Length < 1 || bytes.Length > 4096) throw new ArgumentException("Invalid control frame");
            var data = new byte[bytes.Length + 4];
            for (int i = 0; i < 4; i++) data[i] = (byte)(bytes.Length >> (8 * i));
            Array.Copy(bytes, 0, data, 4, bytes.Length);
            var write = pipe.BeginWrite(data, 0, data.Length, null, null);
            using (write.AsyncWaitHandle)
            {
                if (!write.AsyncWaitHandle.WaitOne(3000))
                {
                    CancelIoEx(pipe.SafePipeHandle.DangerousGetHandle(), IntPtr.Zero);
                    try { pipe.EndWrite(write); } catch (IOException) { }
                    throw new IOException("Control response timed out");
                }
                pipe.EndWrite(write);
            }
        }

        private static uint ServicePid(string service)
        {
            PipeName(service);
            IntPtr manager = OpenSCManagerW(null, null, 1), handle = IntPtr.Zero;
            try
            {
                if (manager == IntPtr.Zero) throw new InvalidOperationException("Client service unavailable");
                handle = OpenServiceW(manager, service, 4);
                Status status; uint required;
                if (handle == IntPtr.Zero || !QueryServiceStatusEx(handle, 0, out status, (uint)Marshal.SizeOf(typeof(Status)), out required) ||
                    status.State != 4 || status.Process == 0) throw new InvalidOperationException("Client service unavailable");
                return status.Process;
            }
            finally { if (handle != IntPtr.Zero) CloseServiceHandle(handle); if (manager != IntPtr.Zero) CloseServiceHandle(manager); }
        }

        [StructLayout(LayoutKind.Sequential)] private struct Status
        { internal uint Type, State, Accepted, Win32ExitCode, ServiceExitCode, CheckPoint, WaitHint, Process, Flags; }
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CancelIoEx(IntPtr handle, IntPtr overlapped);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
        [DllImport("advapi32.dll")] private static extern bool QueryServiceStatusEx(IntPtr service, uint level, out Status status, uint bytes, out uint required);
        [DllImport("advapi32.dll")] private static extern bool CloseServiceHandle(IntPtr handle);
    }
}
