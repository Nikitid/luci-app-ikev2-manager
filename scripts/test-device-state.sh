#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/uci"

cp "$root/scripts/uci-stub.sh" "$tmp/bin/uci"

# The starting point is the previous representation: a domain device kept in
# the shared list, with no per-device sections yet.
cat >"$tmp/uci/ikev2-manager" <<'EOF'
globals=globals
globals.wan_interface=wan
domains=domains
domains.device_source=192.168.1.50
EOF
cat >"$tmp/uci/pbr" <<'EOF'
ikev2pbr_domains=policy
ikev2pbr_domains.src_addr=@br-lan 192.168.1.50
EOF
cat >"$tmp/uci/firewall" <<'EOF'
@zone[0]=zone
@zone[0].name=lan
@zone[0].network=lan iot
@zone[1]=zone
@zone[1].name=wan
@zone[1].network=wan
EOF

cat >"$tmp/bin/ipcalc.sh" <<'EOF'
#!/bin/sh
case "$1" in
	192.168.1.*/32 | 192.168.1.*/24) exit 0 ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/restart" <<'EOF'
#!/bin/sh
[ -z "${TEST_RESTART_LOG:-}" ] || printf '%s\n' "$*" >>"$TEST_RESTART_LOG"
[ "${TEST_RESTART_FAIL:-0}" != 1 ]
EOF

cat >"$tmp/bin/conntrack" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${TEST_RESTART_LOG}.conntrack"
[ "${TEST_CONNTRACK_FAIL:-0}" != 1 ]
EOF
chmod 755 "$tmp/bin/conntrack"

cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
	'-4 route show default') printf '%s\n' 'default via 198.51.100.1 dev eth1' ;;
	'-4 neigh show')
		printf '%s\n' \
			'198.51.100.1 dev eth1 lladdr 00:00:5e:00:01:01 REACHABLE' \
			'192.168.1.50 dev br-lan lladdr 02:00:00:00:00:50 REACHABLE' \
			'192.168.1.51 dev br-lan FAILED'
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/ipcalc.sh" "$tmp/bin/restart" "$tmp/bin/ip"
printf '%s\n' '0 02:00:00:00:00:50 192.168.1.50 laptop *' >"$tmp/state-dhcp.leases"

run_device() {
	PATH="$tmp/bin:$PATH" UCI_STUB_DIR="$tmp/uci" \
	IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
	IKEV2_RESTART_HELPER="$tmp/bin/restart" \
	IKEV2_DEVICE_RUNTIME_HELPER="$tmp/bin/restart" \
	IKEV2_SYSTEM_HELPER="$tmp/bin/restart" \
	IKEV2_DHCP_LEASES="$tmp/state-dhcp.leases" \
	TEST_RESTART_LOG="$tmp/restart.log" \
		sh "$root/luci-ikev2-domains/ikev2-devices.sh" "$@"
}

# Reading works before the import has run, so an upgraded package keeps
# listing the same devices until the first change.
run_device dump | grep -Fxq 'addr=192.168.1.50 mode=domain'
run_device clients | grep -Fxq "192.168.1.50	laptop	02:00:00:00:00:50"
run_device zones | grep -Fxq 'lan=lan iot'
run_device zones | grep -Fxq 'wan=wan'

# The first change imports the previous representation and stores both devices
# as sections of this application.
run_device add-subnet 192.168.1.60
grep -Fxq 'device_192_168_1_50=device_policy' "$tmp/uci/ikev2-manager"
grep -Fxq 'device_192_168_1_50.route_mode=domain' "$tmp/uci/ikev2-manager"
grep -Fxq 'device_192_168_1_60.route_mode=domain' "$tmp/uci/ikev2-manager"
grep -Fxq 'globals.device_schema=2' "$tmp/uci/ikev2-manager"
run_device dump | grep -Fxq 'addr=192.168.1.60 mode=domain'

run_device remove-subnet 192.168.1.50
! grep -q '^device_192_168_1_50' "$tmp/uci/ikev2-manager"
! run_device dump | grep -Fq 'addr=192.168.1.50'

# An override is stored only in application configuration. The independent
# nftables runtime applies it without creating a duplicate PBR policy.
run_device add-override 192.168.1.70 exclude
grep -Fxq 'device_192_168_1_70.route_mode=exclude' "$tmp/uci/ikev2-manager"
! grep -q '^pbr_dev_ex_192_168_1_70' "$tmp/uci/pbr"
run_device dump | grep -Fxq 'addr=192.168.1.70 mode=exclude'

# A regular device edit only applies its owned runtime and invalidates flows
# from that exact source. No global firewall or PBR operation is allowed.
: >"$tmp/restart.log"
: >"$tmp/restart.log.conntrack"
run_device set-exclusions 192.168.1.70 1 0 0
[ "$(cat "$tmp/restart.log")" = sync ]
[ "$(cat "$tmp/restart.log.conntrack")" = '-D -s 192.168.1.70' ]
cp "$tmp/uci/ikev2-manager" "$tmp/before-conntrack-failure"
if TEST_CONNTRACK_FAIL=1 run_device set-included 192.168.1.70; then
	printf '%s\n' 'flow invalidation failure reported success' >&2
	exit 1
fi
unset TEST_CONNTRACK_FAIL
cmp "$tmp/uci/ikev2-manager" "$tmp/before-conntrack-failure"

# A stale policy from an older package is removed by the next render.
UCI_STUB_DIR="$tmp/uci" sh "$tmp/bin/uci" set 'pbr.pbr_dev_ex_stale=policy'
UCI_STUB_DIR="$tmp/uci" sh "$tmp/bin/uci" set \
	'pbr.pbr_dev_ex_stale.name=VPN Exclude: 192.168.1.99'
: >"$tmp/restart.log"
run_device add-override 192.168.1.71 exclude
! grep -q '^pbr_dev_ex_' "$tmp/uci/pbr"
grep -Fxq -- '--wait' "$tmp/restart.log"

run_device remove-override 192.168.1.70
! grep -q '^pbr_dev_ex_192_168_1_70' "$tmp/uci/pbr"
! grep -q '^device_192_168_1_70' "$tmp/uci/ikev2-manager"

# An opt-out is independent of routing: setting one on an unknown device must
# not turn that device into a domain-routing source.
run_device set-flag 192.168.1.90 dns_passthrough 1
grep -Fxq 'device_192_168_1_90.route_mode=none' "$tmp/uci/ikev2-manager"
grep -Fxq 'device_192_168_1_90.dns_passthrough=1' "$tmp/uci/ikev2-manager"
run_device dump | grep -Fxq 'addr=192.168.1.90 mode=none dns=1'
! run_device dump | grep -Fq 'addr=192.168.1.90 mode=domain'

# Clearing the last setting removes the device rather than leaving an empty
# section behind in the list.
run_device set-flag 192.168.1.90 dns_passthrough 0
! grep -q '^device_192_168_1_90' "$tmp/uci/ikev2-manager"

# An opt-out on a device that also has a routing mode keeps both.
run_device add-override 192.168.1.91 fullroute
run_device set-flag 192.168.1.91 dns_passthrough 1
run_device dump | grep -Fq 'addr=192.168.1.91 mode=fullroute'
run_device dump | grep -Fq 'dns=1'
run_device remove-override 192.168.1.91
grep -Fxq 'device_192_168_1_91.dns_passthrough=1' "$tmp/uci/ikev2-manager"
run_device dump | grep -Fxq 'addr=192.168.1.91 mode=none dns=1'

run_device set-flag 192.168.1.91 dns_passthrough 0
! grep -q '^device_192_168_1_91' "$tmp/uci/ikev2-manager"

# The unmanaged preset combines WAN routing with both independent bypasses.
run_device set-unmanaged 192.168.1.92
grep -Fxq 'device_192_168_1_92.route_mode=exclude' "$tmp/uci/ikev2-manager"
grep -Fxq 'device_192_168_1_92.dns_passthrough=1' "$tmp/uci/ikev2-manager"
grep -Fxq 'device_192_168_1_92.dpi_passthrough=1' "$tmp/uci/ikev2-manager"
run_device dump | grep -Fxq \
	'addr=192.168.1.92 mode=exclude dns=1 dpi=1'

# The unified exclusion editor stores all three switches atomically. Turning
# off PBR keeps the remaining opt-outs without silently adding domain routing.
run_device set-exclusions 192.168.1.93 1 1 0
run_device dump | grep -Fxq \
	'addr=192.168.1.93 mode=exclude dns=1'
run_device set-exclusions 192.168.1.93 0 1 1
run_device dump | grep -Fxq 'addr=192.168.1.93 mode=none dns=1 dpi=1'
! grep -q '^pbr_dev_ex_192_168_1_93' "$tmp/uci/pbr"

# Inclusion deliberately clears exclusion flags, while removing its row
# restores the ordinary/default device policy and prunes the empty section.
run_device set-included 192.168.1.93
run_device dump | grep -Fxq \
	'addr=192.168.1.93 mode=fullroute'
! grep -q '^device_192_168_1_93.dns_passthrough=' "$tmp/uci/ikev2-manager"
! grep -q '^device_192_168_1_93.dpi_passthrough=' "$tmp/uci/ikev2-manager"
# A full-route device sent through another tunnel shows it, and only a
# configured tunnel is accepted.
if run_device set-exit 192.168.1.93 2 >/dev/null 2>&1; then
	printf '%s\n' 'a device was sent through a tunnel that is not configured' >&2
	exit 1
fi
printf '%s\n' 'tunnel_2=tunnel' 'tunnel_2.enabled=1' >>"$tmp/uci/ikev2-manager"
run_device set-exit 192.168.1.93 2
run_device dump | grep -Fxq 'addr=192.168.1.93 mode=fullroute exit=2' ||
	{ printf '%s\n' 'a device sent through the second tunnel does not show it' >&2; exit 1; }
# Bound to that tunnel, without backup; an eighth tunnel is not one.
run_device set-exit 192.168.1.93 2s
run_device dump | grep -Fxq 'addr=192.168.1.93 mode=fullroute exit=2s' ||
	{ printf '%s\n' 'a device bound to the second tunnel does not show it' >&2; exit 1; }
for bad in 8 8s 2x s wan; do
	if run_device set-exit 192.168.1.93 "$bad" >/dev/null 2>&1; then
		printf 'a device was sent through "%s"\n' "$bad" >&2
		exit 1
	fi
done
run_device set-exit 192.168.1.93 1
run_device dump | grep -Fxq 'addr=192.168.1.93 mode=fullroute' &&
	! grep -q '^device_192_168_1_93.exit=' "$tmp/uci/ikev2-manager" ||
	{ printf '%s\n' 'the main tunnel is stored as an exit' >&2; exit 1; }
run_device clear-policy 192.168.1.93
! grep -q '^device_192_168_1_93' "$tmp/uci/ikev2-manager"

# A domain member can carry DNS/Zapret exclusions. Removing its unified row
# clears only those exclusions and preserves membership in the shared policy.
run_device add-subnet 192.168.1.94
run_device set-exclusions 192.168.1.94 0 1 1
run_device dump | grep -Fxq 'addr=192.168.1.94 mode=domain dns=1 dpi=1'
run_device clear-policy 192.168.1.94
run_device dump | grep -Fxq 'addr=192.168.1.94 mode=domain'

if run_device set-exclusions 192.168.1.95 1 maybe 0 >/dev/null 2>&1; then
	printf '%s\n' 'invalid unified exclusion switch unexpectedly succeeded' >&2
	exit 1
fi

# A failed restart must leave neither the configuration nor the rendered
# policies changed.
before_app="$(cat "$tmp/uci/ikev2-manager")"
before_pbr="$(cat "$tmp/uci/pbr")"
if TEST_RESTART_FAIL=1 run_device add-subnet 192.168.1.80 >/dev/null 2>&1; then
	printf '%s\n' 'device update unexpectedly survived a failed PBR restart' >&2
	exit 1
fi
[ "$(cat "$tmp/uci/ikev2-manager")" = "$before_app" ]
[ "$(cat "$tmp/uci/pbr")" = "$before_pbr" ]

printf '%s\n' 'device state tests OK'
