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
- **LuCI pages** - five views plus a status-overview widget, all built on one
  shared design system rather than stock CBI
- **checks** - 66 scripts under `scripts/`, run as one suite by
  `scripts/ci-check.sh`; `scripts/ensure-ucode.sh` builds the pinned ucode
  release they need when none is installed (git, cmake, json-c headers); `scripts/test-openwrt.sh` installs the package into official OpenWrt
  24.10 and 25.12 rootfs containers and runs `scripts/openwrt/scenarios.sh`
  on real BusyBox, uci, nft and ip (Docker; its own CI job)

One sibling repository, not in this tree: `openwrt-feed` (the shared signed
feed every router installs from).

## Runtime helpers

Installed to `/usr/libexec`, called by init scripts and by LuCI through the
rpcd `file exec` ACL in `luci-ikev2-manager/acl.json`.

| helper | source | owns |
| --- | --- | --- |
| `ikev2-manager-system` | `ikev2-manager-runtime/ikev2-manager-system.sh` | system state, dependencies, DNS transactions, DNS segments, device policy, routing pause |
| `ikev2-manager` | `luci-ikev2-manager/ikev2-manager.sh` | inbound server, VPN users, ACME, client profile, raw swanctl config |
| `ikev2-domain-router` | `ikev2-manager-runtime/ikev2-domain-router.sh` | sing-box FakeIP engine, tunnel DNS, nftables rules |
| `ikev2-device-routing` | `ikev2-manager-runtime/ikev2-device-routing.sh` | per-device policy marks and their nft chains |
| `ikev2-user-policy` | `ikev2-manager-runtime/ikev2-user-policy.sh` | inbound session admission, driven by VICI events |
| `ikev2-health` | `ikev2-manager-runtime/ikev2-health.sh` | the watcher loop: FakeIP repair and data-plane canary, tunnel DNS failover |
| `ikev2-tunnel-quality` | `ikev2-manager-runtime/ikev2-tunnel-quality.sh` | tunnel quality history, window summaries, tunnel-versus-WAN speed test |
| `ikev2-devices` | `luci-ikev2-domains/ikev2-devices.sh` | LAN inventory the pages read |
| `ikev2-domains-community` | `luci-ikev2-domains/community-domains.sh` | service catalogue and destination lists |
| `ikev2-sync-vips` | `ikev2-manager-runtime/ikev2-sync-vips.sh` | virtual IP reconciliation |
| `ikev2-routing` | `ikev2-manager-runtime/ikev2-routing.sh` | the application's own policy routing (replacing PBR; off unless `globals.routing_backend` selects it) |
| `ikev2-sa` | `ikev2-manager-runtime/ikev2-sa.sh`, `lib/sa.uc` | every question about active SAs, from a bounded `swanmon list-sas` |
| `ikev2-discord-voice` | `ikev2-manager-runtime/ikev2-discord-voice.sh` | Discord voice range handling |

Init scripts in `ikev2-manager-runtime/*.init`: `ikev2-domain-router`,
`ikev2-dns-segments`, `ikev2-health`, `ikev2-user-policy`, `ikev2-xfrm`.

## LuCI pages

Each view is one file. The menu points at the installed resource name, which
carries a version suffix: LuCI's cache key does not move when the package is
upgraded, so a stable name would serve stale code to the browser.

| page | source | installed as |
| --- | --- | --- |
| Overview | `luci-ikev2-manager/setup.js` | `view/ikev2-manager/setup-v7.js` |
| Outbound Tunnel | `luci-ikev2-manager/client.js` | `view/ikev2-manager/client-v7.js` |
| Policy Routing | `luci-ikev2-domains/editor.js` | `view/ikev2-domains/editor-v8.js` |
| Inbound Server | `luci-ikev2-manager/settings.js` | `view/ikev2-manager/settings-v7.js` |
| VPN Users | `luci-ikev2-manager/users.js` | `view/ikev2-manager/users-v11.js` |
| Status widget | `luci-ikev2-manager/status-widget.js` | `view/status/include/06_ikev2-manager.js` |

`luci-ikev2-manager/shared.js` is the design system and the action lifecycle
used by all of them; it installs as `shared-v11.js`. Russian strings live in
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
| `docs/ARCHITECTURE.md` | traffic paths, fail-closed boundary, DNS, ownership |
| `docs/OPERATIONS.md` | installing, diagnosing and recovering on a router |
| `docs/OPENWRT25.md` | apk, the signed feed, release validation |
| `docs/private/` | site-specific runbooks, untracked on purpose |
