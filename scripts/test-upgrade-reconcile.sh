#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/uci"

grep -Fq 'if [ "$(defaultv dns managed 0)" = 1 ]; then' \
	"$root/ikev2-manager-runtime/ikev2-manager-system.sh"
grep -Fq 'apply_saved_dns || return 1' \
	"$root/ikev2-manager-runtime/ikev2-manager-system.sh"

cp "$root/scripts/uci-stub.sh" "$tmp/bin/uci"
cat >"$tmp/bin/domain-router" <<'EOF'
#!/bin/sh
[ "${1:-}" = refresh ] || exit 1
printf '%s\n' refresh >>"$TEST_DOMAIN_ROUTER_LOG"
[ "${TEST_DOMAIN_ROUTER_FAIL:-0}" != 1 ]
EOF
cat >"$tmp/bin/device-runtime" <<'EOF'
#!/bin/sh
[ "${1:-}" = sync ] || exit 1
[ "${TEST_DEVICE_SYNC_FAIL:-0}" != 1 ]
EOF
cat >"$tmp/bin/routing-runtime" <<'EOF'
#!/bin/sh
[ "${1:-}" = sync ] || exit 1
printf '%s\n' sync >>"$TEST_ROUTING_LOG"
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/domain-router" "$tmp/bin/device-runtime" "$tmp/bin/routing-runtime"

cat >"$tmp/uci/ikev2-manager" <<'EOF'
globals=globals
globals.configured=1
domains=domains
domains.engine=fakeip
EOF
TEST_DOMAIN_ROUTER_LOG="$tmp/domain-router.log"
TEST_ROUTING_LOG="$tmp/routing.log"
export TEST_DOMAIN_ROUTER_LOG TEST_ROUTING_LOG

write_firewall() {
	cat >"$tmp/uci/firewall" <<'EOF'
ikev2pbr_dns_lan=redirect
ikev2pbr_dns_lan.src=lan
ikev2pbr_dns_in=redirect
ikev2pbr_dns_in.src=ikev2in
ikev2pbr_dot_lan=rule
ikev2pbr_dot_lan.src=lan
ikev2pbr_dot_in=rule
ikev2pbr_dot_in.src=ikev2in
ikev2pbr_in_dns=rule
ikev2pbr_in_dns.src=ikev2in
unrelated=rule
unrelated.name=keep
EOF
}

force_reconcile() {
	sed -i.bak '/^globals.runtime_schema=/d' "$tmp/uci/ikev2-manager"
}

run_reconcile() {
	PATH="$tmp/bin:$PATH" \
	UCI_STUB_DIR="$tmp/uci" \
	IKEV2_UCI_CONFIG_DIR="$tmp/uci" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_DEVICE_RUNTIME_HELPER="$tmp/bin/device-runtime" \
	IKEV2_ROUTING_RUNTIME_HELPER="$tmp/bin/routing-runtime" \
	IKEV2_DOMAIN_ROUTER_HELPER="$tmp/bin/domain-router" \
	IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
		sh "$root/ikev2-manager-runtime/ikev2-manager-system.sh" _upgrade-reconcile
}

write_firewall
run_reconcile
[ "$(wc -l <"$TEST_DOMAIN_ROUTER_LOG" | tr -d ' ')" = 1 ]
grep -Fxq 'globals.runtime_schema=4' "$tmp/uci/ikev2-manager"
# An upgrade starts the application's own routing before the device policy
# takes its marks; PBR itself is left to the next Apply.
[ "$(cat "$TEST_ROUTING_LOG")" = sync ] ||
	{ printf '%s\n' 'the upgrade did not start policy routing' >&2; exit 1; }
if grep -Eq '^ikev2pbr_(dns|dot)_' "$tmp/uci/firewall"; then
	printf '%s\n' 'obsolete DNS/DoT firewall sections survived upgrade reconcile' >&2
	exit 1
fi
grep -Fxq 'ikev2pbr_in_dns=rule' "$tmp/uci/firewall"
grep -Fxq 'unrelated.name=keep' "$tmp/uci/firewall"

# Installing another build with the same generated-runtime schema is a strict
# no-op for DNS/FakeIP and does not restart resolver processes.
: >"$TEST_DOMAIN_ROUTER_LOG"
run_reconcile
[ ! -s "$TEST_DOMAIN_ROUTER_LOG" ]

# A replacement runtime failure must leave the old UCI state intact. This is
# the no-outage guarantee: retirement happens only after the atomic nft load.
write_firewall
force_reconcile
if TEST_DEVICE_SYNC_FAIL=1 run_reconcile >/dev/null 2>&1; then
	printf '%s\n' 'failed replacement runtime was reported as reconciled' >&2
	exit 1
fi
grep -Fxq 'ikev2pbr_dns_lan=redirect' "$tmp/uci/firewall"
grep -Fxq 'ikev2pbr_dot_lan=rule' "$tmp/uci/firewall"

# A failed DNS-policy refresh is reported before any obsolete firewall state
# is retired. The domain helper owns restoration of its generated config and
# process, while this reconciler leaves persistent UCI untouched.
write_firewall
force_reconcile
if TEST_DOMAIN_ROUTER_FAIL=1 run_reconcile >/dev/null 2>&1; then
	printf '%s\n' 'failed Reliable-mode refresh was reported as reconciled' >&2
	exit 1
fi
grep -Fxq 'ikev2pbr_dns_lan=redirect' "$tmp/uci/firewall"
grep -Fxq 'ikev2pbr_dot_lan=rule' "$tmp/uci/firewall"

# A prefix assignment on a function call outlives it; the cases above set two.
unset TEST_DOMAIN_ROUTER_FAIL TEST_DEVICE_SYNC_FAIL

# The automatic switch to matching by address is gone; a retry an older
# release left pending is dropped.
printf 'domains.fakeip_retry=1\n' >>"$tmp/uci/ikev2-manager"
force_reconcile
run_reconcile || { printf '%s\n' 'reconcile failed with a pending retry' >&2; exit 1; }
if grep -q '^domains.fakeip_retry=' "$tmp/uci/ikev2-manager"; then
	printf '%s\n' 'a pending FakeIP retry survived the upgrade' >&2
	exit 1
fi

# A router that was put on PBR by hand routes on its own after the upgrade
# too: PBR is no longer a way of routing.
printf 'globals.routing_backend=pbr\n' >>"$tmp/uci/ikev2-manager"
force_reconcile
: >"$TEST_ROUTING_LOG"
run_reconcile || { printf '%s\n' 'reconcile failed on a PBR router' >&2; exit 1; }
[ "$(cat "$TEST_ROUTING_LOG")" = sync ] ||
	{ printf '%s\n' 'a router set to PBR did not get policy routing' >&2; exit 1; }

printf '%s\n' 'upgrade reconcile tests OK'
