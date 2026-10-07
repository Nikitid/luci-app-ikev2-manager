# Repository map

Where things live, so a task starts at the right file instead of a search.

Read this first; read `docs/ARCHITECTURE.md` only for the section you need, and
`docs/OPERATIONS.md` only when running something against a router.

## The shape of it

One OpenWrt package, `luci-app-ikev2-manager`, containing three things:

- **runtime** - POSIX shell helpers under `/usr/libexec`, driven by procd init
  scripts and by the LuCI pages through rpcd; structured data (strongSwan SA
  snapshots, the sing-box configuration, installed nftables tables) is read
  and written by ucode scripts in `ikev2-manager-runtime/lib/*.uc`
- **LuCI pages** - six views plus a status-overview widget, all built on one
  shared design system rather than stock CBI
- **checks** - 66 scripts under `scripts/`, run as one suite by
  `scripts/ci-check.sh`; `scripts/ensure-ucode.sh` builds the pinned ucode
  release they need when none is installed (git, cmake, json-c headers); `scripts/test-openwrt.sh` installs the package into official OpenWrt
  24.10 and 25.12 rootfs containers and runs `scripts/openwrt/scenarios.sh`
  on real BusyBox, uci, nft and ip (Docker; its own CI job), then
  `scripts/openwrt/failover.sh`: two tunnels to two strongSwan servers in
  network namespaces, failover and return with real traffic. That one needs
  the kernel's XFRM interfaces, which CI has and OrbStack does not; without
  them it says it was skipped

One sibling repository, not in this tree: `openwrt-feed` (the shared signed
feed every router installs from).

## Runtime helpers

Installed to `/usr/libexec`, called by init scripts and by LuCI through the
rpcd `file exec` ACL in `luci-ikev2-manager/acl.json`.

| helper | source | owns |
| --- | --- | --- |
| `ikev2-manager-system` | `ikev2-manager-runtime/ikev2-manager-system.sh` | system state, dependencies, DNS transactions, DNS segments, device policy, routing pause, the redacted diagnostics report (`lib/system-diagnostics.sh`) |
| `ikev2-manager` | `luci-ikev2-manager/ikev2-manager.sh` | inbound server, VPN users, ACME, client profile, the outbound tunnels and their passwords (`lib/manager-tunnels.sh`), raw swanctl config |
| `ikev2-domain-router` | `ikev2-manager-runtime/ikev2-domain-router.sh` | sing-box FakeIP engine, tunnel DNS, nftables rules |
| `ikev2-device-routing` | `ikev2-manager-runtime/ikev2-device-routing.sh` | per-device policy marks and their nft chains |
| `ikev2-client-admin` | `ikev2-manager-runtime/ikev2-client-admin.sh` | redacted LuCI overview and queued catalog/assignment edits |
| `ikev2-client-catalog` | `ikev2-manager-runtime/ikev2-client-catalog.sh` | periodic publication of client-selected service domain updates |
| `ikev2-client-api` | `ikev2-manager-runtime/ikev2-client-api.sh` | dedicated TLS-only client API, protected certificate validation and process lifetime |
| `ikev2-client-enrollment` | `ikev2-manager-runtime/ikev2-client-enrollment.sh` | bounded background credential provisioning and disabled publication |
| `ikev2-client-access` | `ikev2-manager-runtime/ikev2-client-access.sh` | committed desktop assignments, bounded VICI reconciliation and leased SA-bound admission |
| `ikev2-user-policy` | `ikev2-manager-runtime/ikev2-user-policy.sh` | inbound session admission, driven by VICI events |
| `ikev2-health` | `ikev2-manager-runtime/ikev2-health.sh` | the watcher loop: the tunnel of each exit (`lib/tunnel.sh`, which also numbers the tunnels for every helper), FakeIP repair and data-plane canary, tunnel DNS failover |
| `ikev2-tunnel-quality` | `ikev2-manager-runtime/ikev2-tunnel-quality.sh` | tunnel quality history, window summaries, tunnel-versus-WAN speed test |
| `ikev2-devices` | `luci-ikev2-domains/ikev2-devices.sh` | LAN inventory the pages read |
| `ikev2-domains-community` | `luci-ikev2-domains/community-domains.sh` | service catalogue and destination lists |
| `ikev2-sync-vips` | `ikev2-manager-runtime/ikev2-sync-vips.sh` | virtual IP reconciliation |
| `ikev2-routing` | `ikev2-manager-runtime/ikev2-routing.sh` | the application's own policy routing, the only routing it does; `sync-all` also syncs device routing and Discord voice |
| `ikev2-sa` | `ikev2-manager-runtime/ikev2-sa.sh`, `lib/sa.uc` | every question about active SAs, from a bounded `swanmon list-sas` |
| `ikev2-discord-voice` | `ikev2-manager-runtime/ikev2-discord-voice.sh` | Discord voice range handling |

Init scripts in `ikev2-manager-runtime/*.init`: `ikev2-domain-router`,
`ikev2-dns-segments`, `ikev2-health`, `ikev2-user-policy`, `ikev2-client-access`,
`ikev2-xfrm`.

The managed desktop access modules `client-access*.uc` compile individual
policies, retain publication history, serve a read-only device API and compile
SA-bound authorization. `client-access-control.uc` is the local administrative
publication entry point, including redacted inspection and catalog-backed administrative edits.
`client-access-admin.uc` retains credentials and assignment history during those edits.
Enrollment remains a separate gate;
`client-access-enrollment.uc` prepares one-use invitation transitions and disabled
device proposals; `client-access-enrollment-store.uc` journals them durably.
`client-access-invitation.uc` issues random server-bound invitation links through
a root-only command with private output. The
dedicated HTTPS claim/poll endpoints now connect to a bounded background worker;
`client-access-credentials.uc` stages protected EAP credentials and drives the
existing user transaction. Only authenticated enrollment polling can read the
initial credential bundle; administrative and ordinary policy APIs cannot.
Permanent HTTPS deployment, activation and native enrollment remain verification gates. Manager
user mutations use a shared kernel guard and an internal owned-user operation.
see `docs/CLIENT_ACCESS.md`. `scripts/openwrt/client-ike.sh` verifies real
certificate/EAP login, VICI admission and encrypted selected-service TCP/UDP in
isolated namespaces. Its optional `client-path.sh` extension verifies a real
IKE exit, compiled dedicated proxy, encrypted DNS and existing inbound user policy;
it also exercises automatic proxy activation, recovery and route ownership.
Native Windows HTTPS enrollment and automatic policy refresh have an integrated
SCM/OpenWrt scenario. Windows build.ps1 builds the service, the window and the single-file
Setup that installs, updates and removes them; ManagedVpnProfile owns the split
IKEv2 entry and selected /32 routes after persistent guard staging, and
GuardRuntime opens the tunnel interface only while the router's readiness
endpoint confirms the path. `scripts/openwrt/client-desktop.sh` is the
disposable router for the complete desktop scenario and
`scripts/openwrt/client-setup.sh` the first-activation scenario; activation
itself is `lib/client-access-setup.uc` behind `ikev2-client-admin`. The macOS
client is the Swift package in `desktop-clients/macos`: `ClientCore` (runtime
behind `SystemActions`), the root daemon, the window and `build.sh` for the
installer package; the inbound server answers managed devices on
`ikev2-in-managed` (`lib/manager-server.sh`, `scripts/openwrt/client-managed.sh`).
Names under a service are `client_names_plan` in `lib/client-access.uc`, the
proxy rules in `lib/client-access-path.uc` and the per-service source sets
written by `client-access-path-control.uc sources`; the device directory is
`lib/client-access-directory.uc`. `scripts/check-ucode-regex.sh` forbids the
counted repetitions that made registration slow on a router.

## LuCI pages

Each view is one file. The menu points at the installed resource name, which
carries a version suffix: LuCI's cache key does not move when the package is
upgraded, so a stable name would serve stale code to the browser.

| page | source | installed as |
| --- | --- | --- |
| Overview | `luci-ikev2-manager/setup.js` | `view/ikev2-manager/setup-v13.js` |
| Outbound Tunnel | `luci-ikev2-manager/client.js` | `view/ikev2-manager/client-v13.js` |
| Policy Routing | `luci-ikev2-domains/editor.js` | `view/ikev2-domains/editor-v12.js` |
| Inbound Server | `luci-ikev2-manager/settings.js` | `view/ikev2-manager/settings-v10.js` |
| Remote clients | `luci-ikev2-manager/remote-clients.js` | `view/ikev2-manager/remote-clients-v2.js` |
| VPN Users | `luci-ikev2-manager/users.js` | `view/ikev2-manager/users-v15.js` |
| Status widget | `luci-ikev2-manager/status-widget.js` | `view/status/include/06_ikev2-manager.js` |

`luci-ikev2-manager/shared.js` is the design system and the action lifecycle
used by all of them; it installs as `shared-v14.js`. Russian strings live in
`po/ru/ikev2-manager.po`, compiled by `scripts/po2lmo.py` into
`/usr/lib/lua/luci/i18n/ikev2-manager.ru.lmo`, which LuCI's own `_()` reads.
`luci-ikev2-manager/menu.json` wires the pages, `acl.json` grants every helper
call and input-file write.

## Configuration

- `openwrt/files/etc/config/ikev2-manager` - packaged defaults, installed to
  `/usr/share/ikev2-manager/defaults/` and merged on install
- UCI sections: `client`, `server`, `domains`, `dns`, `dnsseg_*` (one per DNS
  segment), `device_*` (one per device override)

## Checks

`scripts/ci-check.sh` runs everything. Two families:

- `scripts/check-*.sh` - invariants that hold regardless of behaviour: version
  sync, public tree, pinned actions, BusyBox compatibility, the LuCI UI
  contract, the rpcd ACL coverage, the README layout
- `scripts/test-*.sh` and `scripts/test-*.js` - behaviour, run against stubbed
  UCI and a stubbed LuCI environment

A new check is mutated before it is trusted: break what it guards, watch it
fail, restore. Wire it into `scripts/ci-check.sh`, or nothing runs it.

## Build and release

- `release.env` - the single source of package identity; the SDK `Makefile`
  repeats the literals and `scripts/check-version-sync.sh` fails on drift
- `scripts/build-ipk.sh` -> `scripts/stage-package.sh` -> `scripts/pack-ipk.py`
  is the local build; the release workflow builds from the SDK `Makefile`
  instead, so anything that must ship has to be in **both**
- `scripts/release.sh` - tag, watch the release, rebuild the feed, install
- `scripts/deploy-luci.sh` - push page assets to one router without a release
- `scripts/health-check.sh` - read-only sweep across routers
- `scripts/kuma-push.sh` - runs on a router from cron and reports each
  subsystem to Uptime Kuma push monitors; read-only

## Documentation

| file | for |
| --- | --- |
| `docs/MAP.md` | this file |
| `docs/TRAPS.md` | failures that cost hours and will repeat |
| `docs/ARCHITECTURE.md` | traffic paths, fail-closed boundary, several tunnels, DNS, ownership |
| `docs/OPERATIONS.md` | installing, diagnosing and recovering on a router |
| `docs/OPENWRT25.md` | apk, the signed feed, release validation |
| `docs/CLIENT_ACCESS.md` | managed desktop access implementation and verification gates |
| `docs/private/` | site-specific runbooks, untracked on purpose |
