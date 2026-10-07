# Managed desktop access

## State

Implemented and exercised end to end with a real Windows client against a
disposable router with real IKEv2/ESP on both sides of it
(`scripts/openwrt/client-desktop.sh`):

- activation from the Remote clients page, publication of catalog services,
  device invitations, HTTPS registration and per-device credentials;
- SA-bound admission, the dedicated proxy path through the required exit and
  its readiness evidence, per device and tunnel address;
- the Windows service, window and single-file installer: persistent denials,
  managed names and routes, the owned IKEv2 connection, permission only while
  the router confirms its path, central policy updates and revocation.

- every name under a published domain, answered and carried through the
  tunnel without lists of subdomains (see "Names under a service");
- the device directory on the Remote clients page: who a device belongs to,
  its computer, system, client version, tunnel address and whether it is
  connected; a device is opened by its registration and removed in one step.

The macOS client is written and tested up to the privileged boundary (see
"macOS"); its installed form has not been run. Binaries are not signed with a
publisher identity. Sections below describe each part; where
an older paragraph says a step "remains incomplete", this list is the current
state.

## Product boundary

Windows and macOS clients connect to the inbound IKEv2 server for individually
assigned services. Other traffic retains its existing route, including another
VPN where that client permits coexistence. An incompatible VPN must cause a
visible failure, never a fallback to an unapproved exit.

The existing service catalog remains the source of domain lists. Publishing a
service to remote clients reserves its virtual addresses; it does not authorize
every user. User or group assignments decide which services each device receives.
No service name is built into the protocol or clients.

Clients need connection, enforcement, route and data-plane status, minimal
controls, and a previewable redacted diagnostic report. An established SA alone
must never produce a protected status. Device credentials are separate from
shared service policy and independently revocable.

## Stable addresses and compilation

`client-access.uc` validates policy and allocates addresses from an explicitly
configured RFC1918 subnet, separate from dynamic FakeIP. Deployment must check
it against LAN, inbound pools, existing routes and other VPN ranges. The
allocator retains removed domain allocations and does not recycle them: stale
clients must not reach a different service at an old address. The authoritative
registry requires a persistent backup; losing it is not permission to reallocate.

The compiler entry point is `client-access-policy.uc`. Its default mode reads a
credential-free policy from stdin and emits hosts records, routes and sing-box
rules. `allocate` reads the service catalog, allocation history and selected
service IDs and emits the next history plus authorized resources. `client-access-state.uc` owns the committed publication snapshot: allocation
history, per-device revisions, retired identities and the derived API directory.
Updates supply an expected generation and desired assignments, without supplying
allocation or policy history. Removed device identities remain revoked and cannot
be reused. An unchanged device policy retains its revision.

`client-access-store.uc` publishes the snapshot under an exclusive file lock in a
root-owned 0700 directory. Files are root-owned 0600 regular files with one link.
A staged file is closed and synchronized before atomic replacement, followed by
another synchronization. An initialization marker prevents missing history from
silently creating a new allocation registry. Recovery after an interrupted initial
commit requires explicitly restoring verified history; no automatic reset exists.

The local administrative entry point is `client-access-control.uc`, installed in
`/usr/libexec/ikev2-manager.d`. `initialize` and `publish` read
`{version:1, expected_generation:N, desired:{...}}` from stdin; `status` reports
counts and the committed generation. The fixed state directory is
`/etc/ikev2-manager/clients`. The device HTTP API remains read-only. LuCI administration uses the narrow
`ikev2-client-admin` bridge rather than exposing this writer executable. `inspect` returns services and assignments without device credential
hashes or previous policies. `update` reads `{version:1, expected_generation:N,
operation:"configure-service"|"assign-device", payload:{...}}` from stdin.
Service configuration specifies `id`, `client_access` and `transports`; domains
come from the existing service catalog helper. Device assignment specifies an
existing `id`, `enabled` and `selected_services`, retaining its credentials.
Disabling publication removes that service from device assignments. New device
enrollment uses separate invitation, provisioning and bootstrap endpoints;
the native client flow and activation are not connected yet.

`refresh` reloads client-published service domains from the existing catalog,
validates the complete proposal and commits it atomically. Missing or invalid
lists retain the previous publication. Unchanged lists do not write a new
snapshot. A separate `ikev2-client-catalog` procd instance runs this every hour
and retries failed attempts after a minute, independently from admission.
It uses the existing catalog cache and freshness rules; source-fetch metadata
remains owned by the catalog helper. The router path watcher applies published
changes, and device policy retrieval returns updated revisions.


The Remote clients LuCI page publishes catalog services with explicit TCP/UDP
ports and edits assignments for existing enrolled devices. Its overview returns
service counts and assignments, without domain list bodies, credential hashes
or old policies. Save keeps the generation from when the form opened; concurrent
publication is refused instead of overwriting it. New-device enrollment and
initial setup are not available from this page yet.

Administrative writes use protected one-shot input files. The bridge consumes a
bounded root-owned 0600 single-link regular file into a root-only inbox before
starting the detached worker. Request bodies never appear in command arguments.
The page polls the existing action-status pattern and reloads concrete state
on success. Its ACL grants read operations separately from queued update/refresh
operations and covers both the `/var/run` and `/tmp/run` staging paths.
Disabling an existing service uses retained domains and requires no source fetch.

Policy resources contain an ID, exact domain, stable address and transports.
Each transport has a protocol and its own port list. When services share a
domain, TCP and UDP permissions remain separate. Catalog publication allocates
addresses even for services not assigned to the particular client.

The sing-box generator accepts optional `client_access_policy` and
`client_access_port` inputs. It creates a dedicated TProxy listener and explicit
destination rules before ordinary sniffing and routing. Missing exits and
unmatched destinations are rejected. The runtime does not yet supply these
inputs or install the interception rules. This is not an active router feature.

The separate `path` compiler mode reads a validated committed state plus a
server-selected XFRM exit interface, resolver and listener port. It compiles a
dedicated sing-box instance from the published catalog. Both service sockets
and TCP DNS bind to that interface; unknown destinations are rejected. It does
not inspect or redirect unrelated traffic. Its kernel plan uses a destination
and ingress-scoped local route, an interception chain after SA admission, and
terminal denial when interception has no listener. Forwarding virtual addresses
is always denied. The controller manages process ownership, configuration activation and exit
selection; its isolated data-plane checks are described below.

SA/tuple admission sets the reserved `0x00800000` mark for permitted requests
and replies. The independent path guard requires that evidence, so removing the
admission table also closes interception and replies. Existing inbound user
policy permits only this marked virtual-subnet traffic before broader router
and Internet restrictions. The subnet comes from protected committed state;
invalid state adds no exception. Other inbound access checks remain unchanged.

The `authorize` compiler mode accepts server-owned user assignments and a
snapshot of authenticated sessions. It produces source/destination/port grants
with separate TCP and UDP sets and scalar reqid/SPI checks. Unknown identities, ambiguous reused addresses
and out-of-pool sessions receive no grants. Conflicting policy allocations or
overlapping inbound and virtual pools are rejected. The generated prerouting
guard checks every packet against the observed inbound SA before interception.
Replies require an active reverse permission and a matching outbound SA in
postrouting; grants expire while the terminal denial remains installed. `ikev2-client-access` connects the committed snapshot to bounded local VICI
queries. It installs an empty denial table before first admission, replaces its
owned table atomically, and refreshes 15-second grants every two seconds. A query
failure, malformed publication or malformed session evidence clears existing
grants. Stopping the watcher retains denial; after an uncatchable process death,
kernel set timeouts close admission. A foreign table with the same name is not
replaced. Runtime status reports admission evidence and freshness, not complete
desktop or outbound-path protection. Admission now requires a protected
`path-ready.json` acknowledgement in the runtime directory. Its generation and
exit must match the compiled publication; its configuration hash and kernel
fingerprint must match current local files and rules. The recorded root-owned
sing-box process must still have the same start time, executable and exact
configuration argument. Missing, stale, changed or dead evidence closes grants.
The receipt writer must own configuration activation; it is not a device API.
The controller now selects the configured exit watcher's permitted tunnel,
validates its XFRM interface and compiles the committed catalog. It validates the
proxy configuration, refuses occupied routing slots and overlapping destination
routes, installs its scoped local route and interception table, and starts a
separate owned proxy. Readiness is published only after the actual process owns
both listeners and its recorded applied configuration matches the publication.
Changed configuration replaces the process; unchanged current configuration
retains it. Close stops only a process with matching ownership and start time.
Automatic activation has been exercised in disposable home-router namespaces;
permanent installation and complete desktop integration remain unverified. Isolated
admission-only tests explicitly disable this gate in a copied source helper;
the installed helper discards caller overrides and always requires it.

## Updates and enrollment

The implementation must provide a single installer per OS and short-lived,
single-use invitations. Enrollment must authenticate the server before accepting
credentials or policy; the public enrollment surface must not expose LuCI or
administrative RPCs. An invitation becomes a per-device credential, not a shared
password. Stored credentials belong in the OS credential store.

The invitation transition module bounds validity to 1-60 minutes, rejects reused
identities and tokens, and rechecks current service availability at reservation.
Its root-only journal persists consumption and a disabled device proposal before
credential creation. Disabled publication can resume after interruption and
rebase onto current catalog history without replacing unrelated edits. A crash
after publication is recovered without publishing the old snapshot again.
Conflicting credentials, enabled/retired identities and revoked services are
refused; the consumed invitation cannot be replayed or silently reinitialized.
Explicit abandonment clears an unpublished reservation or retires its matching
device publication while preserving allocation history. It cannot modify a
device with another key or make the invitation usable again. External IKE
credentials need cleanup by the provisioning owner. Dedicated HTTPS endpoints
now support claim and polling; native enrollment and activation remain incomplete.

`POST /client/v1/enroll` authenticates the invitation with a bearer token and
binds it to a separate 256-bit `X-Device-Token` generated and persisted by the
client before sending the request. Both tokens use 64 lowercase hex characters.
The endpoint accepts no body, identity or service selection. A retry with the
same pair returns pending; another device token cannot reuse the invitation.
`GET /client/v1/enrollment` authenticates with the device token. It returns
pending until the background worker provisions credentials and commits disabled
publication, then returns the initial policy and EAP credential bundle within
the invitation lifetime. Enabled, retired or unassigned devices cannot retrieve
that bundle. Responses are not cached; TLS, protected credential storage,
account-secret consistency and nondecreasing journal time are required.

The root-only `client-access-invitation-control.uc issue` command accepts a bounded JSON
request on standard input: version, expected enrollment generation, endpoint,
device id, selected services and lifetime in seconds (60-3600). It generates
256 bits from the operating system, commits only the SHA-256 digest, then returns
one invitation link with the token in its fragment. The HTTPS endpoint must match
the published server address and the exact enrollment path; a port is optional.
Issuance does not enable the device or verify listener availability. Lost journal
history cannot be silently initialized again. Until the administrative delivery
flow is integrated, invoke it only with private output handling; do not put its
result into ordinary jobs, reports or logs.

The Remote clients page now creates invitations from a device identifier and
selected published services. Its detached job consumes a protected input file;
ordinary job status and inspection contain metadata only. The result is kept
in a root-only runtime directory and retrieved by a write-only administrative
ACL command. Retrieval is locked, rejects unsafe files and unlinks the result
before returning the link. Repeated retrieval fails; expired retrieval removes
the result without returning it. The page provides a copy button and clears the
link field when closed. A lost response requires a new invitation and identity.
The configured dedicated HTTPS listener is still required; the form does not
establish or verify that listener.

The root-only credential worker now stages a separate random EAP password per
reserved device, retains it across retries and uses the manager's restrictive
user-policy transaction. A policy-only retry explicitly reloads strongSwan
credentials; an unavailable daemon cannot report successful loading. Issuance
markers prevent silent password replacement after lost history. Explicit cleanup
requires an aborted invitation, matching account secret and retired or absent
publication, and retains the issuance marker. These operations return metadata
only; credential records are not included in administrative inspection.

Credential staging/loading and cleanup have been exercised with real strongSwan
and UCI in disposable OpenWrt systems with the gateway unconfigured. This does
not prove an operational inbound path or desktop protection. Separate installed
HTTPS tests verify trusted TLS, token binding, background credential delivery,
retry, storage failures, disabled admission, clock rollback and expiration.
Manager account operations and empty-database initialization now share a kernel
lock. Its descriptor remains held by live child operations after parent death.
The private owned-user operation compares the expected secret while holding this
lock before creation, repair or deletion; a concurrent password change cannot
turn an earlier ownership check into permission to modify another account.
The background coordinator is installed under `ikev2-client-access` supervision.
The dedicated HTTPS launcher is now supervised by `ikev2-client-access` after
explicit publication initialization. UCI `client_access.enabled` defaults to 0;
`client_access.port` defaults to 8443 and permits 1024-65535. The inbound server
must be enabled and its configured identity must match the published address.
The launcher uses the existing server certificate/key configuration, verifies
protected source paths, stages a private pair and checks TLS server purpose,
hostname, validity and matching public keys. It binds IPv4 and IPv6 with an empty
root and only the client API handler; it attaches no LuCI or ubus handler.
Configuration reload updates the API instance without restarting unchanged client
controllers. Disabling removes the listener. Certificate renewal currently
requires a service reload; automatic renewal integration remains incomplete.

Installed OpenWrt tests exercise the launcher and actual procd startup, port
reload and disable. No live router endpoint or WAN firewall rule has been
configured. WAN exposure, management UI for listener configuration, native
client enrollment, activation and full data-plane integration remain incomplete.

Windows `EnrollmentTransportClient` implements the claim/poll HTTP contract
with platform certificate and hostname validation, no redirects or HTTP proxy,
a bounded strict UTF-8 JSON response and credential-to-policy identity checks.
Pending responses cannot contain credentials. Validation tests run on Windows;
they do not prove live TLS enrollment. Protected OS persistence is tested separately.
`EnrollmentRegistration` now generates and saves an independent device key before
any request, polls before retrying a claim after a lost response, pins a returned
device identity and retains the initial policy and password after successful
registration. Completed registration drops the invitation. It never activates
traffic permission.

The service-owned Windows journal uses DPAPI LocalMachine encryption plus
administrator/LocalSystem-only file permissions. Machine scope permits the
system service to resume registration initiated by an administrator; the file
ACL remains necessary because machine-scope DPAPI does not isolate local users.
The journal is flushed before publication. A staged first write is recovered
without changing the key; a marker prevents silently starting over after loss
of committed history. Invalid permissions, damaged ciphertext and changed
identity are refused. Native tests verify restart recovery, restricted-user
access denial and failure behavior.

`GuardRuntime` can begin and continue registration. On restart it stages a
completed registration's initial policy under persistent WFP denials before
publishing policy intent. An invalid registration refuses startup while
preserving installed denials. Actual Windows WFP tests exercise this recovery;
the state remains blocked, not protected. Native profile installation, system
hosts/routes and router activation are not wired yet.

The Windows service exposes only `begin` and `continue` through a local named
pipe. Initial registration requires an elevated administrator token; continuing
the stored registration is available to local users. Network pipe connections
are rejected by the kernel. The client compares the pipe server process with
the running SCM service before transmitting the invitation. Requests and replies
have strict fields, a 4 KiB frame limit and bounded I/O. An acknowledgement keeps
the server from discarding unread output when disconnecting. Slow clients are
cancelled and disconnected without relinquishing the owned pipe instance.
Neither administrative commands nor saved credentials are exposed.

Registration processing runs separately from the pipe listener, polls while
pending and resumes saved pending registration at service startup. The Windows
window accepts an invitation link of the form
`https://vpn.example.com/client/v1/enroll#<64-lowercase-hex-token>` and sends
the token separately from the HTTPS endpoint. It offers continuation/retry
without reading the protected journal. Actual SCM tests cover command delivery,
restricted-user refusal, unknown operations, oversized frames, slow clients and
encrypted registration persistence. Interactive enrollment and a live native
claim/poll exchange with the router remain verification gates.

Policy updates need authentication, monotonic revisions and staged activation:

1. Validate the new policy and address history; reject rollback and collisions.
2. Install and verify denial outside the assigned VPN for added resources.
3. Install hosts entries and narrow VPN routes, then verify actual traffic.
4. Acknowledge the revision; retain protection if any step or the service fails.

Retiring access must also retire router-side authorization and established
connections. Removing hosts entries while a user is still protected would expose
public resolution, so revocation cannot simply delete the client configuration.
Policy removal is a separate, explicit operation.

`hosts` only handles exact names. Suffix entries in existing service lists cannot
be represented by pretending the suffix covers all subdomains. The client DNS
and enforcement design must cover that case before service publication is
considered complete. External proxies, separate resolvers, WSL and containers
also require explicit coverage or a visible refusal of that execution mode.

## Client policy validation

Windows `ClientPolicy.cs` and macOS `ClientPolicy.swift` validate the router
policy schema before any network mutation. Resources are immutable and ordered
canonically, with distinct TCP and UDP permissions. `PolicyHistory` proposes a
new value without changing committed state. It rejects revision rollback,
changed content at the same revision, changes to the enrolled server or address
pool, and reassignment of any previously reserved domain or address. Retired
addresses remain in the required protection set. Hosts reconciliation uses the
complete allocation history, so revocation retains the protected name mapping.
History can be serialized and restored with strict validation of reserved
addresses and the current revision. Authenticated policy transport is implemented on both platforms. The Windows
service retrieves policy every 30 seconds after enrollment and on service restart;
changes extend persistent denials before committing history. Connection failures,
rejected updates and revocation close permission sessions and leave a visible
error until successful synchronization. Each complete HTTP response has a
10-second deadline. Windows provisions selected /32 routes in an owned split
IKEv2 profile; actual dialing, route observation and hosts/DNS activation remain
pending. Windows stores protected intent in a separate restricted journal;
macOS filesystem persistence is not implemented.

The router compiler and both clients run the same policy fixtures. Local client
tests additionally cover update ordering, retained allocations and rollback.
Mutations that forget retired allocations during updates or recovery are
rejected on both platforms. Shared history fixtures cover duplicate, missing,
out-of-pool and bootstrap allocations.

## Verification gates

- Persistent OS guard, including boot, crash, sleep, reconnect and stale state.
- Router authorization based on authenticated device/user identity, not merely
  possession of a destination address or a client-side service list.
- Guard installed before any hosts or routing mutation; transactional recovery
  preserves unrelated configuration and the management connection.
- Real TCP and UDP traffic through the selected exit; both inbound and outbound
  tunnel failures tested, including existing connections.
- Windows and macOS route, IPv6, DNS, proxy and third-party VPN compatibility.
- Published and assigned service changes reach clients without new VPN profiles;
  existing addresses remain stable and revoked access closes existing sessions.
- GUI reflects verified current evidence; missing or stale evidence cannot show
  protected. Reports omit credentials, invitation tokens and personal paths.
- Signed distributable applications and installers; updates authenticated before
  activation. Native networking integrations tested on both operating systems.

## Windows enforcement implementation

`desktop-clients/windows/build.ps1 -Version X.Y.Z` builds the service, the
window and `WaypointSetup.exe`, which carries both. Setup requires
elevation, installs an automatic SYSTEM service under a protected Program Files
folder with service recovery, a Start menu shortcut and an uninstall entry, and
opens the window. Running it again updates the binaries and keeps the
registration and the persistent filters. `/uninstall` stops the service, has
the service binary remove what it installed (filters, managed names, the VPN
profile, an abandoned connection and the state directory) and then removes the
files; `/quiet` suppresses dialogs. The binaries are unsigned, so Windows shows
its unknown-publisher warning.

### Permission, status and recovery

`GuardRuntime` asks the router every two seconds whether its path is in effect
for this device at the tunnel's address (`GET /client/v1/readiness`, device
token, `X-Client-Address`). Only an answer for the same device, address and
policy revision permits the tunnel interface in the dynamic WFP session and
publishes `protected`. An unanswered request keeps permission for at most ten
seconds since the last confirmation, less than the router's own fifteen-second
admission lease; revocation, a different policy or an invalid answer closes it
at once. Without confirmation the state stays `tunnel_connected` with a reason
the window explains. Selected addresses are virtual and denied outside the
tunnel at all times, so this gate decides what the user is told and when the
tunnel may carry traffic, not whether traffic can leave another way.

The user's last connect or disconnect is journaled; a restart, a reboot or a
killed service returns to it. A connection left on the managed entry by a
killed service is ended before dialing, at startup and on removal. A policy
poll that got no answer keeps the committed policy and the connection; a
refused one closes them.

The status is version 3: state, guard, protection, connection intent, error
code, assigned and available service names, domain count and policy revision.
The window shows them as blocking outside the tunnel, tunnel and routes, router
path and services, offers only the actions that apply, and connects by itself
after a registration started in it. The report preview contains the same
fields and no addresses, names of hosts or credentials.

`WfpGuard.cs` installs persistent IPv4 destination denials at connection
authorization and inbound/outbound packet layers, plus boot-time packet filters.
Permissions require an explicit interface LUID and belong to a dynamic WFP
session. Closing that session or terminating its process removes the permissions;
disposing the controller retains the persistent denials. Explicit removal owns
only the recorded filters and sublayer. Recovery verifies recorded filter
destinations, actions, layers and ownership before permitting traffic.

`GuardStore.cs` stores a protection plan before installing its filters. The
directory, journal and controller lock grant access only to Administrators and
SYSTEM. A write-through temporary file is flushed before publication; recovery
reconciles the recorded filter identities in a WFP transaction. An exclusive
file handle prevents two controllers from owning the store simultaneously.
Plan extensions retain every existing destination and filter identity. Removing
a service does not silently remove its local denial.

`GuardStore.SavePolicyHistory` requires every historical destination in the
protection plan and verifies the installed WFP denials before publication. The
restricted journal preserves revisions and allocations across restart. Invalid
updates leave the previous journal intact. Startup and heartbeat validation
reject malformed history or missing plan coverage while retaining existing
denials. This is protected intent, not proof that hosts or routes were activated.

`GuardRuntime.StagePolicy` coordinates the ordered transition under the service
lock: validate the next history, close permissions, persist the protection plan,
install and verify its denials, then publish policy intent. Failure retains the
plan for recovery and opens no permission. Callers must authenticate the policy
source; registration recovery can now stage the initial policy through the service coordinator. First
staging and later revisions are tested against native WFP.

`ClientService.cs` hosts the guard under the Windows Service Control Manager.
It recovers the stored plan, checks the guard and publishes a bounded status
record that ordinary users may read but cannot modify. Stopping or killing the
service retains persistent denials. The runtime now coordinates registration
storage and initial protection recovery. User-facing enrollment and tunnel
activation remain incomplete; the service never reports end-to-end protection.
It has only been installed as an isolated loopback test service.

`ManagedVpnProfile.cs` invokes an embedded fixed PowerShell program with metadata
on standard input. Passwords and device tokens are absent from this operation.
The SYSTEM service creates one global split IKEv2/EAP profile whose name derives
from the persistent guard owner. A separate protected journal pins the native
entry GUID to that owner; missing initialized history or another GUID is refused.
The profile uses the inbound server's AES256/SHA256/Group14 compatibility suite.
Existing crypto, authentication, server and split-routing settings must match;
unexpected changes are refused. Windows currently requires identical server
address and remote identity. Remembered and Windows-logon credentials are disabled.

Provisioning follows persistent WFP staging. Only current selected destinations
receive /32 profile routes; retired destinations remain locally denied. Policy
refresh reconciles those routes in the same profile and preserves other VPN
entries. Interrupted first creation can finish the owned entry before its GUID
is journaled. Provisioning has a 30-second process deadline; failure grants no
traffic permission. Native profile creation, stable ownership, route replacement
and unrelated-profile preservation have been exercised on Windows. A real
SCM/OpenWrt HTTPS enrollment run also created and persisted the profile and
updated it from central publication. An opt-in native connection scenario now
also verifies EAP IKEv2 establishment and effective selected routes. Full traffic
protection remains incomplete.

`SystemHosts.cs` reconciles assigned and retained domain mappings only after
persistent WFP coverage is verified. Replacement preserves unrelated entries,
checks file ownership and permissions, and refreshes the system DNS cache.
Ordinary disconnection retains mappings. Alternate resolvers and proxies remain
separate coverage requirements.

`OwnedRasConnection.cs` dials through native RAS with credentials in process
memory, pins the connection identity and closes only its owned handle.
`OwnedTunnelRoutes.cs` installs selected active-store /32 routes on the observed
interface: profile routes alone are insufficient evidence. Installed rows are
read back, verified and removed only while their owned state is unchanged.

`ClientApp.cs` provides a Windows status and registration window and a previewable
report that the user can save explicitly. `ClientStatusReader.cs` verifies the
status file permissions, running SCM process identity, timestamp and supported
state before displaying it. Stale, inconsistent or unsupported protection
claims are rejected. Reports contain only allowlisted status fields. Native
rendering was checked without an interactive desktop; interactive saving and
normal-user installation still need verification.

Live enrollment, profile validation, native connection and selected-route checks
are integrated. Checked with the installed product against a production
router: after a reboot the boot-time and persistent denials are present and
the service reconnects and reaches `protected` before anyone logs on; after
sleep the lost connection is redialled within the retry interval; with a
global IPv6 address and a default IPv6 route on the machine, managed names
return no AAAA record and a forced IPv6 request has nowhere to go; with a
full-tunnel WireGuard connection that blocks other traffic, selected services
stay closed and return when it is gone. A connection whose handle the system
no longer knows is closed by what the system lists for the managed entry, so
it cannot keep the service from redialling, stopping or being uninstalled.
The service keeps `faults.log`, the last forty failures as time, place, kind
and code, and the window's report includes it. WSL and containers were not
present on the test machine and are unverified.
An interface observation alone must not authorize permissions. The controller
must verify the enrolled profile, current routes and data plane before opening
access and revoke permissions when that evidence expires. This component is not
yet an end-to-end access controller.

`RasTunnel.cs` observes a managed profile by entry GUID and phonebook path through
native RAS APIs. It requires connected IKEv2 projection and a unique active PPP
interface matching the negotiated IPv4 address. The observation does not
authenticate the intended server or prove the effective route. Its connected
path has been exercised with an actual enrolled IKEv2 connection in a disposable
server scenario; it does not prove application traffic protection.
`RouteObservation.cs` reads the route actually chosen by Windows, without
constraining the lookup to the desired interface. Its match requires the tunnel
LUID, negotiated source address and an exact destination route. Native checks
cover loopback route observation and rejection of an unrelated interface.

## Current checks

`scripts/test-client-access-policy.py` exercises compilation and allocation.
`scripts/test-desktop-client-core.sh` runs native hosts transformation checks
where toolchains are present. Windows also runs `desktop-clients/windows/test.ps1`.
The elevated `-EnrollmentStorage` option exercises encrypted registration and
restricted-user access without changing VPN profiles, hosts, routes or WFP rules.
The `-Wfp` suite also tests registration-to-denial recovery with uniquely owned
test filters and removes them afterward.
Both implementations use the same fixtures for conflicts, aliases, malformed
ownership markers, newline preservation and idempotence. These tests do not
modify the system hosts file.

On an elevated Windows process, `desktop-clients/windows/test.ps1 -Wfp` also
tests native filtering against a loopback TCP server and incoming UDP packets.
It covers interface mismatch, revocation of an established TCP connection,
persistent denial after controller shutdown, invalid recovery receipts, and
forced termination of the permission owner. Explicit cleanup restores loopback
reachability. A mutation without inbound packet denials was rejected by the UDP
check. Journal tests kill processes before and after filter installation,
reconcile the same identities, extend protection and reject removal of existing
destinations. Service tests install an isolated executable in a protected
directory, start it through SCM, kill it, restart it and stop it. A restricted
Windows token verifies that status is readable while journal access and status
modification are denied. The test service, directory and filters are removed.
A policy journal scenario temporarily denies two test destinations only after
checking that they have no specific route or active TCP connection. It tests
planned versus installed protection, restart, invalid updates, restricted-user
access, and corruption at startup and during a heartbeat. It does not send
traffic to those destinations and removes its owned filters and journal.
This is not an IKEv2 end-to-end test. The Windows CI job runs this scenario;
the workflow itself has not yet been exercised remotely.

`scripts/openwrt/client-access.sh` uses the production authorization compiler
and two disposable network namespaces with actual kernel ESP, TCP and UDP.
It checks SA identity, permission expiry, unknown users, revocation of an open
stream and replacement of real SAs and keys while retaining the same client IP.
The new SA cannot inherit the old owner's grant. Removing the generated guard
or its reply stages proves that otherwise-denied traffic can resume. Removing
inbound or outbound SA checks was caught by the packet tests. Test SAs,
keys, rules, namespaces and servers are removed. This validates the compiled
kernel guard; EAP identities remain a server-owned fixture, not an actual IKE
login. `scripts/openwrt/client-ike.sh` adds a real certificate-validated
EAP-MSCHAPv2 login between two isolated strongSwan daemons. The production
controller reads their actual local VICI socket and committed publication. The
test checks encrypted TCP/UDP, rejection of an unselected port, assignment
revocation/restoration and session termination. It preserves the working daemon
and removes its disposable namespaces and credentials. End-to-end desktop
protection remains unverified. With `CLIENT_ACCESS_TEST_PATH=1`, the scenario also creates
a real IKE-negotiated exit in a third namespace and runs the compiled dedicated
proxy and existing inbound user policy. It proves TCP/UDP and DNS use the
required encrypted exit with broader inbound router/Internet/LAN access
disabled in the user policy. Required exit loss, proxy loss and removal of the admission table close
access; restoration recovers it. An independently usable direct route and
kernel counters provide the negative control. This remains an isolated router
data-plane test, not desktop enrollment or automatic runtime activation.

## Device policy API and transport

`client-access-api.uc` serves device-specific policies through a dedicated
uhttpd handler at `/client/v1/policy`. It requires HTTPS and a device bearer key;
the root-owned snapshot contains only key hashes. Unknown and disabled keys
receive the same refusal. Requests cannot select another device, post a body,
access administrative endpoints or receive malformed policy fields. The
snapshot directory and file require owner-only permissions. The listener is
not yet installed as a permanent router service or opened on WAN.

Windows `PolicyTransportClient` and its macOS counterpart use platform
certificate and hostname validation, refuse redirects, bypass configured HTTP
proxies and bound the response to 1 MiB. They validate schema and enrolled history
before returning a proposal. Neither fetch commits intent nor grants access.
A temporary home-router HTTPS listener with the existing public certificate
chain was tested against Windows: two revisions were fetched and staged in
native WFP, followed by device-key revocation. A trusted certificate with a
mismatched hostname was refused. Test mappings, filters and device
keys were removed. The uhttpd ucode module remains installed. This was not an
IKEv2 data-plane or macOS networking test.

The `publish` compiler mode creates individual policies from server-owned service
assignments and an authoritative allocation registry. It preserves revisions
for unchanged policy content, advances them for changed access and refuses
identity, pool or allocation changes. Removing all assignments disables policy
retrieval while retaining the last intent. The caller must also revoke live
router grants; client polling alone cannot terminate existing access. Persistent publication and the read-only API share a validated snapshot.
Enrollment and catalog UI integration are still required.


## Authenticated session evidence

The `sessions` compiler mode reads a local swanmon/VICI snapshot for the inbound
connection. For this EAP-only inbound connection, it uses `remote-eap-id` when
present and the authenticated `remote-id` when VICI omits the equal EAP identity.
An explicit invalid EAP field never falls back. It requires authenticated IKEv2,
one IPv4 virtual
address and a previously installed ESP tunnel child on the managed inbound XFRM interface.
The remote selector must be exactly the assigned host. Failed or malformed
snapshots are errors; incomplete sessions provide no admission evidence.
Authenticated rekey and host-update states retain their SA bindings; newly
installing, retrying and deleting children are excluded. Actual packets must
match installed kernel SA metadata. Output retains reqid and both SPIs. The local controller polls this evidence with a bounded query; immediate VICI
event integration is not implemented.

A source address alone is insufficient when the pool reuses an address before
an old grant expires. The authorization compiler binds grants to the observed
reqid and SPIs, rejects conflicting owners and keeps both valid children during
a rekey. Scalar SA checks and timed address/port sets are published in one
atomic table. Generic integer concatenations with timeout sets are avoided:
the router's nft crashed while reconstructing their expiring elements.

The `reconcile` compiler mode joins the protected API publication to a local
VICI snapshot. Device IDs are the provisioned EAP IDs; enabled devices receive
only their server-owned policy. Disabled, unknown or incomplete sessions get
no grant. Invalid local publication or failed VICI reads are errors. The live
controller reads this persistent publication. Enrollment, actual managed-device
IKEv2 provisioning and client activation are not connected yet.

The encrypted packet scenario requires `kmod-nft-xfrm` and XFRM interfaces;
its isolated veth links also require `kmod-veth` on a router. Containers without
XFRM skip the scenario unless `IKEV2_REQUIRE_XFRM=1`, as in CI. The scenario passed
on home hardware; the updated remote workflow has not yet been exercised.
The runtime dependency installer does not yet install nft_xfrm.


## Router admission controller

`ikev2-client-access sync` performs one bounded reconciliation. `watch` starts
with closed admission and refreshes the leased kernel grants; `close` clears
permissions and retains denial, and `status` reads the last result and timestamp.
Commands are serialized; while `watch` is running, use the init service stop
operation before invoking a one-shot command. The procd definition starts only
after publication initialization. Enabling it
and coupling it to enrollment/runtime activation still require integration.
Installed invocation drops caller runtime overrides. No device API or LuCI ACL
exposes controller mutations yet.

The controller owns only `inet ikev2_client_access`, identified by an ownership
chain. Its stop operation never removes that table. A kernel operation failure
reports failure; existing leases provide a 15-second backstop if permissions
cannot be cleared immediately. Status older than the lease cannot establish
current admission. Read-only status is not a substitute for route and data-plane
verification. A missing or malformed state without an existing table cannot
establish the virtual range; provisioning must not activate a listener or client
before the initial denial table is verified.


The encrypted namespace scenario also runs the actual controller against its
committed store. It checks TCP/UDP admission and revocation, invalid publication,
query failure and timeout, explicit closure, graceful stop, uncatchable process
death and stale-lock recovery. It refuses a foreign table and installs an initial
empty guard when its table is missing. The local VICI reader is represented by
server-owned snapshot fixtures in this scenario. The separate `client-ike.sh`
scenario covers real IKE/EAP login and VICI reads; the optional path extension
covers outbound proxy traffic. Enrollment of desktop clients and automatic runtime activation still require end-to-end validation. Removing failure
closure is detected by encrypted traffic continuing after the query fails.

## Activation and service names

`client-access-setup.uc` backs the "Access for remote clients" section of the
Remote clients page through `ikev2-client-admin client-admin-settings` and the
queued `client-admin-setup`. The first save creates the committed state from
the inbound server's DNS identity, the chosen exit and a private virtual subnet
that no interface, route or inbound pool of the router uses; later saves may
change the exit, the port and the switch, never the subnet. The bridge then
stores `client_access.enabled` and `port`, has `ikev2-manager-system
client-api-apply` set the `ikev2pbr_client_api` WAN rule (accepting the port
only while the inbound server and client access are both on) and reloads the
supervised service. `scripts/openwrt/client-setup.sh` covers refusals, first
activation, the live firewall rule, the fixed subnet, exit change and disable.

`GET /client/v1/services` returns, for the authenticated device, the services
it was assigned and the other services published to clients, each as a name
and a domain count. It grants nothing and carries no domains or addresses.

## Names under a service

A service is published as domains; a device must reach every name under them
without anyone listing subdomains. The virtual subnet is split the same way
by the router and by both clients, from the subnet alone: the lower half holds
one fixed address per catalog domain, its last address is the resolver, and
the upper half is the range names are answered from. The default subnet is a
/20.

A client sends questions for each assigned domain and everything under it to
the resolver (NRPT rules on Windows, `/etc/resolver/<domain>` on macOS); the
domain itself stays pinned in the hosts file. The resolver exists only inside
the tunnel. The managed proxy answers an A question with an address from the
names range and remembers the name behind it; any other record type gets an
empty answer, and a name outside the device's services is refused. A
connection to such an address is carried to the remembered name through the
required exit, on the service's ports only, and only from a device the service
is assigned to: the controller writes the tunnel addresses of each service's
connected devices into a source set the proxy reloads (`client-path.sh`,
`scripts/test-client-path.py`). Admission, the client's denials and its routes
cover the whole subnet, so the resolver and the names range are closed outside
the tunnel like the fixed addresses.

Because no AAAA record is ever returned for a managed name, a machine with
working IPv6 has no IPv6 destination for it. Browsers are told by policy to
resolve through the system (the installers set the Chromium-family and Firefox
policies and remove only what they set); a browser with its own encrypted
resolver would otherwise never ask the tunnel. A system proxy takes browser
traffic before any route does; the Windows client reports it as a warning.

On the router the DNS enforcement redirect leaves questions arriving from the
inbound tunnel for the virtual subnet alone, and the firewall admits marked
traffic to the subnet when the inbound zone is closed.

## Devices and their owners

An invitation may carry the owner's name and a note. Registration records
them, and the first policy request records what the device says about itself:
computer name, system and client version. The Remote clients page shows these
with the assigned services, the tunnel address and whether the device is
connected. A device is opened as soon as its registration completes; removal
closes its sessions, deletes its credentials and forgets its record
(`client-admin.sh`).

## Waypoint: names and supported systems

The desktop client is called Waypoint on both systems: the program, its
window, the installer (`WaypointSetup.exe`, `Waypoint-X.Y.Z.pkg`) and the
VPN entry the system shows. Identifiers a user does not see (service name,
state directory, launchd label, markers in the hosts file) keep their earlier
form. The icon is drawn by `desktop-clients/assets/make-icon.py`; its results
are committed. Both windows follow the system's light or dark appearance and
let the user choose one.

Supported: Windows 10 22H2 and Windows 11, x64, with the .NET Framework 4.8
they include; macOS 14 and later on Apple silicon. Run so far on Windows 11
and macOS 27; the other versions are supported by construction, not by test.
Intel Macs are not supported: the package is built for Apple silicon only.

## Networks a device may sit in

What the design gives on networks the administrator does not control, by
reasoning except where a test is named:

- DNS interception or a false resolver. Managed names never ask the local
  resolver (hosts entries, and a resolver that exists only inside the
  tunnel). The server's own name is resolved locally; a false answer leads to
  a host that cannot present the server's certificate, so neither the HTTPS
  API nor IKEv2 authenticates and access stays closed.
- IKEv2 captured or redirected by the local gateway: the same certificate
  check fails it. Behind the router that is itself the server, the client
  works (tested on both systems).
- UDP 500/4500 blocked: no tunnel and no fallback; the window stays at
  "connecting". A limitation of native IKEv2.
- The registration port blocked outbound: registration, policy and readiness
  are asked outside the tunnel, so access stays closed even with the tunnel
  up. A limitation; moving these questions into the tunnel would lift it.
- A local network inside the virtual subnet (WSL and container bridges take
  ranges from 172.16.0.0/12): the local route is more specific than the
  tunnel's, the route check refuses it and access stays closed. Choose the
  virtual subnet with that in mind; it cannot change after the first device.
- A full-tunnel VPN beside it: closed while that VPN blocks other traffic,
  back when it is gone (tested with WireGuard on Windows).
- A system proxy: traffic sent to the proxy bypasses the tunnel; the Windows
  window warns, the macOS one does not yet.
- A program with its own encrypted resolver, other than the browsers the
  installer configures, reaches a service directly and not through the tunnel.
- Captive portals, IPv6-only access networks and small path MTU are
  unverified.

## Client installers in a release

The release workflow builds `WaypointSetup.exe` on a Windows runner
and `Waypoint-X.Y.Z.pkg` on a macOS runner after the router package
is published, and attaches both to the release. Neither is signed with a
publisher identity, so Windows shows its unknown-publisher warning and macOS
needs "Open" from the context menu. These jobs have not run yet.

`GET /client/v1/release` tells an enrolled device the version of the router's
package, as a number and nothing else. A client whose own version is older
shows it and offers a download button; the address is built in the client from
the project's release page, so the router cannot point a user elsewhere. The
program never installs anything by itself: the user runs the downloaded
installer, which keeps the registration.

A disabled or revoked device stays known to the router and its client reports
`access_closed`.

## Marks and other software on the router

Admission marks a packet `0x00800000`, and the path guard and the inbound user
policy ask for that mark. A mark is evidence only inside one hook: other
software rewrites marks between hooks. A connection-mark restore in the mangle
prerouting chain (Tailscale installs one) replaces the whole mark of every
established flow, after this path's interception and before delivery, so the
first packet of a connection passed and the rest were dropped at input. The
admission table therefore decides again at the input hook, from the SA and the
grants, ahead of every input rule that reads the mark. `client-path.sh` installs
such a foreign rule and requires admitted flows to survive it and unselected
ports to stay closed.

A router that was activated but has no device yet reports `closed`, with the
path up and nothing admitted; that is not a failure.

## Complete desktop scenario

`scripts/openwrt/install.sh client-desktop` turns a privileged OpenWrt
container on a host kernel with XFRM interfaces into a router with the
registration listener, an inbound server for a native client, the installed
controller in automatic mode and a namespace that terminates the required exit
with a service and a resolver behind it. A direct route to that service exists
on purpose and is counted, so a leak would be seen. The Windows side is
`EnrollmentIntegrationTests.exe` with `probe_host` set (test service) and
`ProductIntegrationTests.exe` (the installed product): registration,
`protected` only with router readiness, the service answering only through the
exit SA, a closed port, exit loss and recovery, disconnect, restart, a killed
service, update and complete uninstallation. The same installed-product check
has also run against a production router with a public certificate and a real
exit: a catalog service published to the device answered with the exit's
address, not the direct one. The drivers that connect the machines are
site-specific and not part of the repository.

## macOS

`desktop-clients/macos` is a Swift package with three products.

`ClientCore` holds the shared policy and hosts logic, the device requests
(registration, policy, readiness, service names), the private store and the
state machine `ClientRuntime`. Everything the runtime does to the machine goes
through `SystemActions`, and the text it hands over is built by `SystemPlan`,
so each decision is tested without privileges: denial before names, permission
only with router readiness for the same device, address and revision, the
ten-second lease, refusal of a tunnel that carries the default route,
revocation, removal.

`ikev2-manager-clientd` is the root daemon. Its `RealSystem` keeps the managed
block in `/etc/hosts`, loads the packet-filter anchor
`com.apple/250.IKEv2ManagerClient` (the virtual subnet is dropped on every
path; a confirmed tunnel interface is passed for the selected addresses ahead
of that) and drives the system's IKEv2 service with `scutil --nc`. It answers
the window over a Unix socket: status and connect or disconnect for any local
user, registration and the VPN profile for administrators.

The IKEv2 service itself comes from a configuration profile that the daemon
generates after registration and the owner approves once in System Settings;
macOS offers no way to install it silently. The profile names the device
`<id>@managed.ikev2-manager`. The inbound server answers that name on its
`ikev2-in-managed` connection, which offers the virtual subnet alone, so the
system routes nothing else into the tunnel
(`scripts/openwrt/client-managed.sh`). If a tunnel nevertheless carries the
default route, the daemon stops it and reports `tunnel_takes_everything`. A
router with a custom inbound configuration has to define that connection
itself.

On current macOS a profile-installed IKEv2 configuration is not listed by
`scutil --nc` and a program cannot start it. The profile therefore connects on
demand: the system brings the tunnel up and keeps it, with no step for the
user. The daemon learns that the profile is installed from `profiles list
-all` and that the tunnel is up from the routes of the virtual subnet.
Switching access off in the window closes the packet filter and leaves the
system's connection alone; the tunnel routes the virtual subnet only. A user
who switches the VPN off in the system's settings sees it come back.

`IKEv2ManagerClient` is the window. Both windows are built the same way: a
status with one sign and colour, three checks (denial outside the tunnel,
tunnel and routes, path through the office), the assigned services, a notice
for an update or a proxy, and one prominent button for the next step; the
macOS one adds "a VPN profile is needed".

`desktop-clients/macos/build.sh X.Y.Z` builds an installer package for Apple
silicon: the application, the daemon under `/Library/PrivilegedHelperTools`,
its launchd job and `io.github.nikitid.ikev2-manager-client.uninstall`, which
removes the rules, the names, the VPN profile, the stored device and the
files. Binaries carry an ad-hoc signature only.

Verified: the unit tests; the daemon running unprivileged with `--dry-system`
against the disposable router - registration over verified TLS, private
storage, planned denial and names, service names, the generated profile, the
router refusing readiness for a tunnel it did not authenticate, revocation and
removal; the package's contents. Not yet run on a Mac with privileges: the
installed daemon, the packet-filter anchor, the profile approval and a real
IKEv2 session. The packet filter does not keep rules across a boot. The
daemon is a launchd job started at boot, before any user session, and loads
the denial before it touches names; until then managed names point at virtual
addresses that lead nowhere, so nothing reaches the real service.
