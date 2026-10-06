using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace IkeV2Manager.Client
{
    public sealed class HostEntry
    {
        public string address { get; set; }
        public string domain { get; set; }
    }

    // Pure transformation; filesystem transactions and guard enforcement belong
    // to the privileged service, never to the UI or the policy document.
    public static class ManagedHosts
    {
        private const string Begin = "# BEGIN IKEv2 Manager managed hosts";
        private const string End = "# END IKEv2 Manager managed hosts";

        public static string Reconcile(string original, IList<HostEntry> entries)
        {
            if (original == null || entries == null || Encoding.UTF8.GetByteCount(original) > 1048576 ||
                original.Contains("\0") || original.Replace("\r\n", "\n").Contains("\r") || entries.Count > 4096)
                throw new ArgumentException("Invalid hosts document");
            var domains = new HashSet<string>(StringComparer.Ordinal);
            var addresses = new HashSet<string>(StringComparer.Ordinal);
            foreach (HostEntry entry in entries)
            {
                if (entry == null || entry.address == null || entry.domain == null)
                    throw new ArgumentException("Invalid hosts entry");
                string[] octets = entry.address.Split('.');
                if (octets.Length != 4 || !octets.All(IsOctet) || entry.domain.Length > 253 ||
                    !Regex.IsMatch(entry.domain, @"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z") ||
                    Regex.IsMatch(entry.domain, @"\A[0-9.]+\z") ||
                    !domains.Add(entry.domain) || !addresses.Add(entry.address))
                    throw new ArgumentException("Invalid hosts entry");
            }
            string newline = original.Contains("\r\n") ? "\r\n" : "\n";
            var kept = new List<string>();
            bool inBlock = false, seenBlock = false;
            foreach (string rawLine in original.Split('\n'))
            {
                string line = rawLine.EndsWith("\r", StringComparison.Ordinal) ? rawLine.Substring(0, rawLine.Length - 1) : rawLine;
                if (line == Begin)
                {
                    if (inBlock || seenBlock) throw new ArgumentException("Malformed managed block");
                    inBlock = seenBlock = true;
                }
                else if (line == End)
                {
                    if (!inBlock) throw new ArgumentException("Malformed managed block");
                    inBlock = false;
                }
                else if (!inBlock)
                {
                    string content = line.Split('#')[0];
                    string[] fields = content.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                    if (fields.Skip(1).Any(name => domains.Contains(name.ToLowerInvariant().Trim('.'))))
                        throw new ArgumentException("Existing hosts entry conflicts with policy");
                    kept.Add(rawLine);
                }
            }
            if (inBlock) throw new ArgumentException("Unterminated managed block");
            string result = String.Join("\n", kept);
            if (entries.Count == 0) return result;
            if (result.Length > 0 && !result.EndsWith("\n", StringComparison.Ordinal)) result += newline;
            result += Begin + newline;
            foreach (HostEntry entry in entries) result += entry.address + " " + entry.domain + newline;
            return result + End + newline;
        }

        private static bool IsOctet(string octet)
        {
            byte value;
            return Byte.TryParse(octet, out value) && value.ToString(System.Globalization.CultureInfo.InvariantCulture) == octet;
        }
    }
}
