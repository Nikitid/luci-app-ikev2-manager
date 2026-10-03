#!/bin/sh

# Runs scripts/openwrt/scenarios.sh inside official OpenWrt rootfs containers,
# one per supported release, with the package built from this tree installed.
# Needs Docker; NET_ADMIN lets nft and ip work in the container's own network
# namespace, which disappears with it.
#
#   scripts/test-openwrt.sh            the releases below
#   IKEV2_OPENWRT_RELEASES=25.12.5 scripts/test-openwrt.sh
#
# Then the two-tunnel failover test on IKEV2_OPENWRT_FAILOVER (25.12.5; empty
# skips it), in a privileged container: it needs network namespaces and the
# kernel's XFRM interfaces, and says so and passes where the kernel has none.
# IKEV2_REQUIRE_XFRM=1 makes that a failure, as CI does.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
releases="${IKEV2_OPENWRT_RELEASES:-24.10.8 25.12.5}"

case "$(uname -m)" in
	x86_64 | amd64) target=x86-64; platform='' ;;
	arm64 | aarch64) target=armsr-armv8; platform='--platform linux/aarch64_generic' ;;
	*) printf 'unsupported host architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

command -v docker >/dev/null 2>&1 || { printf '%s\n' 'Docker is required' >&2; exit 1; }
"$root/scripts/build-ipk.sh" >/dev/null

for release in $releases; do
	image="openwrt/rootfs:$target-$release"
	# shellcheck disable=SC2086
	docker pull -q $platform "$image" >/dev/null
	# shellcheck disable=SC2086
	docker run --rm $platform --cap-add NET_ADMIN -v "$root:/src:ro" "$image" \
		/bin/sh /src/scripts/openwrt/install.sh
done

failover="${IKEV2_OPENWRT_FAILOVER-25.12.5}"
if [ -n "$failover" ]; then
	image="openwrt/rootfs:$target-$failover"
	# shellcheck disable=SC2086
	docker pull -q $platform "$image" >/dev/null
	# shellcheck disable=SC2086
	docker run --rm $platform --privileged -e "IKEV2_REQUIRE_XFRM=${IKEV2_REQUIRE_XFRM:-0}" \
		-v "$root:/src:ro" "$image" /bin/sh /src/scripts/openwrt/install.sh failover
fi
