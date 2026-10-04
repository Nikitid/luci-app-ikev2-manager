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
	# What the configuration on disk gives sing-box to listen on.
	jsonfilter() { printf '%s\n' 53 1602 1603 1604 ${fixture_exit_ports:-}; }
	config_file="$tmp/config.json"
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
	# A second tunnel's devices have an inbound of their own, once the
	# configuration sing-box runs holds it.
	fixture_exit_ports=1612
	if listeners_ready; then fail 'a missing second exit listener was accepted'; fi
	fixture_sockets="$fixture_sockets
tcp 0 0 127.0.0.1:1612 0.0.0.0:* LISTEN"
	listeners_ready || fail 'the second exit listener was not taken'
	fixture_exit_ports=''
	# A tunnel saved in the settings but not applied has no inbound in that
	# configuration, and a restart would not bring one up. The settings were
	# read here, so the watcher restarted the resolver on every pass and cut
	# every routed connection each time.
	uci() { printf "ikev2-manager.client=client\nikev2-manager.client.enabled='1'\nikev2-manager.tunnel_2=tunnel\nikev2-manager.tunnel_2.enabled='1'\n"; }
	fixture_sockets="$(printf '%s\n' "$fixture_sockets" | grep -v ':1612 ')"
	listeners_ready || fail 'a tunnel not applied yet read as a resolver to restart'
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

# Every exit there is has a rule set, empty until something is sent through
# it. With a rule set only for the exits that had a list, the first service
# sent through a tunnel - and the last taken off it - changed the
# configuration, and sing-box was restarted with every connection it carried.
(
	. "$root/ikev2-manager-runtime/lib/tunnel.sh"
	for name in ruled_exits render_ruleset tunnel_inputs exit_domain_file exit_ruleset \
		exit_tproxy_port bypass_listed json_array_file; do
		eval "$(extract "$name")"
	done
	uci() {
		printf '%s\n' "ikev2-manager.client=client" "ikev2-manager.client.enabled='1'" \
			"ikev2-manager.tunnel_2=tunnel" "ikev2-manager.tunnel_2.enabled='1'"
	}
	validate_domain_file() { :; }
	die() { printf '%s\n' "$*" >&2; exit 1; }
	mkdir -p "$tmp/sets"
	domain_file="$tmp/sets/domains.txt"
	bypass_domain_file="$tmp/sets/never.txt"
	ruleset_file="$tmp/sets/rules.json"
	bypass_ruleset_file="$tmp/sets/never.json"
	printf 'first.example\n' >"$domain_file"
	render_ruleset
	for exit in 1s 2 2s; do
		[ "$(cat "$tmp/sets/rules.exit-$exit.json" 2>/dev/null)" = '{"version":3,"rules":[]}' ] ||
			fail "the exit $exit nothing is sent through has no empty rule set"
	done
	[ ! -e "$tmp/sets/rules.exit-3.json" ] || fail 'a tunnel that is not configured was given a rule set'
	inputs_before="$(tunnel_inputs)"
	printf '%s\n' "$inputs_before" | grep -c '^exit_rules' | grep -qx 3 ||
		fail 'the configuration does not name a rule set for every exit'
	printf '%s\n' "$inputs_before" | awk '$1 == "exit_rules" { printf "%s ", $2 }' | grep -qx '2s 2 1s ' ||
		fail 'the rule sets of the exits are not in the order they take precedence'
	printf 'bound.example\n' >"$tmp/sets/domains.exit-2s.txt"
	render_ruleset
	[ "$(cat "$tmp/sets/rules.exit-2s.json")" = '{"version":3,"rules":[{"domain_suffix":["bound.example"]}]}' ] ||
		fail 'the names sent through an exit are not in its rule set'
	[ "$(tunnel_inputs)" = "$inputs_before" ] ||
		fail 'sending a service through another tunnel changes the configuration'
) || fail 'rule set scenario failed'

# After a reload sing-box routes by the new rule sets only what is opened
# afterwards. What the rules as they are now would route elsewhere is closed,
# and looked for again: a connection reopened before sing-box took the new
# rule set is on the old path once more.
(
	. "$root/ikev2-manager-runtime/lib/tunnel.sh"
	for name in close_rerouted_connections ruled_exits exit_ruleset bypass_listed; do
		eval "$(extract "$name")"
	done
	uci() {
		printf '%s\n' "ikev2-manager.client=client" "ikev2-manager.client.enabled='1'" \
			"ikev2-manager.tunnel_2=tunnel" "ikev2-manager.tunnel_2.enabled='1'"
	}
	mkdir -p "$tmp/moved"
	ruleset_file="$tmp/moved/rules.json"
	bypass_domain_file="$tmp/moved/never.txt"
	bypass_ruleset_file="$tmp/moved/never.json"
	printf '{"version":3,"rules":[{"domain_suffix":["kept.example"]}]}\n' >"$ruleset_file"
	printf '{"version":3,"rules":[{"domain_suffix":["moved.example"]}]}\n' >"$tmp/moved/rules.exit-2.json"
	for exit in 1s 2s; do printf '{"version":3,"rules":[]}\n' >"$tmp/moved/rules.exit-$exit.json"; done
	ucode_bin=ucode
	runtime_lib_dir="$root/ikev2-manager-runtime/lib"
	controller_address=127.0.0.44:1605
	controller_curl_config() { : >"$1/curl.conf"; }
	sleep() { :; }
	old='inbound=tproxy-in rule_set=ikev2-domains => route(exit-1)'
	new='inbound=tproxy-in rule_set=ikev2-domains-2 => route(exit-2)'
	row() { printf '{"id":"00000000-0000-0000-0000-00000000000%s","metadata":{"host":"%s"},"rule":"%s"}' "$1" "$2" "$3"; }
	: >"$tmp/moved/calls"
	curl() {
		local last='' argument delete=0
		for argument in "$@"; do [ "$argument" != DELETE ] || delete=1; last="$argument"; done
		if [ "$delete" = 1 ]; then
			printf 'close %s\n' "${last##*/}" >>"$tmp/moved/calls"
			return 0
		fi
		printf 'list\n' >>"$tmp/moved/calls"
		# First the moved service's connection and one that stays; then the
		# moved one reopened on the old path; then on the new one.
		case "$(grep -c '^list$' "$tmp/moved/calls")" in
			1) printf '{"connections":[%s,%s]}' "$(row 1 www.moved.example "$old")" "$(row 2 kept.example "$old")" ;;
			2) printf '{"connections":[%s,%s]}' "$(row 3 www.moved.example "$old")" "$(row 2 kept.example "$old")" ;;
			*) printf '{"connections":[%s,%s]}' "$(row 4 www.moved.example "$new")" "$(row 2 kept.example "$old")" ;;
		esac
	}
	close_rerouted_connections
	[ "$(tr '\n' ' ' <"$tmp/moved/calls")" = 'list close 00000000-0000-0000-0000-000000000001 list close 00000000-0000-0000-0000-000000000003 list ' ] ||
		fail "the connections of a moved service were not the ones closed: $(tr '\n' ' ' <"$tmp/moved/calls")"
	# A controller that does not answer is a resolver restarting: nothing to do.
	curl() { return 7; }
	close_rerouted_connections || fail 'an unanswering controller failed the rule refresh'
) || fail 'rerouted connection scenario failed'

# Validation dies on bad input, and a refresh must still put the previous
# configuration back: its rollback stays reachable.
(
	eval "$(extract refresh)"
	init_config() { :; }
	defaultv() { echo fakeip; }
	mktemp() { mkdir -p "$tmp/refresh" && printf '%s\n' "$tmp/refresh"; }
	backup_generated() { :; }
	check_config() { exit 1; }
	restore_generated() { : >"$tmp/restored"; }
	write_status() { printf '%s\n' "$1" >"$tmp/refresh-status"; }
	rc=0
	refresh || rc=$?
	[ "$rc" = 1 ] && [ -e "$tmp/restored" ] && [ "$(cat "$tmp/refresh-status")" = error ]
) || fail 'refresh validation can still exit before its restore'

printf '%s\n' 'domain validation tests OK'
