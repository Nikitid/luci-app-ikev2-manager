using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace IkeV2Manager.Client
{
    // Service-owned durable registration. It never grants traffic permission.
    public sealed class EnrollmentRegistration
    {
        public readonly Uri ClaimEndpoint;
        public readonly string DeviceToken, Id;
        public readonly ClientPolicy Policy;
        public readonly string Password;
        private readonly string invitation;

        private EnrollmentRegistration(Uri endpoint, string invite, string token, string id, ClientPolicy policy, string password)
        { ClaimEndpoint = endpoint; invitation = invite; DeviceToken = token; Id = id; Policy = policy; Password = password; }

        public static EnrollmentRegistration Begin(GuardStore store, Uri endpoint, string invite)
        {
            if (store == null) throw new ArgumentNullException("store");
            EnrollmentTransportClient.ValidateEndpoint(endpoint, invite, true);
            var existing = Load(store);
            if (existing != null)
            {
                if (existing.ClaimEndpoint != endpoint || existing.invitation != invite)
                    throw new InvalidOperationException("A different registration already exists");
                return existing;
            }
            var bytes = new byte[32];
            string token;
            using (var random = new RNGCryptoServiceProvider()) random.GetBytes(bytes);
            try { token = BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }
            finally { Array.Clear(bytes, 0, bytes.Length); }
            if (token == invite) throw new InvalidOperationException("Independent enrollment key required");
            var next = new EnrollmentRegistration(endpoint, invite, token, null, null, null);
            // Flushed encrypted publication precedes every network request.
            store.SaveEnrollmentDocument(next.Export(), false);
            return Load(store);
        }

        public static EnrollmentRegistration Load(GuardStore store)
        {
            string json = store.LoadEnrollmentDocument();
            if (json == null) return null;
            return Parse(json);
        }

        private static EnrollmentRegistration Parse(string json)
        {
            try
            {
                var serializer = new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 16 };
                var root = ClientPolicy.Object(serializer.DeserializeObject(json));
                if (root.Count != 7) throw new ArgumentException();
                ClientPolicy.Integer(root["version"], 1, 1);
                string token = ClientPolicy.Text(root["device_token"]);
                var endpoint = new Uri(ClientPolicy.Text(root["claim_endpoint"]));
                EnrollmentTransportClient.ValidateEndpoint(endpoint, token, true);
                string invite = root["invitation"] == null ? null : ClientPolicy.Text(root["invitation"]);
                string id = root["id"] == null ? null : ClientPolicy.Text(root["id"]);
                if (id != null && !Regex.IsMatch(id, @"\A[a-z][a-z0-9-]{0,47}\z")) throw new ArgumentException();
                if (root["policy"] == null)
                {
                    EnrollmentTransportClient.ValidateEndpoint(endpoint, invite, true);
                    if (invite == token || root["password"] != null) throw new ArgumentException();
                    return new EnrollmentRegistration(endpoint, invite, token, id, null, null);
                }
                ClientPolicy policy = ClientPolicy.Parse(serializer.Serialize(root["policy"]));
                string password = ClientPolicy.Text(root["password"]);
                if (invite != null || id != policy.Id || !Regex.IsMatch(password, @"\A[a-f0-9]{64}\z")) throw new ArgumentException();
                return new EnrollmentRegistration(endpoint, null, token, id, policy, password);
            }
            catch (ArgumentException) { throw new InvalidOperationException("Stored registration is invalid"); }
            catch (KeyNotFoundException) { throw new InvalidOperationException("Stored registration is invalid"); }
            catch (FormatException) { throw new InvalidOperationException("Stored registration is invalid"); }
            catch (InvalidOperationException) { throw new InvalidOperationException("Stored registration is invalid"); }
        }

        public static EnrollmentRegistration Resume(GuardStore store)
        {
            var current = Load(store);
            if (current == null) throw new InvalidOperationException("Registration has not started");
            if (current.Policy != null) return current;
            var poll = new UriBuilder(current.ClaimEndpoint) { Path = "/client/v1/enrollment" }.Uri;
            EnrollmentResult response;
            try { response = EnrollmentTransportClient.Poll(poll, current.DeviceToken); }
            catch (EnrollmentException error)
            {
                // Poll first recovers a lost claim response, including when the
                // background worker has already consumed the invitation.
                if (error.Code != "enrollment_access_rejected" || current.Id != null) throw;
                response = EnrollmentTransportClient.Claim(current.ClaimEndpoint, current.invitation, current.DeviceToken);
            }
            return Accept(store, response);
        }

        internal static EnrollmentRegistration Accept(GuardStore store, EnrollmentResult response)
        {
            var current = Load(store);
            if (current == null || response == null || (current.Id != null && current.Id != response.Id))
                throw new InvalidOperationException("Registration identity changed");
            if (current.Policy != null)
            {
                if (response.Pending || response.Policy.Canonical != current.Policy.Canonical || response.Password != current.Password)
                    throw new InvalidOperationException("Completed registration changed");
                return current;
            }
            var next = new EnrollmentRegistration(current.ClaimEndpoint, response.Pending ? current.invitation : null,
                current.DeviceToken, response.Id, response.Policy, response.Password);
            Parse(next.Export());
            store.SaveEnrollmentDocument(next.Export(), true);
            return Load(store);
        }

        private string Export()
        {
            return new JavaScriptSerializer { MaxJsonLength = 1048576 }.Serialize(new Dictionary<string, object> {
                { "version", 1 }, { "claim_endpoint", ClaimEndpoint.AbsoluteUri }, { "invitation", invitation },
                { "device_token", DeviceToken }, { "id", Id },
                { "policy", Policy == null ? null : Policy.Document() }, { "password", Password }
            });
        }

        public override string ToString() { return Policy == null ? "pending" : "registered"; }
    }
}
