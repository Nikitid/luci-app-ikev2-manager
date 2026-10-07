# Traps

Failures that looked like something else and cost hours. Each one is here
because the obvious reading of the evidence was wrong, and because nothing in
the code makes the real rule visible at the point where you would break it.

Where a check now guards a trap, it is named. Add to this file whenever a bug
takes more than an hour to locate: the entry is cheaper than the second
investigation.

## rpcd resolves a path before it checks the ACL

OpenWrt symlinks `/var` to `/tmp`. A grant written as
`/var/run/ikev2-manager-client-*.in` is therefore never the path rpcd tests -
it tests `/tmp/run/...` - and every write through it is refused with
`Permission denied`. Grant both forms.

What made this expensive: `ubus call session access` compares the path
**literally**, so it answered `true` for the exact string the real call was
refused on. The permission looked present while it was absent. Verify a
permission by making the call, not by asking `session.access`.

Guarded by `scripts/check-luci-exec-acl.sh`.

## rpcd passes the caller's environment to the helper

`file exec` takes an `env` object and sets it in the child; the ACL checks
only the command and its arguments. Every `IKEV2_*` override a helper reads
was therefore settable by any LuCI session, read-only ones included, and some
of them choose what the root helper runs. The overrides exist for the tests:
where the package is installed a helper drops them, resets `PATH` and unsets
`TMPDIR` before anything else. Nothing may hand a child a decision through the environment -
the "lock already held" flag became a check that the lock holder is a parent
process (`action_lock_held_by_ancestor`).

Guarded by `scripts/openwrt/scenarios.sh`.

## `ubus -S` is silent about failure

`ubus -S call ...` prints nothing on success *and* nothing on a refusal.
Reading an empty result as success turned the trap above into two wrong
diagnoses and two pointless releases. Always check the exit status.

## LuCI resource names must carry a version

LuCI requests a view as `<name>.js?v=<luci version>`, and that version does not
move when this package is upgraded. A resource whose file name never changes is
served from the browser cache across an upgrade: new code, old page - or worse,
new page code against cached stylesheet rules, which renders a layout that
matches neither.

Every view and the shared module carry a `-vN` suffix; bump it when the file
changes shape. Superseded names are deleted in `postinst`, or they accumulate.

Guarded by `scripts/check-luci-ui-contract.sh`, which also fails when pages
disagree about which build of the shared module they want.

## The page-wide control floor outranks a bare class

`shared.js` sets `.ikev2-page textarea { min-height: 6rem }`. That selector is a
class plus an element; a rule written as `.ikev2-domain-editor { min-height:
19rem }` is a class alone and loses. The editors silently stayed at the floor
for two releases while the rule sat there looking correct.

Scope component rules to `.ikev2-page .ikev2-thing`, and when two rules have
equal weight remember that the later one wins - an override must come *after*
the rule it narrows.

## Marks route the tunnel, not source addresses

`ip rule` selects the tunnel table by fwmark. Binding a socket to the tunnel
address does not put it in the tunnel:

```
ip route get 8.8.8.8 from <tunnel vip>  ->  via <wan gateway> dev <wan>
```

Only `SO_BINDTODEVICE` works, which on these routers means `curl --interface
ipsec-out`. A probe that binds the source address instead answers about the WAN
path while looking like it answers about the tunnel - a false healthy. The
tunnel DNS health probe uses a temporary sing-box worker with
both bootstrap and DoH bound to that interface. A successful empty HTTP request
to a DoH endpoint is not a successful DNS query.

## A socket keeps the source address it was opened with

A connected UDP socket fixes its source when it is created. If `ipsec-out` has
no IPv4 address at that moment, the kernel picks one from another interface -
the WAN address - and the socket keeps it after the tunnel address returns.
xfrm then drops every packet silently: the policy selector is the tunnel
address. sing-box shares one UDP socket per DNS server and replaces it only on a
read or write error, never on a timeout, so the tunnel resolver failed with
`lookup dns.cloudflare.com: context deadline exceeded` until a restart, while
listeners, configuration and the separate tunnel DNS probe all looked healthy.

Three things keep it closed: the tunnel address stays on `ipsec-out` across a
reconnect (only disabling the client removes it), the tunnel bootstrap resolver
uses TCP, which dials per query, and the watcher checks the live instance
through `/proxies/ikev2-out/delay` and restarts it when the tunnel works but the
instance does not.

Guarded by `scripts/test-data-plane-recovery.sh` and `scripts/test-dns-regressions.sh`.

## strongswan.d/charon/ is inside charon.plugins

`/etc/strongswan.conf` includes `strongswan.d/charon/*.conf` inside
`charon.plugins { }`. A `charon { ... }` section placed there becomes
`charon.plugins.charon` and is ignored without a warning. Charon settings go in
`/etc/strongswan.d/ikev2-manager.conf`, which is included at the top level.
`install_virtual_ip` is read when the kernel-netlink plugin starts, so a change
needs a charon restart; `swanctl --reload-settings` does not apply it. Doctor
reports `tunnel_vip_placement=warn:charon-managed` when the tunnel address is on
any interface besides `ipsec-out`.

Guarded by `scripts/test-package-lifecycle.sh`.

## A strongSwan upgrade restarts charon, or leaves the old one running

Every strongSwan package's post-upgrade script runs `/etc/init.d/swanctl start`.
procd restarts charon only when a file in the instance's list changed, and
`/etc/swanctl/swanctl.conf`, the stock file the package ships, is one of them.
An upgrade that brings a new copy of it restarts the daemon and drops every
tunnel. One that does not, or one that keeps an edited copy, leaves the old
daemon running until the next restart. Doctor reports the installed version
and, as `strongswan_running`, the version charon reports itself.

## swanctl signals its whole process group when charon goes away

`swanctl --monitor-sa` ends, when charon closes the VICI connection, with
`send_sigint()`, which strongSwan implements as `kill(0, SIGINT)`: every process
in its group. A service procd starts runs in procd's own process group, and
procd takes SIGINT as a reboot. With the inbound session monitor started that
way, every charon restart - `swanctl restart`, a strongSwan upgrade - rebooted
the router in an orderly way: the shutdown scripts ran, ubusd, logd and wpad
were signalled too, and nothing reached pstore, so it looked like a kernel hang.

The monitor runs under socat with `setsid`, in a session of its own, and so does
the inbound diagnostic `swanctl --log`. Any other long-running swanctl client
needs the same.

Guarded by `scripts/openwrt/scenarios.sh`.

## LuCI trims a translation key before looking it up

`_()` collapses whitespace in the string before hashing it, so a catalog entry
whose id ends in a space is never found and the page stays in English. Put the
space in a `%s` format string instead of the id.

Guarded by `scripts/test-luci-translations.sh`.

## A busy button keeps what the page decided about it

A button stays busy until `onSuccess` has read the new state, then shows its
outcome. Released before `onSuccess`, it flashed its idle look between the
spinner and the result. Held through it, the restore overwrote what `onSuccess`
had set: Pause came back as Pause, and a Save that `trackChanges` greyed out
became usable again. `setBusy` now keeps a label changed while busy, and a
busy button records a `disabled` write as the state to return to. Relabel or
disable in `onSuccess` or `onError`, never inside `run`.

Guarded by `scripts/test-luci-shared.js`.

## A package manager call per package is slow on the router

Each `apk` invocation costs about 60 ms. Doctor asked for every strongSwan
plugin's version separately and made the overview page wait three seconds.
A read-only report takes one listing with `pkg_cache_versions` and answers
from it; `pkg_cache_clear` drops it before anything installs. The overview and
the Status widget serve their stored snapshot at once and refresh it in the
background; only a missing snapshot is computed while the page waits.

Guarded by `scripts/test-runtime-modules.sh`, `scripts/test-doctor-ui-cache.sh`
and `scripts/test-widget-status.sh`.

## A TProxy fwmark rule can fail after Tailscale starts

Tailscale 1.98 sets `net.ipv4.conf.all.src_valid_mark=1`. If the FakeIP local
route is selected by fwmark, Linux also uses that sparse local-only table for
reverse-path validation and silently rejects forwarded LAN sources. DNS,
nftables counters and router-originated TProxy traffic all remain healthy while
LAN clients time out.

Select the local TProxy table by the reserved `198.18.0.0/15` destination
*and a covered ingress interface*. Router-originated packets need a separate
`iif lo` plus fwmark rule: a destination-only rule also catches their first,
unmarked route lookup and bypasses the output hook, making FakeIP destinations
unreachable from the router. Verify real HTTPS both from a LAN client while
Tailscale is running and from the router when router-traffic routing is enabled.

## BusyBox is not coreutils

Router scripts run against BusyBox applets. Notably **there is no `timeout`
applet** - see `bounded_nslookup` in `ikev2-domain-router.sh` for the pattern
used instead. `od` and `stat` are absent too. Use `date -r FILE +%s` for file
modification time on the supported router; lock recovery must work without
`stat`. A GNU-only option passes every check on a developer machine and behaves
differently on the router.

Guarded by `scripts/check-busybox-compat.sh`; extend it rather than relying on
review.

## Reading the whole system log costs seconds

`logread` with no options formats the entire ring buffer, which on a router
with a busy log is a hundred thousand lines and four to five seconds of CPU.
The quality sample did that every minute to find reconnects, and the
watcher's cost looked like its own loop. Read the last messages with
`logread -l N`, or let logread filter with `-e PATTERN`, and measure a
periodic check by its CPU time, not by how many processes it starts.

## BusyBox sleep takes whole seconds

`sleep 0.2` fails with "invalid number" on the router; a wait loop built on
it spins or stops at once, and every developer shell accepts it.

Guarded by `scripts/check-busybox-compat.sh`.

## ash scopes variables dynamically

A function that assigns a name without `local` writes into whichever caller
has a variable of that name, and validators are called directly inside
conditions, not in a `$(...)` subshell. `dns_segment_update` kept its chosen
protocol in a local `protocol`; `valid_dns_endpoint_any` assigned its own, and
the segment was stored with the scheme of the last endpoint validated. The
caller looked correct, the validator looked correct, and the stored value was
wrong.

Guarded by `scripts/check-shell-locals.sh`, which requires every variable a
validator or small helper assigns to be declared local.

## Restore what you changed, not the file

A snapshot of a whole configuration file restored months later puts back
everything that was in it and erases everything added since. Disabling managed
DNS and removing dependencies both copied `/etc/config/dhcp` from the moment
they were first enabled, and every static lease added after that was lost.
Record and restore only the options the application writes; keep whole-file
snapshots for rollbacks within one transaction.

Guarded by `scripts/test-dhcp-preservation.sh`.

## A service start must not re-render its configuration

`ikev2-domain-router` rendered its sing-box configuration from UCI on every
start. A failed refresh put the previous configuration back and restarted the
service - and the start rendered the failed one again, while the status said
the previous rules were restored. A start runs what was last validated; every
change path renders and checks before it restarts. Because a start no longer
re-renders, a rule refresh compares the running configuration with a fresh
render and falls back to a full refresh when they differ.

Guarded by `scripts/test-fakeip-restart.sh`.

## BusyBox sort ignores the options it does not have

The router's `sort` knows `-n`, `-r`, `-u`, `-s` and `-z`. Given `-t` or
`-k` it does not fail: it drops them and sorts whole lines as text, so a
device list sorted with `-t . -k1,1n` came out as `10.0.0.10` before
`10.0.0.9` for as long as it existed, and every GNU test passed. Its `-n` also
overflows past 2^31, so a 32-bit address as one number sorts wrongly too. Sort
by a zero-padded text prefix and cut it off afterwards.

Guarded by `scripts/check-busybox-compat.sh`.

## BusyBox grep matches every line against an empty pattern file

`grep -f FILE` with an empty FILE matches nothing in GNU grep and every line
in BusyBox grep, so `grep -v -f` of a list that holds nothing yet prints
nothing at all. The networks of each exit were filtered that way against what
the exits before it had taken; with one tunnel nothing had been taken, and
every service network was dropped. The names of a service still went through
the tunnel while the addresses its application connects to did not, which
read as Telegram loading badly, not as a routing fault, and every test passed
because they run GNU or BSD grep. Filter a list against a file with awk, and
refuse a result that is empty where the input was not.

Guarded by `scripts/check-busybox-compat.sh` and `scripts/openwrt/scenarios.sh`.

## `with_lock` takes a function, not a command line

`with_lock` runs its first argument as a shell function. Writing
`with_lock pause pause_routing` makes the shell look for a program named
`pause`. Pinned by a check that every `with_lock` target is a function defined
in the same file.

## nftables reads its own output back differently

A rule written as `!= 0` is listed back as `!= 0x00000000`, and a mask gains
the bit its OR sets. A check that compares the listed rule to the written
string reports a healthy runtime as missing. Device routing, the inbound user
policy and the policy routing record the fingerprint of `nft -j list table`
right after installing (`runtime_fingerprint` in `lib/nft-runtime.sh`) and
compare later listings with that, never with what they wrote. The inbound
policy keeps its named fail-closed checks as well: a fingerprint accepts
whatever was installed, including a table the generator got wrong.

## sing-box refuses a field it does not know

sing-box decodes its configuration strictly: one unknown key and the whole
document is refused. The generator asked the cache to keep each selector's
choice with a key that does not exist, and only with more than one tunnel, so
every test and the one-tunnel router passed. Adding a second tunnel ended in
"applying them failed" and each list rebuild after it in "Community update
failed". A test that reads the rendered document cannot see this; the document
has to be given to sing-box. With the cache enabled a selector's choice is
stored without being asked for.

Guarded by `scripts/openwrt/scenarios.sh`, which runs `sing-box check` on the
configuration of one tunnel and of several.

## Health is measured against what was applied, not what was saved

Settings can be saved and their apply fail, which leaves the resolver running
the previous configuration. The listener check took the inbounds it expected
from the settings, found those of the new tunnel missing, and the watcher
restarted the resolver on every pass: a restart loads the same file, so it
never helped, and each one cut every routed connection. A check that leads to
a restart must ask only for what a restart can bring up - what the
configuration on disk declares. The pending change belongs to the apply that
failed, which says so.

Guarded by `scripts/test-domain-validation.sh`.

## The health watcher will undo what you just did

`ikev2-health` repairs the FakeIP runtime on its own schedule. Any state change
that looks like breakage - pausing routing, for instance - has to be visible to
the watcher, or it is reverted within seconds and the failure appears to come
from nowhere. Keep such guards ahead of the repair, not after it.

## Two build paths ship the package

`scripts/stage-package.sh` builds locally; the release workflow builds from the
SDK `Makefile`. Anything that must reach a router has to be installed by
**both**. The version stamp was added to the packer only, so every release from
1.7.0 to 1.8.0 shipped without it and the page reported an unknown version.

Guarded by `scripts/check-version-sync.sh`.

## A released tag does not reach the routers

`OPENWRT_FEED_DISPATCH_TOKEN` is not configured, so the release workflow's feed
notification step reports success while the dispatch never arrives. Until the
secret exists, the feed must be rebuilt by hand after every tag:

```
gh workflow run "Build feed" --repo Nikitid/openwrt-feed
```

`scripts/release.sh` does this as part of the sequence.

## Verify the page, not the parse

A syntactically valid LuCI view can still die at render: a helper that is not
exported, a control built before its dependency, an option read from the wrong
module. Every command-line check passes while the page shows nothing. The
render harnesses under `scripts/` stub the LuCI environment and actually call
`render()`; add a page to them when you add a page.

## Conntrack deletion does not close a userspace proxy connection

An established TProxy socket can continue on the old outbound after conntrack
is deleted. On the supported kernel, `ss -K` returned success without closing
the socket. Device changes therefore use sing-box's authenticated loopback API
to close matching source connections before clearing conntrack. Test an active
connection and an unrelated control connection; exit status alone proves
neither closure nor isolation.

Guarded by `scripts/test-audit-regressions.py` and router data-plane checks.

## Routes into an XFRM link need the link up first

`ip route add ... dev ipsec-out` fails with "Device for nexthop is not up" on a
link that is down. Turning managed mode off, or disabling the inbound server,
leaves `ipsec-out` or `ipsec-in` down, so a later apply that installed the
tunnel table before `/etc/init.d/ikev2-xfrm start` failed and rolled back:
managed mode or the server could not be turned back on. Start the XFRM links
before any routing sync, in every apply path.

## A disabled inbound server leaves `ipsec-in` in place

Deleting an XFRM link can block in the kernel on OpenWrt 25, so `ikev2-xfrm`
only takes it down. A check that required the link to be gone failed every
server disable and the rollback after it, which then reported that the
rollback failed. Test the `UP` flag, not the link's existence.

Guarded by `scripts/openwrt/scenarios.sh`.

## Removing the app stops FakeIP before it restores DNS

Restoring the original DNS while FakeIP ran re-pointed sing-box at it after the
segment resolvers were stopped; sing-box still sent `.ru` to the stopped
segment, the probe failed, and the reset refused. The reset deactivates FakeIP
first and restores DNS without it.


## Inbound clients get no NAT reflection

A LAN service published through a WAN DNAT is reachable from the LAN by its
public name because fw4 generates reflection rules. Those rules match only the
source zone of the redirect's destination (`iifname br-lan`, `saddr` of the LAN
subnet). An inbound IKEv2 client arrives on `ipsec-in`, is not reflected, and
its connection to the WAN address lands on the router itself, where the
inbound router-access rule admits it. On port 443 that is uhttpd, so the
client sees a certificate for the wrong name and reports a TLS error, which
reads like a certificate or proxy fault.

Resolve the published names to the LAN address in the router resolver
(`uci` `dhcp` `domain` entries) rather than extending `reflection_zone`: the
traffic then stays inside, the proxy sees the real client address, and it
keeps working while WAN is down. Keep the IKE server name on its public
address.

## Turning managed mode off must not change what turning it on restores

Disabling used `ikev2-domain-router deactivate`, which rewrites the engine to
`nftset`, and stopped the segment resolvers; enabling brought neither back, so
the router came back matching by address with its segments down. Disabling
now uses `shutdown`, which keeps the engine, and enabling restarts the
segments and resumes FakeIP.

## BusyBox awk reads a gsub replacement's backslashes its own way

`gsub(/"/, "\\\"")` puts a backslash before the quote in macOS and GNU awk.
BusyBox awk drops it, so a JSON profile went out with a password's quote and
backslash unescaped - and every test passed, because they run on the
developer's awk. Escape character by character with `substr`, as
`xml_escape` and `json_escape` in `lib/manager-profiles.sh` do.

Guarded by `scripts/openwrt/scenarios.sh`.

## dnsmasq's servers file is a bind mount in its jail

OpenWrt starts dnsmasq in ujail and mounts the `serversfile` option's file
into it by itself. Writing a new file and moving it over the old one - the
usual atomic update - replaces the name outside the jail only: dnsmasq goes on
reading the inode it was given, HUP rereads the old list, and nothing reports
an error. The file is rewritten in place (`cat new >file`), and it lives
outside `/etc/ikev2-manager`, which the `dnsmasq` account cannot enter when
there is no jail. HUP also empties dnsmasq's cache, so a list change sends it
only after sing-box has loaded the new rules; told earlier, dnsmasq caches the
real addresses sing-box still gives.

Guarded by `scripts/openwrt/scenarios.sh`, with the real init script and dnsmasq.

## A Windows VPN profile does not prove an active route

The selected /32 routes can be present in the all-user VPN profile while a
native RAS connection does not publish them in the active routing table. A
connected SA and profile inspection both pass, but ordinary traffic still
selects another interface. The desktop controller creates owned active-store
routes only after identifying its RAS interface, keeps destination denials
throughout, and checks the unconstrained best route before accepting connection
readiness. Remove only unchanged rows belonging to that connection.

Docker's published-port listing is also not evidence that an IKE listener is
reachable: a host-side privileged UDP bind can fail after the container starts.
Use packet evidence and host forwarding errors before changing authentication.

## A packet mark does not survive from prerouting to input

Managed desktop access marked an admitted packet in prerouting and required the
mark again at input. On a container router every check passed. On a router
with Tailscale the first packet of each connection got through and everything
after it was dropped: Tailscale's mangle prerouting chain restores the
connection mark over the **whole** packet mark for established flows
(`ct state established,related meta mark set ct mark & 0x0000ff00`), between
the two hooks.

What made this expensive: a TCP connect succeeded and the client showed
"protected", so it looked like a TLS or proxy fault. Only the path table's
input counter showed the drops.

The rule: a mark set in one hook is not evidence in the next. Decide again in
each hook where the mark is read. `client-access-authorization.uc` has an
input chain for this, and `scripts/openwrt/client-path.sh` installs a foreign
mark rewrite to keep it honest. A stand without other packages' rules cannot
find this class of fault; one run on a real router did.

## A loop that waits on its own pipe outlives its helpers

The inbound policy watcher read events from a FIFO that it held open itself,
and two helpers wrote to it: the VICI monitor wrapper and a timer. A helper
that ends on a signal exits through its trap and writes nothing. With both
gone the watcher blocked in `read` for ever - no end of file, because its own
descriptor kept the pipe open. procd saw a live process, the health check saw
a stale session file, and clients stayed closed until the service was
restarted by hand.

What made this expensive: the process was there, its PID unchanged for days,
and nothing was logged. It looked like a lost event, not a dead producer.

The rule: a loop must not depend on a helper to wake it. The watcher now waits
with `read -t`, runs its periodic pass by the clock and checks the event source
for life every time the wait runs out. `scripts/test-user-policy.sh` ends the
source with a signal and requires the watcher to exit.

## A counted repetition in a ucode pattern costs milliseconds on a router

Registration on a router with ten remote devices began to fail with 502, and
only from one of two machines. The device API ran out of the web server's five
seconds per request. The time went into validating names: ucode compiles a
regular expression each time it is evaluated, and the router's regex library
expands a counted repetition state by state. `/^[a-z][a-z0-9-]{0,47}$/` took
2.3 ms per match, `/…{0,127}$/` 22 ms; the same pattern with `*` took 0.06 ms.
A registration validates the whole state several times, every name in it.

What made this expensive: it passed for hours and then failed every time, with
no change to the code - only the number of devices in the state had grown. On
a development machine the same patterns cost microseconds, so no test showed
it, and the client reported nothing because the reason was overwritten.

The rule: bound the length with `length()` and write the repetition as `*` or
`+`. `scripts/check-ucode-regex.sh` refuses a count of 16 or more.
