using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace IkeV2Manager.Client
{
    // What a reset or a removal took away, and what it could not.
    public sealed class RemovalResult
    {
        public int Filters { get; internal set; }
        public int Connections { get; internal set; }
        public int NameRules { get; internal set; }
        public int Hosts { get; internal set; }
        public bool Registration { get; internal set; }
        public int BrowserPolicies { get; internal set; }
        public bool Folder { get; internal set; }
        public List<string> Failed { get; private set; }
        // Why each step failed: where, the kind of failure and the program's
        // own words for it, no path or address.
        public List<string> Reasons { get; private set; }
        public bool Complete { get { return Failed.Count == 0; } }
        // Nothing the program set up was on this computer any more; its empty
        // folder, which a service makes again at every start, does not count.
        public bool Nothing { get { return Filters == 0 && Connections == 0 && NameRules == 0 && Hosts == 0 && !Registration && BrowserPolicies == 0; } }
        public RemovalResult() { Failed = new List<string>(); Reasons = new List<string>(); }

        internal void Fail(string step) { if (!Failed.Contains(step)) Failed.Add(step); }

        internal void Fail(string step, Exception error)
        {
            Fail(step);
            var native = error as System.ComponentModel.Win32Exception;
            string detail = native != null ? "code " + native.NativeErrorCode : error.Message;
            if (Reasons.Count < 16) Reasons.Add(step + " " + error.GetType().Name + " " + FailureQueue.Plain(detail, 100));
        }

        public string Json(DateTime at)
        {
            return new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                { "version", 1 }, { "at", FailureQueue.Stamp(at) }, { "complete", Complete },
                { "filters", Filters }, { "connections", Connections }, { "name_rules", NameRules }, { "hosts", Hosts },
                { "registration", Registration }, { "browser_policies", BrowserPolicies }, { "failed", Failed.ToArray() }, { "reasons", Reasons.ToArray() } });
        }

        public static RemovalResult Parse(string json)
        {
            try
            {
                var data = new JavaScriptSerializer().DeserializeObject(json ?? "") as Dictionary<string, object>;
                if (data == null || !(data["version"] is int) || (int)data["version"] != 1) return null;
                var result = new RemovalResult {
                    Filters = (int)data["filters"], Connections = (int)data["connections"], NameRules = (int)data["name_rules"],
                    Hosts = (int)data["hosts"], Registration = (bool)data["registration"], BrowserPolicies = (int)data["browser_policies"] };
                foreach (object step in (object[])data["failed"]) result.Fail((string)step);
                return result;
            }
            catch (Exception) { return null; }
        }
    }
}
