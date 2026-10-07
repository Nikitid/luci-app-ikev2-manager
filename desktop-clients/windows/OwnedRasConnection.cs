using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;

namespace IkeV2Manager.Client
{
    public sealed class NativeConnectionException : InvalidOperationException
    {
        public readonly uint Code;
        internal NativeConnectionException(uint code) : base("Native IKEv2 connection failed") { Code = code; }
    }
    // Asynchronous native RAS ownership. This class never grants traffic access.
    public sealed class OwnedRasConnection : IDisposable
    {
        private sealed class Progress
        {
            internal volatile bool Done;
            internal uint Error, State;
        }
        private static readonly ConcurrentDictionary<ulong, Progress> Calls = new ConcurrentDictionary<ulong, Progress>();
        private static readonly Native.Callback Notify = OnProgress;
        private static long sequence;
        private readonly ulong key;
        private readonly Progress progress;
        private readonly Stopwatch elapsed = Stopwatch.StartNew();
        private readonly ManagedVpnProfile profile;
        private IntPtr handle;
        private bool disposed;
        private Guid correlation;
        public uint ErrorCode { get; private set; }

        private OwnedRasConnection(ManagedVpnProfile entry, ulong id, Progress state)
        { profile = entry; key = id; progress = state; }

        public static OwnedRasConnection Begin(ManagedVpnProfile profile, string username, string password)
        {
            if (profile == null || !Regex.IsMatch(username ?? "", @"\A[a-z][a-z0-9-]{0,47}\z") ||
                !Regex.IsMatch(password ?? "", @"\A[a-f0-9]{64}\z")) throw new ArgumentException("Enrolled profile credentials required");
            if (RasTunnel.Exists(profile.EntryId, profile.Phonebook))
                throw new InvalidOperationException("Managed profile already has an unowned connection");
            ulong id = checked((ulong)Interlocked.Increment(ref sequence));
            var state = new Progress();
            if (!Calls.TryAdd(id, state)) throw new InvalidOperationException("RAS operation identity unavailable");
            var result = new OwnedRasConnection(profile, id, state);
            var parameters = new Native.Parameters { Size = (uint)Marshal.SizeOf(typeof(Native.Parameters)),
                Entry = profile.Name, Username = username, Password = password, CallbackId = new UIntPtr(id) };
            var extensions = new Native.Extensions { Size = (uint)Marshal.SizeOf(typeof(Native.Extensions)), Options = 0x1c0 };
            int length = Marshal.SizeOf(typeof(Native.Parameters));
            IntPtr memory = Marshal.AllocHGlobal(length);
            try
            {
                Marshal.StructureToPtr(parameters, memory, false);
                uint error = Native.RasDialW(ref extensions, profile.Phonebook, memory, 2, Notify, ref result.handle);
                if (error != 0) { result.ErrorCode = error; result.Dispose(); throw new NativeConnectionException(error); }
                if (result.handle == IntPtr.Zero) { result.Dispose(); throw new InvalidOperationException("Native connection handle missing"); }
                return result;
            }
            catch { result.Dispose(); throw; }
            finally
            {
                Marshal.Copy(new byte[length], 0, memory, length);
                Marshal.FreeHGlobal(memory);
                parameters.Password = null;
            }
        }

        private static uint OnProgress(UIntPtr context, uint subentry, IntPtr connection, uint message, uint state, uint error, uint extended)
        {
            try
            {
                Progress progress;
                if (!Calls.TryGetValue(context.ToUInt64(), out progress)) return 0;
                if (error != 0 || state >= 0x1000)
                {
                    progress.Error = error != 0 ? error : state == 0x2000 ? 0u : 703u;
                    progress.State = state;
                    progress.Done = true;
                }
                return 1;
            }
            catch { return 0; } // Never cross the native callback boundary.
        }

        public TunnelObservation Observe()
        {
            if (disposed) throw new ObjectDisposedException("OwnedRasConnection");
            if (!progress.Done)
            {
                if (elapsed.ElapsedMilliseconds < 30000) return null;
                ErrorCode = 1460; Dispose(); throw new NativeConnectionException(1460);
            }
            if (progress.Error != 0 || progress.State != 0x2000)
            {
                ErrorCode = progress.Error; Dispose(); throw new NativeConnectionException(ErrorCode);
            }
            var observation = RasTunnel.Observe(profile.EntryId, profile.Phonebook);
            if (observation == null) { Dispose(); throw new InvalidOperationException("Native IKEv2 connection lost"); }
            if (correlation == Guid.Empty) correlation = observation.Connection;
            if (correlation != observation.Connection) { Dispose(); throw new InvalidOperationException("Native connection ownership changed"); }
            return observation;
        }

        public void Dispose()
        {
            if (disposed && handle == IntPtr.Zero) return;
            disposed = true;
            Progress ignored; Calls.TryRemove(key, out ignored);
            if (handle == IntPtr.Zero) return;
            IntPtr owned = handle;
            Native.RasHangUpW(owned);
            // RAS cleanup is asynchronous, and after a sleep or a restart of
            // the system's own service the handle may answer with any error.
            // What decides is whether the managed entry is still connected;
            // whatever is left on it is ended by what the system lists.
            var deadline = Stopwatch.StartNew();
            do
            {
                var status = new Native.Status { Size = (uint)Marshal.SizeOf(typeof(Native.Status)) };
                if (Native.RasGetConnectStatusW(owned, ref status) != 0 && !RasTunnel.Exists(profile.EntryId, profile.Phonebook))
                { handle = IntPtr.Zero; return; }
                Thread.Sleep(25);
            } while (deadline.ElapsedMilliseconds < 5000);
            RasTunnel.Release(profile.EntryId, profile.Phonebook);
            handle = IntPtr.Zero;
        }

        private static class Native
        {
            [UnmanagedFunctionPointer(CallingConvention.Winapi)]
            internal delegate uint Callback(UIntPtr context, uint subentry, IntPtr connection, uint message, uint state, uint error, uint extended);
            [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
            internal struct Parameters
            {
                internal uint Size;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] internal string Entry;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] internal string Phone, CallbackNumber;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] internal string Username, Password;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)] internal string Domain;
                internal uint Subentry; internal UIntPtr CallbackId; internal uint InterfaceIndex; internal IntPtr EncryptedPassword;
            }
            [StructLayout(LayoutKind.Sequential, Pack = 4)] internal struct Info { internal uint Size; internal IntPtr Data; }
            [StructLayout(LayoutKind.Sequential, Pack = 4)] internal struct Extensions
            {
                internal uint Size, Options; internal IntPtr Parent; internal UIntPtr Reserved, Reserved1;
                internal Info Eap; internal int SkipAuthentication; internal Info Device;
            }
            [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)] internal struct Status
            {
                internal uint Size, State, Error;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] internal string DeviceType;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] internal string DeviceName, Phone;
                internal Endpoint Local, Remote; internal uint Substate;
            }
            [StructLayout(LayoutKind.Sequential, Pack = 4)] internal struct Endpoint { internal uint Type, A, B, C, D; }
            [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
            internal static extern uint RasDialW(ref Extensions extensions, string phonebook, IntPtr parameters, uint notifier, Callback callback, ref IntPtr connection);
            [DllImport("rasapi32.dll", ExactSpelling = true)] internal static extern uint RasHangUpW(IntPtr connection);
            [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
            internal static extern uint RasGetConnectStatusW(IntPtr connection, ref Status status);
        }
    }
}
