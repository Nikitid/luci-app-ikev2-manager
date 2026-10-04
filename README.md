# IKEv2 Manager for OpenWrt

[Русский](README.ru.md)

[![CI](https://github.com/Nikitid/luci-app-ikev2-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/Nikitid/luci-app-ikev2-manager/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Nikitid/luci-app-ikev2-manager)](https://github.com/Nikitid/luci-app-ikev2-manager/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

The `luci-app-ikev2-manager` package is a LuCI application for an outbound IKEv2
tunnel, an inbound IKEv2 server and selective IPv4 routing on OpenWrt. It can
use [IKEv2 Manager for Ubuntu](https://github.com/Nikitid/ikev2-ubuntu) as the
remote gateway.

![IKEv2 Manager overview page](docs/images/overview.png)

## Features

- outbound IKEv2/EAP client over an XFRM interface, with up to seven tunnels
  that stand in for each other;
- VPN routing for services, domains, IPv4 addresses and CIDR networks, each
  service, manual list and full-route device through the tunnel chosen for
  it, free to move to another tunnel or bound to its own;
- per-device modes for selected domains, full tunnel or direct WAN, independent
  DNS/DPI bypasses and a fully unmanaged preset;
- FakeIP/TProxy domain routing and its own fail-closed policy routing, with
  no dependency on the pbr package;
- inbound IKEv2/EAP server with global and per-user access to the router,
  selected public router ports, Internet and selected local IPv4 destinations;
- Status Overview widget for the outbound tunnel, policy routing and active
  inbound VPN clients;
- DNS upstream over UDP, TCP, DoT, DoH, HTTP/3, DoQ or DNSCrypt, including
  independent resolver groups for explicit domain suffixes;
- destinations that never go through the tunnel, by domain or address, which
  win over every selected service, optionally also for full-route devices;
- inbound client profiles for Apple, Android (strongSwan app) and Windows
  VPNv2/NRPT, including a reusable Windows setup application plus separate
  VPNv2 XML profiles, with no PowerShell, and a one-time QR link that installs
  the phone profile without a file on the computer;
- an encrypted settings backup that restores on the same router or moves to
  another, which keeps its own networks;
- ACME and Russian/English LuCI interfaces.

## Requirements

- official OpenWrt `24.10.x`;
- firewall4/nftables, IPv4 WAN and official package feeds;
- storage for strongSwan, sing-box, `dnsmasq-full` and `dnsproxy`.

OpenWrt `25.12.x` support is experimental and limited to the validated
`mediatek/filogic` and `aarch64_cortex-a53` targets. Vendor firmware, snapshots
and firewall3 are not supported.

## Installation

### OpenWrt 24.10

Download the latest `luci-app-ikev2-manager_*_all.ipk` from
[Releases](https://github.com/Nikitid/luci-app-ikev2-manager/releases) and upload
it through:

```text
System -> Software -> Upload Package
```

Then open:

```text
Services -> IKEv2 Manager -> Overview
```

Install the dependencies, select the WAN and protected networks, enable
managed mode and configure the tunnel. CLI installation, migration and
recovery are covered in [Operations](docs/OPERATIONS.md).

### OpenWrt 25.12

```sh
wget -O /tmp/nikitid-feed.sh \
  https://raw.githubusercontent.com/Nikitid/openwrt-feed/feed/install.sh
sh /tmp/nikitid-feed.sh luci-app-ikev2-manager
```

The installer verifies the release public key and registers the shared signed
stable APK repository for Nikitid OpenWrt applications without redirects. The
legacy key and `/etc/apk/repositories.d/ikev2-manager.list` path remain
compatible. If the application was installed before version `1.1.9`, run these
two commands once more: the installer upgrades the package and moves the
existing installation to the stable repository.

Later updates:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```

This upgrades only IKEv2 Manager, not all system packages.

## Policy routing

Domain rules use sing-box FakeIP and nftables TProxy. IPv4 and CIDR rules work
without DNS. If the outbound tunnel is unavailable, selected traffic is
blocked while unrelated traffic continues through WAN.

With more than one tunnel, every enabled tunnel stays connected. When the
tunnel of a service is down, or connected while nothing passes through it,
its traffic moves to the next tunnel that is up within a minute and returns
two minutes after its own tunnel is back. A service that must not leave from
another country is bound to its tunnel instead: it is blocked while that
tunnel is down. Nothing falls back to WAN: with no tunnel up it is blocked.
Moving a service to another tunnel closes that service's open connections
and leaves every other one alone.

Clients must use router DNS for domain routing. Browser DoH and Android
Private DNS can bypass classification. In Reliable mode the router answers the
names Firefox and Apple publish for this purpose as missing, so Firefox keeps
the router resolver and iCloud Private Relay is turned off on this network.

## Domain lists

Project lists are stored in `luci-ikev2-domains/local-services/`. Optional
lists are downloaded from
[`itdoginfo/allow-domains`](https://github.com/itdoginfo/allow-domains) and are
not included in the IPK. See [NOTICE](NOTICE) for their terms. Zoom Meetings
networks come from Zoom's official list instead and merge with the bundled
snapshot.

## Development

```sh
./scripts/ci-check.sh
```

The signed feed and release validation: [docs/OPENWRT25.md](docs/OPENWRT25.md).

## Documentation

- [Repository map](docs/MAP.md) - where things live
- [Traps](docs/TRAPS.md) - failures that already cost hours
- [Architecture](docs/ARCHITECTURE.md)
- [Operations](docs/OPERATIONS.md)
- [OpenWrt 25.12 and apk](docs/OPENWRT25.md)
- [Shared APK feed](https://github.com/Nikitid/openwrt-feed/blob/main/docs/MEMBER_INTEGRATION.md)

## Support

Questions and bug reports go to
[Issues](https://github.com/Nikitid/luci-app-ikev2-manager/issues/new/choose): pick the form that
fits, and attach the report from **Download report** on the Overview page,
under Runtime dependencies: passwords, keys and tokens are left out of it, and
public and MAC addresses and host and user names are replaced. Read it first.
Report a vulnerability privately through
[a security advisory](https://github.com/Nikitid/luci-app-ikev2-manager/security/advisories/new).
English or Russian is fine.

## License

[MIT](LICENSE). Optional downloaded lists are described in [NOTICE](NOTICE).
