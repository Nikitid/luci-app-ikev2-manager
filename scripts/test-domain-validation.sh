#!/bin/sh

# Resolver validation used to exit the helper on failure, which skipped every
# rollback its callers had written, and a rule reload was assumed after a
# one-second sleep. Check that validation reports and returns, and that the
# reload proof finds the domain a change adds.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
router="$root/ikev2-manager-runtime/ikev2-domain-router.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

extract() {
	awk -v name="$1" '
		index($0, name "() {") == 1 { body = 1; close_with = "}" }
		index($0, name "() (") == 1 { body = 1; close_with = ")" }
		body { print }
		body && $0 == close_with { exit }
	' "$router"
}

for name in validate_dns_server added_rule_domain; do
	extract "$name" >>"$tmp/functions.sh"
done

# A failed validation returns to the caller, which can then roll back.
(
	domain_file="$tmp/domains"
	printf 'example.org\n' >"$domain_file"
	dns_address=127.0.0.42
	selected_test_domain() { echo example.org; }
	lookup_address() { echo 203.0.113.9; }
	is_fakeip() { case "$1" in 198.18.*) return 0 ;; *) return 1 ;; esac; }
	sleep() { :; }
	. "$tmp/functions.sh"
	if validate_dns_server 2>"$tmp/err"; then
		fail 'a real address for a selected domain passed validation'
	fi
	grep -q 'Selected domain did not receive FakeIP: example.org -> 203.0.113.9' "$tmp/err" ||
		fail 'validation failure was not reported'
	printf 'rolled back\n' >"$tmp/after"
) || fail 'validation ended the caller instead of returning'
grep -qx 'rolled back' "$tmp/after" || fail 'the caller could not roll back'

# A resolver that has just started answers with the real address until it has
# loaded the selected domains; that settles within the retries and passes.
(
	domain_file="$tmp/domains"
	dns_address=127.0.0.42
	dns_probe_names=control.example
	: >"$tmp/lookups"
	selected_test_domain() { echo example.org; }
	lookup_address() {
		[ "$1" = example.org ] || { echo 203.0.113.20; return; }
		echo x >>"$tmp/lookups"
		[ "$(wc -l <"$tmp/lookups")" -ge 3 ] && echo 198.18.0.5 || echo 203.0.113.9
	}
	is_fakeip() { case "$1" in 198.18.*) return 0 ;; *) return 1 ;; esac; }
	sleep() { :; }
	. "$tmp/functions.sh"
	validate_dns_server 2>"$tmp/err" || fail 'a resolver that settled after starting was refused'
)

# The reload proof picks a domain the new rule-set adds over the old one.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/jsonfilter" <<'SHIM'
#!/bin/sh
jq -er '.rules[].domain_suffix[]' "$2"
SHIM
chmod 755 "$tmp/bin/jsonfilter"
(
	PATH="$tmp/bin:$PATH"
	ruleset_file="$tmp/new.json"
	. "$tmp/functions.sh"
	printf '{"version":3,"rules":[{"domain_suffix":["a.example","b.example"]}]}\n' >"$tmp/old.json"
	printf '{"version":3,"rules":[{"domain_suffix":["a.example","c.example","b.example"]}]}\n' >"$ruleset_file"
	[ "$(added_rule_domain "$tmp/old.json")" = c.example ] ||
		fail 'the added domain was not found'
	printf '{"version":3,"rules":[{"domain_suffix":["a.example"]}]}\n' >"$ruleset_file"
	[ -z "$(added_rule_domain "$tmp/old.json")" ] ||
		fail 'a removal was reported as an addition'
	: >"$tmp/empty.json"
	[ "$(added_rule_domain "$tmp/empty.json")" = a.example ] ||
		fail 'a first rule-set did not yield a domain to prove'
)

# The health checks read each listing once. They must still fail on any single
# missing listener or rule.
(
	. "$root/ikev2-manager-runtime/lib/tunnel.sh"
	eval "$(extract listeners_ready)"
	eval "$(extract exit_tproxy_port)"
	eval "$(extract nft_runtime_ready)"
	uci() { [ -z "${fixture_tunnel_2:-}" ] || printf "ikev2-manager.tunnel_2=tunnel\n"; }
	dns_address=127.0.0.42; dns_port=53; tproxy_address=127.0.0.1
	tproxy_port=1602; direct_tproxy_port=1603; router_tproxy_port=1604
	nft_table=ikev2_domain_router; fakeip_range=198.18.0.0/15
	direct_tproxy_mark=0x00400001; router_tproxy_mark=0x00400002; tproxy_table=51820
	fixture_sockets='tcp 0 0 127.0.0.42:53 0.0.0.0:* LISTEN
tcp 0 0 127.0.0.1:1602 0.0.0.0:* LISTEN
tcp 0 0 127.0.0.1:1603 0.0.0.0:* LISTEN
tcp 0 0 127.0.0.1:1604 0.0.0.0:* LISTEN'
	netstat() { printf '%s\n' "$fixture_sockets"; }
	listeners_ready || fail 'healthy listeners were rejected'
	# A second tunnel's devices have an inbound of their own.
	fixture_tunnel_2=1
	if listeners_ready; then fail 'a missing second exit listener was accepted'; fi
	fixture_sockets="$fixture_sockets
tcp 0 0 127.0.0.1:1612 0.0.0.0:* LISTEN"
	listeners_ready || fail 'the second exit listener was not taken'
	fixture_tunnel_2=''
	fixture_sockets="$(printf '%s\n' "$fixture_sockets" | grep -v ':1603 ')"
	if listeners_ready; then fail 'a missing TProxy listener was accepted'; fi

	router=1
	defaultv() { echo "$router"; }
	tproxy_rules_ready() { return 0; }
	ip() { echo 'local default dev lo scope host'; }
	fixture_pre='ip daddr 198.18.0.0/15 meta mark set 0x00400001 tproxy to :1604'
	fixture_out='ip daddr 198.18.0.0/15 meta mark set 0x00400002'
	nft() {
		case "$*" in
			*prerouting) printf '%s\n' "$fixture_pre" ;;
			*output) printf '%s\n' "$fixture_out" ;;
		esac
	}
	nft_runtime_ready || fail 'healthy nftables rules were rejected'
	fixture_out='ip daddr 198.18.0.0/15'
	if nft_runtime_ready; then fail 'a missing router TProxy mark was accepted'; fi
	router=0; fixture_out='ip daddr 10.0.0.0/8'
	nft_runtime_ready || fail 'standard router traffic was rejected'
	fixture_out='ip daddr 198.18.0.0/15'
	if nft_runtime_ready; then fail 'router interception left behind was accepted'; fi
	fixture_out='ip daddr 10.0.0.0/8'
	fixture_pre='ip daddr 198.18.0.0/15'
	if nft_runtime_ready; then fail 'a missing direct TProxy mark was accepted'; fi
) || fail 'resolver health scenario failed'

# Callers keep their rollback reachable.
extract refresh | grep -Fq 'if ! ( check_config ); then' ||
	fail 'refresh validation can still exit before its restore'

printf '%s\n' 'domain validation tests OK'
