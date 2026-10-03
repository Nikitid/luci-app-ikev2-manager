#!/bin/sh
# A plain-text report of the router's state, to attach to a bug report.
#
# What identifies the router, its owner or its users does not leave in it:
# values of settings named like a password, secret, key or token are dropped,
# and so is anything between PEM markers; every tunnel's server and identities,
# the server name, the VPN user names and the router's host name become
# placeholders, and so do public IPv4 and IPv6 addresses and MAC addresses.
# Private, loopback, FakeIP and documentation ranges stay, as do the well-known
# public resolvers, because the routing cannot be read without them. One value
# gets the same placeholder throughout, so the report still shows where the
# same address comes back.

diagnostics_resolvers='1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 9.9.9.10 9.9.9.11'
diagnostics_resolvers="$diagnostics_resolvers 149.112.112.112 149.112.112.10 77.88.8.8"
diagnostics_resolvers="$diagnostics_resolvers 77.88.8.1 77.88.8.2 77.88.8.88 94.140.14.14"
diagnostics_resolvers="$diagnostics_resolvers 94.140.15.15 208.67.222.222 208.67.220.220"
diagnostics_resolvers="$diagnostics_resolvers 76.76.2.0 76.76.10.0 194.242.2.2"

# "value<TAB>placeholder" for every setting that names a host or a person.
diagnostics_identities() {
	local value section n=0 cert pair
	for pair in client.remote_address:tunnel-server client.remote_id:tunnel-server-id \
		client.username:tunnel-user server.identity:server-name; do
		value="$(uci -q get "$config.${pair%%:*}" 2>/dev/null || true)"
		[ -z "$value" ] || printf '%s\t<%s>\n' "$value" "${pair#*:}"
	done
	# The other tunnels, numbered as they are in the report.
	for section in $(uci -q show "$config" 2>/dev/null |
		sed -n "s/^$config\.\(tunnel_[2-7]\)=tunnel$/\1/p"); do
		for pair in remote_address:server remote_id:server-id username:user; do
			value="$(uci -q get "$config.$section.${pair%%:*}" 2>/dev/null || true)"
			[ -z "$value" ] || printf '%s\t<tunnel-%s-%s>\n' "$value" "${section#tunnel_}" "${pair#*:}"
		done
	done
	# Their credential store names the same users. It exists only once a
	# second tunnel was saved, and the report runs under set -e.
	value="${IKEV2_TUNNELS_SECRET_DB:-/etc/ikev2-manager/tunnels.secret}"
	[ ! -r "$value" ] ||
		awk -F '\t' 'NF >= 2 && $2 != "" { printf "%s\t<tunnel-%s-user>\n", $2, $1 }' "$value"
	for section in $(uci -q show "$config" 2>/dev/null |
		sed -n "s/^$config\.\(user_[^.=]*\)=.*/\1/p"); do
		value="$(uci -q get "$config.$section.username" 2>/dev/null || true)"
		[ -n "$value" ] || continue
		n=$((n + 1))
		printf '%s\t<user-%s>\n' "$value" "$n"
	done
	# The credential store names the same users; the first placeholder wins.
	cut -f1 "${IKEV2_USERS_DB:-/etc/ikev2-manager/users.db}" 2>/dev/null |
		awk -v n="$n" 'NF { printf "%s\t<user-%d>\n", $0, ++n }'
	value="$(uci -q get system.@system[0].hostname 2>/dev/null || true)"
	[ -z "$value" ] || printf '%s\t<router-name>\n' "$value"
	for value in $(uci -q get acme.ikev2.domains 2>/dev/null); do
		printf '%s\t<server-name>\n' "$value"
	done
	cert="${IKEV2_DIAGNOSTICS_CERT:-/etc/swanctl/x509/ikev2.pem}"
	[ -r "$cert" ] && command -v openssl >/dev/null 2>&1 &&
		openssl x509 -in "$cert" -noout -subject -ext subjectAltName 2>/dev/null |
		sed -n 's/.*CN *= *\([^,/]*\).*/\1/p; s/DNS://gp' | tr ',' '\n' |
		sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' |
		while IFS= read -r value; do printf '%s\t<server-name>\n' "$value"; done
	:
}

# Reads the report on stdin; FILE holds diagnostics_identities.
diagnostics_redact() {
	awk -v resolvers="$diagnostics_resolvers" -v identities="$1" -F '\t' '
		function label(kind, value,   key) {
			key = kind SUBSEP value
			if (!(key in seen)) {
				count[kind]++
				seen[key] = "<" kind "-" count[kind] ">"
			}
			return seen[key]
		}
		# A value ends a word before a dot only when the dot ends the
		# sentence, and a dot before it still starts one: a subdomain of the
		# server name is the server name too.
		function bounded(line, at, length_,   before, after) {
			before = at > 1 ? substr(line, at - 1, 1) : ""
			after = substr(line, at + length_, 1)
			if (before ~ /[A-Za-z0-9_@-]/) return 0
			if (after == ".") return substr(line, at + length_ + 1, 1) !~ /[A-Za-z0-9]/
			return after !~ /[A-Za-z0-9_@-]/
		}
		# every whole-word occurrence of a literal value
		function literal(line, value, replacement,   out, at) {
			out = ""
			while ((at = index(line, value)) > 0) {
				if (!bounded(line, at, length(value))) {
					out = out substr(line, 1, at)
					line = substr(line, at + 1)
				} else {
					out = out substr(line, 1, at - 1) replacement
					line = substr(line, at + length(value))
				}
			}
			return out line
		}
		function kept4(address,   o, f, s, i) {
			if (split(address, o, ".") != 4) return 1
			for (i = 1; i <= 4; i++)
				if (length(o[i]) > 3 || o[i] + 0 > 255) return 1
			f = o[1] + 0; s = o[2] + 0
			if (f == 0 || f == 10 || f == 127 || f >= 224) return 1
			if (f == 169 && s == 254) return 1
			if (f == 172 && s >= 16 && s <= 31) return 1
			if (f == 192 && s == 168) return 1
			if (f == 100 && s >= 64 && s <= 127) return 1
			if (f == 198 && (s == 18 || s == 19)) return 1
			if (f == 192 && s == 0 && o[3] + 0 == 2) return 1
			if (f == 198 && s == 51 && o[3] + 0 == 100) return 1
			if (f == 203 && s == 0 && o[3] + 0 == 113) return 1
			return (address in resolver)
		}
		# Replace what PATTERN matches when KEEP says it is not to be kept.
		function scan(line, pattern, kind,   out, token) {
			out = ""
			while (match(line, pattern)) {
				token = substr(line, RSTART, RLENGTH)
				out = out substr(line, 1, RSTART - 1)
				if (kind == "ip" && kept4(token)) out = out token
				else if (kind == "ip6" && !global6(token)) out = out token
				else out = out label(kind, tolower(token))
				line = substr(line, RSTART + RLENGTH)
			}
			return out line
		}
		# A global unicast IPv6 address: a time of day has three groups and no
		# "::", an address has "::" or all eight.
		function global6(token,   groups) {
			groups = split(token, parts, ":")
			if (index(token, "::") == 0 && groups < 8) return 0
			return tolower(token) ~ /^[23][0-9a-f]*:/
		}
		BEGIN {
			split(resolvers, list, " ")
			for (i in list) if (list[i] != "") resolver[list[i]] = 1
		}
		# By name: an empty identities file would make FNR == NR true for
		# the report too.
		FILENAME == identities {
			if ($1 != "" && !($1 in known)) {
				known[$1] = 1
				values[++nvalues] = $1
				names[nvalues] = $2
			}
			next
		}
		!sorted {
			# longest first, so a value inside another is not replaced first
			for (i = 1; i <= nvalues; i++)
				for (j = i + 1; j <= nvalues; j++)
					if (length(values[j]) > length(values[i])) {
						t = values[i]; values[i] = values[j]; values[j] = t
						t = names[i]; names[i] = names[j]; names[j] = t
					}
			sorted = 1
		}
		/-----BEGIN / { pem = 1; print "<pem block removed>"; next }
		pem { if (/-----END /) pem = 0; next }
		{
			line = $0
			at = index(line, "=")
			if (at > 1) {
				key = tolower(substr(line, 1, at - 1))
				if (key !~ /[ \t]/ && key ~ /(password|passwd|secret|psk|token|private|key_file|eap_id)/)
					line = substr(line, 1, at) "<redacted>"
			}
			for (i = 1; i <= nvalues; i++)
				line = literal(line, values[i], names[i])
			line = scan(line, "[0-9A-Fa-f][0-9A-Fa-f](:[0-9A-Fa-f][0-9A-Fa-f])(:[0-9A-Fa-f][0-9A-Fa-f])(:[0-9A-Fa-f][0-9A-Fa-f])(:[0-9A-Fa-f][0-9A-Fa-f])(:[0-9A-Fa-f][0-9A-Fa-f])", "mac")
			line = scan(line, "[0-9][0-9]*\\.[0-9][0-9]*\\.[0-9][0-9]*\\.[0-9][0-9]*", "ip")
			line = scan(line, "[0-9A-Fa-f]*:[0-9A-Fa-f:]*:[0-9A-Fa-f]*", "ip6")
			print line
		}
	' "$1" -
}

# A set's elements are counted, not listed: learned destinations and user
# addresses are many, and they are the users' traffic.
diagnostics_collapse_sets() {
	awk '
		inset {
			n += gsub(/,/, ",")
			if (index($0, "}")) { print indent "elements = { " n " entries }"; inset = 0 }
			next
		}
		/elements = \{/ {
			indent = substr($0, 1, index($0, "elements") - 1)
			rest = substr($0, index($0, "{") + 1)
			n = gsub(/,/, ",", rest) + 1
			if (index(rest, "}")) print indent "elements = { " n " entries }"
			else inset = 1
			next
		}
		{ print }
	'
}

diagnostics_section() {
	local title="$1" rc=0
	shift
	printf '\n## %s\n' "$title"
	pkg_run_bounded 20 "$@" 2>&1 || rc=$?
	[ "$rc" = 0 ] || printf '(exit %s)\n' "$rc"
}

diagnostics_versions() {
	grep -E '^DISTRIB_(RELEASE|TARGET|ARCH)=' /etc/openwrt_release 2>/dev/null
	printf 'application=%s\n' "$(cat /usr/share/ikev2-manager/version 2>/dev/null || echo unknown)"
	uname -r
	if command -v apk >/dev/null 2>&1; then
		apk list --installed 2>/dev/null
	else
		opkg list-installed 2>/dev/null
	fi | grep -E '^(luci-app-ikev2|strongswan|sing-box|dnsproxy|dnsmasq|kmod-xfrm|ip-full|nftables|firewall4)'
}

# swanctl names every plugin it was built without on stderr.
diagnostics_swanctl() {
	swanctl "$@" 2>&1 | grep -v "^plugin '[^']*': failed to load"
}

diagnostics_routes() {
	local table routes
	ip -4 rule show
	for table in 1601 1602 51820; do
		printf -- '-- table %s\n' "$table"
		ip -4 route show table "$table"
	done
	# The tables of the other exits, those that hold a route.
	for table in 1603 1604 1605 1606 1607 1608 1609 1610 1611 1612 1613 1614 1615; do
		routes="$(ip -4 route show table "$table" 2>/dev/null || :)"
		[ -n "$routes" ] || continue
		printf -- '-- table %s\n%s\n' "$table" "$routes"
	done
	printf -- '-- addresses\n'
	ip -4 -o addr show
}

diagnostics_nft() {
	local table
	nft list tables
	for table in $(nft list tables 2>/dev/null | awk '$3 ~ /^ikev2/ { print $2 ":" $3 }'); do
		nft list table "${table%%:*}" "${table#*:}"
	done | diagnostics_collapse_sets
}

diagnostics_log() {
	logread -l 4000 2>/dev/null |
		grep -E 'ikev2|charon|ipsec|swanctl|sing-box|dnsproxy|dnsmasq\[|netifd|procd' |
		# dnsmasq lists every selected domain each time it rereads them
		grep -v -e 'using nameserver .* for domain' -e 'using only locally-known addresses' |
		tail -n 400
}

# Each tunnel's state, which tunnel each exit uses now and since when, and the
# tunnel chosen for each service and list.
diagnostics_tunnels() {
	/usr/libexec/ikev2-manager tunnels-status
	printf -- '-- selection\n'
	cat "${IKEV2_TUNNEL_STATE:-/var/run/ikev2-tunnels.state}" 2>/dev/null || :
	printf -- '-- exits\n'
	cat /etc/pbr-ikev2-exits.txt 2>/dev/null || :
}

diagnostics_action_logs() {
	local log
	for log in /tmp/ikev2-system-action.log /tmp/ikev2-domain-router.log \
		/tmp/ikev2-manager-deps.log; do
		[ -f "$log" ] || continue
		printf -- '-- %s\n' "$log"
		tail -n 80 "$log"
	done
}

diagnostics_collect() {
	printf '# IKEv2 manager diagnostics\ngenerated=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	diagnostics_section 'Versions' diagnostics_versions
	diagnostics_section 'Readiness' "$0" doctor
	diagnostics_section 'Router settings' "$0" get
	diagnostics_section 'Outbound tunnel' /usr/libexec/ikev2-manager client-get
	diagnostics_section 'Tunnels' diagnostics_tunnels
	diagnostics_section 'Security associations' diagnostics_swanctl --list-sas
	diagnostics_section 'Loaded connections' diagnostics_swanctl --list-conns
	diagnostics_section 'Domain routing' /usr/libexec/ikev2-domain-router status
	diagnostics_section 'Policy routing' /usr/libexec/ikev2-routing status
	diagnostics_section 'Device routing' /usr/libexec/ikev2-device-routing check
	diagnostics_section 'Router DNS' "$0" dns-get
	diagnostics_section 'DNS segments' "$0" dns-segments-get
	diagnostics_section 'dnsmasq' uci -q show 'dhcp.@dnsmasq[0]'
	diagnostics_section 'Rules, routes and addresses' diagnostics_routes
	diagnostics_section 'nftables' diagnostics_nft
	diagnostics_section 'Tunnel quality, last hour' /usr/libexec/ikev2-tunnel-quality summary 1h
	diagnostics_section 'Configuration' uci -q show "$config"
	diagnostics_section 'Action logs' diagnostics_action_logs
	diagnostics_section 'System log' diagnostics_log
}

diagnostics_report() {
	local identities
	identities="$(mktemp)" || die 'Unable to create a temporary file'
	diagnostics_identities >"$identities"
	diagnostics_collect | diagnostics_redact "$identities"
	rm -f "$identities"
}
