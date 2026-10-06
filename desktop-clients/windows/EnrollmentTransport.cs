using System;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Threading;

namespace IkeV2Manager.Client
{
    public sealed class EnrollmentException : Exception
    {
        public readonly string Code;
        internal EnrollmentException(string code) : base(code) { Code = code; }
    }

    public sealed class EnrollmentResult
    {
        public readonly string Id;
        public readonly ClientPolicy Policy;
        public readonly string Password;
        public bool Pending { get { return Policy == null; } }
        internal EnrollmentResult(string id, ClientPolicy policy, string password)
        { Id = id; Policy = policy; Password = password; }
        // Reports and UI must never stringify credentials.
        public override string ToString() { return Pending ? "pending" : "enrolled"; }
    }

    public static class EnrollmentTransportClient
    {
        private const int Limit = 1048576;

        // The caller must persist its independent device token in protected
        // storage before Claim. These operations neither activate nor admit it.
        public static EnrollmentResult Claim(Uri endpoint, string invitation, string deviceToken)
        {
            ValidateEndpoint(endpoint, invitation, true);
            ValidateToken(deviceToken);
            if (invitation == deviceToken) throw new ArgumentException("Enrollment keys must be independent");
            return Request(endpoint, invitation, deviceToken);
        }

        public static EnrollmentResult Poll(Uri endpoint, string deviceToken)
        {
            ValidateEndpoint(endpoint, deviceToken, false);
            return Request(endpoint, deviceToken, null);
        }

        internal static void ValidateEndpoint(Uri endpoint, string key, bool claim)
        {
            ValidateToken(key);
            if (endpoint == null || !endpoint.IsAbsoluteUri || endpoint.Scheme != "https" ||
                endpoint.HostNameType != UriHostNameType.Dns || endpoint.Host.Length > 253 || !endpoint.Host.Contains(".") ||
                endpoint.UserInfo.Length != 0 || endpoint.Query.Length != 0 || endpoint.Fragment.Length != 0 ||
                endpoint.AbsolutePath != (claim ? "/client/v1/enroll" : "/client/v1/enrollment") ||
                endpoint.OriginalString.Length > 2048)
                throw new ArgumentException("Invalid enrollment endpoint");
        }

        private static void ValidateToken(string key)
        {
            if (key == null || !Regex.IsMatch(key, @"\A[a-f0-9]{64}\z"))
                throw new ArgumentException("Invalid enrollment key");
        }

        private static EnrollmentResult Request(Uri endpoint, string key, string deviceToken)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            var request = (HttpWebRequest)WebRequest.Create(endpoint);
            request.Method = deviceToken == null ? "GET" : "POST";
            if (deviceToken != null) { request.ContentLength = 0; request.Headers["X-Device-Token"] = deviceToken; }
            request.AllowAutoRedirect = false;
            request.Proxy = null;
            request.UseDefaultCredentials = false;
            request.KeepAlive = false;
            request.Timeout = request.ReadWriteTimeout = 10000;
            request.MaximumResponseHeadersLength = 16;
            request.Accept = "application/json";
            request.Headers[HttpRequestHeader.Authorization] = "Bearer " + key;
            using (var deadline = new Timer(ignored => request.Abort(), null, 10000, Timeout.Infinite))
            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                using (var stream = response.GetResponseStream())
                {
                    if (deviceToken != null && response.StatusCode != HttpStatusCode.Accepted)
                        throw new EnrollmentException("enrollment_http_rejected");
                    return Decode(stream, response.ContentType, response.ContentLength, (int)response.StatusCode);
                }
            }
            catch (WebException error)
            {
                using (var response = error.Response as HttpWebResponse)
                {
                    if (response != null && response.StatusCode == HttpStatusCode.Unauthorized)
                        throw new EnrollmentException("enrollment_access_rejected");
                }
                throw new EnrollmentException("enrollment_connection_failed");
            }
            catch (IOException) { throw new EnrollmentException("enrollment_connection_failed"); }
        }

        internal static EnrollmentResult Decode(Stream stream, string contentType, long contentLength, int status)
        {
            if ((status != 200 && status != 202) || stream == null || contentType == null ||
                !String.Equals(contentType.Split(';')[0].Trim(), "application/json", StringComparison.OrdinalIgnoreCase) ||
                contentLength == 0 || contentLength > Limit)
                throw new EnrollmentException("enrollment_response_invalid");
            using (var data = new MemoryStream())
            {
                var buffer = new byte[4096];
                int read;
                while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (data.Length + read > Limit) throw new EnrollmentException("enrollment_response_too_large");
                    data.Write(buffer, 0, read);
                }
                if (data.Length == 0 || (contentLength >= 0 && data.Length != contentLength))
                    throw new EnrollmentException("enrollment_response_invalid");
                try
                {
                    var serializer = new JavaScriptSerializer { MaxJsonLength = Limit, RecursionLimit = 16 };
                    var root = ClientPolicy.Object(serializer.DeserializeObject(new UTF8Encoding(false, true).GetString(data.ToArray())));
                    ClientPolicy.Integer(root["version"], 1, 1);
                    if (status == 202)
                    {
                        ClientPolicy.Fields(root, "version", "state", "id");
                        var id = ClientPolicy.Text(root["id"]);
                        if (ClientPolicy.Text(root["state"]) != "pending" || !Regex.IsMatch(id, @"\A[a-z][a-z0-9-]{0,47}\z"))
                            throw new ArgumentException();
                        return new EnrollmentResult(id, null, null);
                    }
                    ClientPolicy.Fields(root, "version", "state", "policy", "credentials");
                    if (ClientPolicy.Text(root["state"]) != "enrolled") throw new ArgumentException();
                    var policy = ClientPolicy.Parse(serializer.Serialize(root["policy"]));
                    var credentials = ClientPolicy.Object(root["credentials"]);
                    ClientPolicy.Fields(credentials, "username", "password");
                    var username = ClientPolicy.Text(credentials["username"]);
                    var password = ClientPolicy.Text(credentials["password"]);
                    ValidateToken(password);
                    if (username != policy.Id) throw new ArgumentException();
                    return new EnrollmentResult(username, policy, password);
                }
                catch (ArgumentException) { throw new EnrollmentException("enrollment_response_invalid"); }
                catch (InvalidOperationException) { throw new EnrollmentException("enrollment_response_invalid"); }
                catch (System.Collections.Generic.KeyNotFoundException) { throw new EnrollmentException("enrollment_response_invalid"); }
            }
        }
    }
}
