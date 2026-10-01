# OpenWrt 25.12 and apk

The `main` branch builds one application source tree for both supported package
manager lines:

- OpenWrt `24.10.x` with `opkg` and IPK packages;
- OpenWrt `25.12.x` with apk-tools 3 and APK packages.

A permanent platform branch is not required. Package-manager differences are
kept behind the runtime package abstraction and release builders; changes are
merged only after the IPK checks and the target-specific APK build pass.

## Compatibility boundary

The runtime accepts only official release builds with firewall4 and matching
official feeds. Vendor firmware, snapshots, firewall3, a mismatched package
manager and non-release feeds fail before dependency installation.

APK artifacts contain a target-specific architecture and are coupled to the
OpenWrt kernel ABI through their kmod dependencies. Build and publish one APK
feed for every validated target/architecture and OpenWrt 25.12 release. A minor
OpenWrt update normally needs a rebuild and smoke test when its kernel ABI or
package indexes change; LuCI and shell code do not need a separate fork.

The currently validated OpenWrt 25 target is:

- OpenWrt `25.12.5`;
- `mediatek/filogic`;
- `aarch64_cortex-a53`;
- GL.iNet Flint 2 running official OpenWrt.

Other targets remain unsupported until the same SDK build, dependency-plan and
router validation sequence succeeds for their exact package feeds and kernel
ABI.

## Implemented support

- package-manager abstraction for `opkg` and apk-tools 3;
- release/feed and persistent-storage preflight checks;
- exact installed-version and dnsmasq-provider detection;
- trusted-feed `dnsmasq-full` replacement with solver-backed rollback;
- application-owned package tracking and baseline restoration;
- retention of packages still required by unrelated software;
- exact dnsmasq nftset capability validation;
- reproducible APK builds with the official OpenWrt 25.12 SDK;
- a shared P-256 release key, signed APKs and signed `packages.adb` indexes;
- a rollback-safe one-time bootstrap for the GitHub Release feed;
- live validation of preflight, install, doctor, managed enable/disable,
  Reliable mode, policy routing rebuild, DNS rollback and guarded dependency removal.

## Shared signed feed

The signed feed lives in its own repository, `Nikitid/openwrt-feed`. This
project builds and signs only its own package and publishes it as a GitHub
Release asset; the feed repository collects the current release of every member
application, verifies the signatures and publishes the signed index. Ownership
and publishing are described by the feed itself, in
[Joining the shared feed](https://github.com/Nikitid/openwrt-feed/blob/main/docs/MEMBER_INTEGRATION.md).

The first OpenWrt 25.12 installation uses the feed bootstrap:

```sh
wget -O /tmp/nikitid-feed.sh \
  https://raw.githubusercontent.com/Nikitid/openwrt-feed/feed/install.sh
sh /tmp/nikitid-feed.sh luci-app-ikev2-manager
```

The script checks the exact OpenWrt release, target and architecture, verifies
the publisher public-key checksum, installs the key under `/etc/apk/keys/`,
registers the signed feed, refreshes indexes and simulates the package
transaction before installation or upgrade. A failed bootstrap restores the
previous key and feed state.

One publisher key covers every application in the feed, so a router holds a
single trust anchor and a single feed entry. Installations made before the feed
moved are migrated by the package itself.

Older local APK installations can leave an identity-hash constraint in
`/etc/apk/world`. The bootstrap replaces only that application's constraint
before the scoped package upgrade and restores it if the transaction fails. It
does not run a system-wide package upgrade.

Later updates use the normal package manager:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```

Direct LuCI upload of an APK signed only by an unknown project key fails with
`UNTRUSTED signature`. The one-time bootstrap is therefore required before
LuCI or `apk` can install and update project packages normally.

## Release validation

For every OpenWrt 25.12 update or newly supported target:

1. build the APK and signed index with the exact official SDK;
2. verify architecture, SDK identity, signatures and deterministic output;
3. run bootstrap and dependency-plan simulation against current feeds;
4. run `preflight`, dependency installation and `doctor` on the target;
5. test DNS apply/rollback, managed enable/disable, Reliable mode and policy
   routing rebuild;
6. test full dependency reset and confirm ordinary WAN/DNS remains available;
7. reboot once and repeat `doctor` plus inbound/outbound smoke tests.
