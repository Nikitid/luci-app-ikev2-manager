using System;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace IkeV2Manager.Client
{
    public sealed class PolicyFetchException : Exception
    {
        public readonly string Code;
        internal PolicyFetchException(string code) : base(code) { Code = code; }
    }

    public static class PolicyTransportClient
    {
        private const int Limit = 1048576;

        // Call only with the endpoint, token and initial policy authenticated at
        // enrollment. This method does not enroll, commit or grant permission.
        public static ClientPolicy Fetch(Uri endpoint, string token, PolicyHistory committed)
        {
            ValidateEndpoint(endpoint, token);
            if (committed == null) throw new ArgumentNullException("committed");
            // This service owns its process. Require TLS 1.2; leave certificate
            // chain and hostname verification to Windows, with no override.
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = (HttpWebRequest)WebRequest.Create(endpoint);
            request.Method = "GET";
            request.AllowAutoRedirect = false;
            request.Proxy = null;
            request.UseDefaultCredentials = false;
            request.KeepAlive = false;
            request.Timeout = request.ReadWriteTimeout = 10000;
            request.MaximumResponseHeadersLength = 16;
            request.Accept = "application/json";
            request.Headers[HttpRequestHeader.Authorization] = "Bearer " + token;
            using (var deadline = new Timer(ignored => request.Abort(), null, 10000, Timeout.Infinite))
            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    if (response.StatusCode != HttpStatusCode.OK) throw new PolicyFetchException("policy_http_rejected");
                    using (var stream = response.GetResponseStream())
                    {
                        var next = Decode(stream, response.ContentType, response.ContentLength);
                        try { committed.Propose(next); }
                        catch (InvalidOperationException) { throw new PolicyFetchException("policy_update_rejected"); }
                        return next;
                    }
                }
            }
            catch (WebException error)
            {
                using (var response = error.Response as HttpWebResponse)
                {
                    if (response != null && response.StatusCode == HttpStatusCode.Unauthorized)
                        throw new PolicyFetchException("device_access_revoked");
                }
                throw new PolicyFetchException("policy_connection_failed");
            }
            catch (IOException) { throw new PolicyFetchException("policy_connection_failed"); }
        }

        internal static void ValidateEndpoint(Uri endpoint, string token)
        {
            if (endpoint == null || !endpoint.IsAbsoluteUri || endpoint.Scheme != "https" ||
                endpoint.HostNameType != UriHostNameType.Dns || endpoint.Host.Length > 253 || !endpoint.Host.Contains(".") ||
                endpoint.UserInfo.Length != 0 || endpoint.Query.Length != 0 || endpoint.Fragment.Length != 0 ||
                endpoint.AbsolutePath != "/client/v1/policy" || endpoint.OriginalString.Length > 2048 ||
                token == null || !Regex.IsMatch(token, @"\A[a-f0-9]{64}\z"))
                throw new ArgumentException("Invalid enrolled policy endpoint or device key");
        }

        internal static ClientPolicy Decode(Stream stream, string contentType, long contentLength)
        {
            if (stream == null || contentType == null ||
                !String.Equals(contentType.Split(';')[0].Trim(), "application/json", StringComparison.OrdinalIgnoreCase) ||
                contentLength > Limit || contentLength == 0)
                throw new PolicyFetchException("policy_response_invalid");
            using (var data = new MemoryStream())
            {
                var buffer = new byte[4096];
                int read;
                while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (data.Length + read > Limit) throw new PolicyFetchException("policy_response_too_large");
                    data.Write(buffer, 0, read);
                }
                if (data.Length == 0 || (contentLength >= 0 && data.Length != contentLength))
                    throw new PolicyFetchException("policy_response_invalid");
                try { return ClientPolicy.Parse(new UTF8Encoding(false, true).GetString(data.ToArray())); }
                catch (ArgumentException) { throw new PolicyFetchException("policy_response_invalid"); }
                catch (InvalidOperationException) { throw new PolicyFetchException("policy_response_invalid"); }
            }
        }
    }
}
