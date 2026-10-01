#!/bin/sh
# Routing invariants shared by apply, doctor and operational self-tests.

# ip route del with metric 0 can match any priority. The flush selector is
# filtered in userspace and removes only the zero-metric PBR default. Install
# and verify our terminal route first; never delete the last guard to repair it.
ensure_failclosed_default() {
	local family="$1" table="$2" routes
	routes="$(ip -"$family" route show table "$table" 2>/dev/null)" || routes=''
	if ! printf '%s\n' "$routes" | grep -Eq '^unreachable default .*metric 32767( |$)'; then
		ip -"$family" route replace unreachable default metric 32767 table "$table" || return 1
	fi
	if [ "$family" = 4 ] && printf '%s\n' "$routes" |
		awk '/^unreachable default/ && !/metric / { found=1 } END { exit !found }'; then
		ip -4 route flush table "$table" type unreachable metric 0 || return 1
	fi
	ip -"$family" route show table "$table" 2>/dev/null |
		grep -Eq '^unreachable default .*metric 32767( |$)'
}

forward_chain_ok() {
	nft list chain inet fw4 forward 2>/dev/null | grep -q 'jump forward_'
}

ensure_forward_chain() {
	forward_chain_ok && return 0
	fw4 -q reload || return 1
	forward_chain_ok
}

# Names asked to decide whether a resolver answers. Any one of them is enough:
# a single unreachable or blocked domain used to read as a broken resolver and
# roll back a working configuration. The Russian name keeps the check working on
# uplinks that drop foreign resolution paths.
dns_probe_names='openwrt.org cloudflare.com yandex.ru'

# The IPv4 address SERVER gives NAME, or nothing. Bounded, so a resolver that
# never answers cannot stall the caller: nslookup has no timeout of its own.
dns_probe_lookup() {
	local name="$1" server="$2" seconds="${3:-2}" output query_pid watchdog_pid sleeper_pid=''
	output="$(mktemp "${TMPDIR:-/tmp}/ikev2-dns-probe.XXXXXX")" || return 1
	nslookup "$name" "$server" >"$output" 2>/dev/null &
	query_pid=$!
	(
		trap '[ -z "$sleeper_pid" ] || kill "$sleeper_pid" 2>/dev/null; exit 0' TERM INT
		sleep "$seconds" &
		sleeper_pid=$!
		wait "$sleeper_pid" 2>/dev/null || exit 0
		kill "$query_pid" 2>/dev/null || :
	) >/dev/null 2>&1 &
	watchdog_pid=$!
	wait "$query_pid" 2>/dev/null || :
	kill "$watchdog_pid" 2>/dev/null || :
	wait "$watchdog_pid" 2>/dev/null || :
	awk '
		/^Name:/ { answer = 1; next }
		answer && /^Address[^:]*:/ {
			for (i = 2; i <= NF; i++)
				if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
		}
	' "$output"
	rm -f "$output"
}

# Whether SERVER answers any of the probe names.
dns_probe_answers() {
	local server="$1" name
	for name in $dns_probe_names; do
		[ -z "$(dns_probe_lookup "$name" "$server")" ] || return 0
	done
	return 1
}

# Resolvers outside everything this application runs: the WAN's own and two
# public ones.
dns_probe_baseline_servers() {
	local interface
	interface="$(uci -q get ikev2-manager.globals.wan_interface 2>/dev/null || echo wan)"
	ubus call "network.interface.$interface" status 2>/dev/null |
		jsonfilter -e '@["dns-server"][*]' 2>/dev/null || :
	# A list without a final newline must not run into the next address.
	printf '\n%s\n' 77.88.8.8 1.1.1.1
}

# When none of them answers any probe name the Internet is unreachable, and a
# failed check says nothing about the configuration just applied: nothing
# should be rolled back or switched over it.
internet_dns_reachable() {
	local server
	for server in $(dns_probe_baseline_servers); do
		dns_probe_answers "$server" && return 0
	done
	return 1
}

router_dns_ready() {
	local server
	server="${1:-127.0.0.1}"
	dns_probe_answers "$server"
}

wait_for_router_dns() {
	local server attempts tries
	server="${1:-127.0.0.1}"
	attempts="${2:-20}"
	case "$attempts" in
		'' | *[!0-9]* | 0) return 1 ;;
	esac
	tries=0
	while [ "$tries" -lt "$attempts" ]; do
		router_dns_ready "$server" && return 0
		tries=$((tries + 1))
		[ "$tries" -ge "$attempts" ] || sleep 1
	done
	internet_dns_reachable ||
		printf '%s\n' 'No resolver on the Internet answers either; the WAN connection appears to be down' >&2
	return 1
}

ensure_ipv6_failfast() {
	ip -6 route show default 2>/dev/null | grep -q . && return 0
	ip -6 route replace unreachable default metric 2147483647 2>/dev/null || true
}

# The routing table of the tunnel, unreachable when it is down, which
# ikev2-routing installs.
routing_tunnel_table() {
	printf '1601\n'
}

failclosed_check() (
	table="$(routing_tunnel_table)"
	test_ip='203.0.113.77'
	routes="$(ip -4 route show table "$table" 2>/dev/null)"

	printf '%s\n' "$routes" |
		grep -Eq '^unreachable default( |$)' || return 1

	# Derive the active PBR mark from the existing rule and query it without
	# creating or deleting any routing objects. Doctor calls this function while
	# rendering LuCI, so validation must be strictly read-only.
	rule="$(ip -4 rule show 2>/dev/null |
		awk -v table="$table" '
			$0 ~ "lookup " table "([[:space:]]|$)" {
				for (i = 1; i <= NF; i++)
					if ($i == "fwmark") { print $(i + 1); exit }
			}
		')"
	[ -n "$rule" ] || return 1
	mark="${rule%%/*}"
	if printf '%s\n' "$routes" | grep -Eq '^default dev ipsec-out( |$)'; then
		output="$(ip -4 route get "$test_ip" mark "$mark" 2>&1)" || return 1
		printf '%s\n' "$output" | grep -Eq '(^|[[:space:]])dev ipsec-out([[:space:]]|$)'
	else
		output="$(ip -4 route get "$test_ip" mark "$mark" 2>&1)" && return 1
		printf '%s\n' "$output" | grep -qi 'unreachable'
	fi
)

failclosed_ipv6_check() (
	table="$(routing_tunnel_table)"
	test_ip='2001:db8::77'

	ip -6 route show table "$table" 2>/dev/null |
		grep -Eq '^unreachable default( |$)' || return 1
	rule="$(ip -6 rule show 2>/dev/null |
		awk -v table="$table" '
			$0 ~ "lookup " table "([[:space:]]|$)" {
				for (i = 1; i <= NF; i++)
					if ($i == "fwmark") { print $(i + 1); exit }
			}
		')"
	[ -n "$rule" ] || return 1
	mark="${rule%%/*}"
	output="$(ip -6 route get "$test_ip" mark "$mark" 2>&1)" && return 1
	printf '%s\n' "$output" | grep -qi 'unreachable'
)
