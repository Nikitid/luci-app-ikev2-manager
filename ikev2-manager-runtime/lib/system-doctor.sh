#!/bin/sh
# Readiness report of the system helper: dependency, runtime and security
# checks, and the cached copy the setup page reads. Sourced by
# ikev2-manager-system, whose configuration helpers and globals it uses.

doctor_dns_segments_status() {
	local segment_state
	segment_state="$(sed -n 's/^state=//p' "$dns_segments_status_file" 2>/dev/null |
		tail -n1)"
	case "$segment_state" in
		up | ok)
			printf 'dns_segments=ok\n'
			return 0
			;;
		degraded)
			printf 'dns_segments=degraded:%s\n' \
				"$(sed -n 's/^failure_ids=//p' "$dns_segments_status_file" | tail -n1)"
			return 1
			;;
		*)
			printf 'dns_segments=notice:not-checked-yet\n'
			return 0
			;;
	esac
}

# The installed strongSwan: one build across its packages, and versions with
# the fixes the client and the server need; then the charon that runs, which an
# upgrade that did not restart it leaves on the old version while the
# installed one, read above, is the new.
#
# A known vulnerability with no fixed package in the feed is something to
# know, not a broken router: failing the whole report for it kept the overview
# red for as long as the feed waited, and red that never clears stops being
# read. It is a warning either way; its text says whether a fixed package is
# already there to install. Sets ok and dependencies_ok of the caller.
doctor_strongswan() {
	local strongswan_version strongswan_cohort strongswan_fix running installed vulnerable=0
	strongswan_version="$(pkg_version strongswan)"
	if strongswan_cohort="$(strongswan_cohort_version 2>/dev/null)" &&
	   [ -n "$strongswan_cohort" ]; then
		printf 'strongswan_cohort=ok:%s\n' "$strongswan_cohort"
	else
		printf 'strongswan_cohort=invalid:mixed-or-missing-version\n'
		ok=0
		dependencies_ok=0
	fi
	if pkg_version_at_least strongswan 6.0.3; then
		printf 'strongswan_eap_client_security=ok:%s\n' "$strongswan_version"
	else
		printf 'strongswan_eap_client_security=warn:%s-cve-2025-62291\n' \
			"${strongswan_version:-missing}"
	fi
	if pkg_version_at_least strongswan 6.0.7; then
		printf 'strongswan_eap_server_security=ok:%s\n' "$strongswan_version"
	else
		strongswan_fix=awaiting-feed
		pkg_version_string_at_least "$(pkg_available_version strongswan)" 6.0.7 &&
			strongswan_fix=update-available
		printf 'strongswan_eap_server_security=warn:%s-cve-2026-47895-%s\n' \
			"${strongswan_version:-missing}" "$strongswan_fix"
		vulnerable=1
	fi
	[ -n "$strongswan_version" ] || return 0
	installed="${strongswan_version%-r*}"
	if ! running="$(strongswan_running_version)"; then
		printf 'strongswan_running=notice:not-answering\n'
	elif pkg_version_string_at_least "$running" "$installed"; then
		printf 'strongswan_running=ok:%s\n' "$running"
	else
		# Upgraded on disk only: the fixes arrive with the next charon
		# restart, which on some routers is a reboot (see TRAPS).
		printf 'strongswan_running=warn:%s-restart-pending-%s\n' "$running" "$installed"
		pkg_version_string_at_least "$running" 6.0.7 || vulnerable=1
	fi
	[ "$vulnerable" = 0 ] || [ "$(getv server enabled)" != 1 ] || printf 'security_ok=0\n'
}

# The version of the charon running now, as it reports itself. Bounded: an
# unanswered VICI query stalled its caller for as long as charon was wedged.
strongswan_running_version() {
	local line
	command -v swanctl >/dev/null 2>&1 || return 1
	line="$(pkg_run_bounded 3 swanctl --version --daemon 2>/dev/null | head -n1)"
	case "$line" in
		'strongSwan '[0-9]*' '*) line="${line#strongSwan }" ;;
		*) return 1 ;;
	esac
	printf '%s\n' "${line%% *}"
}

# Answer every package question of one report from a single listing; see
# pkg_cache_versions. The cache is dropped before returning, so a caller that
# goes on to install packages asks the package manager again.
# With more than one tunnel: every enabled one has its password and its link
# and is up, and every exit something is sent through has a tunnel to use. A
# router with one tunnel reports nothing here, as before there could be more.
# Prints "tunnels=ok" or "tunnels=warn:" and a comma list of N-no-password,
# N-no-link, N-down and exit-N-no-tunnel, where the exit is Ns for what is
# bound to tunnel N without backup while that tunnel is off.
doctor_tunnels() {
	local index exit problems='' sa='' sa_read=0 assigned=''
	tunnel_settings_load
	tunnel_several || return 0
	# A pause closes the tunnels; down is what it is meant to be then. With
	# charon not answering, which doctor_strongswan reports, nothing is known.
	if [ "$(defaultv domains paused 0)" != 1 ] &&
		sa="$(pkg_run_bounded 5 "${IKEV2_SA_HELPER:-/usr/libexec/ikev2-sa}" tunnels 2>/dev/null)"; then
		sa_read=1
	fi
	for index in $tunnel_on; do
		tunnel_names "$index"
		if [ "$index" != 1 ] && ! awk -F '\t' -v want="$index" '
			$1 == want && $3 != "" { found = 1 }
			END { exit !found }
		' "${IKEV2_TUNNELS_SECRET_DB:-/etc/ikev2-manager/tunnels.secret}" 2>/dev/null; then
			problems="$problems,$index-no-password"
		elif ! ip link show dev "$tunnel_link" >/dev/null 2>&1; then
			problems="$problems,$index-no-link"
		elif [ "$sa_read" = 1 ] &&
			! printf '%s\n' "$sa" | awk -F '\t' -v want="$index" '
				$1 == want && $2 == 1 { up = 1 }
				END { exit !up }
			'; then
			problems="$problems,$index-down"
		elif grep -qx "silent $index 1" "$tunnel_state_file" 2>/dev/null; then
			# Connected, and the watcher's probe finds nothing crossing it
			# while it crosses another tunnel: its exits were moved off it.
			problems="$problems,$index-silent"
		fi
	done
	# What a service, a list or a device is sent through; an exit whose tunnel
	# is not configured leaves by the first. The exits file exists only once a
	# service was sent elsewhere, and under set -e a failed read would end the
	# list before the devices.
	assigned="$(
		exits="${IKEV2_EXITS_FILE:-/etc/pbr-ikev2-exits.txt}"
		{ [ ! -r "$exits" ] || awk '{ print $2 }' "$exits"
		  device_fullroute_exits 2>/dev/null | awk '{ print $2 }'; } | sort -u
	)"
	for exit in $tunnel_exit_order; do
		case " $(printf '%s' "$assigned" | tr '\n' ' ') " in *" $exit "*) ;; *) continue ;; esac
		case " $tunnel_exits " in *" $exit "*) ;; *) continue ;; esac
		tunnel_exit_chain "$exit"
		[ -n "$tunnel_chain" ] || problems="$problems,exit-$exit-no-tunnel"
	done
	if [ -n "$problems" ]; then
		printf 'tunnels=warn:%s\n' "${problems#,}"
	else
		printf 'tunnels=ok\n'
	fi
}

doctor() {
	local doctor_rc=0
	pkg_cache_versions
	doctor_checks || doctor_rc=$?
	pkg_cache_clear
	return "$doctor_rc"
}

doctor_checks() {
	ok=1
	dependencies_ok=1
	check_command() {
		name="$1"
		command="$2"
		if command -v "$command" >/dev/null 2>&1; then
			printf '%s=ok\n' "$name"
		else
			printf '%s=missing\n' "$name"
			ok=0
			dependencies_ok=0
		fi
	}
	check_file() {
		name="$1"
		path="$2"
		if [ -e "$path" ]; then
			printf '%s=ok\n' "$name"
		else
			printf '%s=missing\n' "$name"
			ok=0
			dependencies_ok=0
		fi
	}

	compatibility_checks
	upnp_ikev2_check || ok=0

	check_command firewall4 fw4
	check_command ip_full ip
	check_command nft nft
	check_command swanctl swanctl
	check_command socat socat
	check_command conntrack conntrack
	check_command openssl openssl
	check_command jsonfilter jsonfilter
	check_command swanmon swanmon
	check_command dnsproxy dnsproxy
	check_command sing_box sing-box
	if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
		printf 'curl=ok\n'
	else
		printf 'curl=missing\n'
		ok=0
		dependencies_ok=0
	fi
	if find /lib/modules/"$(uname -r)" -name 'xfrm_interface.ko*' -print 2>/dev/null |
		grep -q .; then
		printf 'xfrm_module=ok\n'
	else
		printf 'xfrm_module=missing\n'
		ok=0
		dependencies_ok=0
	fi
	# The application routes on its own; PBR is not needed at all.
	if [ "$(getv globals configured)" != 1 ]; then
		:
	elif [ -x "$routing_runtime_helper" ] && "$routing_runtime_helper" check >/dev/null 2>&1; then
		printf 'policy_routing_runtime=ok\n'
	elif [ "${IKEV2_DOCTOR_ALLOW_RUNTIME_REPAIR:-0}" = 1 ]; then
		printf 'policy_routing_runtime=warn:repair-required\n'
	else
		printf 'policy_routing_runtime=missing\n'
		ok=0
	fi
	if command -v fw4 >/dev/null 2>&1; then
		if firewall_check_strict; then
			printf 'firewall4_config=ok\n'
		else
			printf 'firewall4_config=invalid\n'
			ok=0
		fi
	fi
	if [ "$(getv globals configured)" = 1 ]; then
		if [ ! -x "$device_runtime_helper" ]; then
			printf 'device_policy_runtime=missing-helper\n'
			ok=0
		elif "$device_runtime_helper" check >/dev/null 2>&1; then
			printf 'device_policy_runtime=ok\n'
		elif [ "${IKEV2_DOCTOR_ALLOW_RUNTIME_REPAIR:-0}" = 1 ]; then
			printf 'device_policy_runtime=warn:repair-required\n'
		else
			printf 'device_policy_runtime=missing\n'
			ok=0
		fi
		if [ "$(defaultv dns managed 0)" = 1 ]; then
			if [ "${IKEV2_DOCTOR_SKIP_PROBES:-0}" = 1 ]; then
				if ! doctor_dns_segments_status; then
					ok=0
				fi
			elif dns_segments_check; then
				printf 'dns_segments=ok\n'
			elif [ "${IKEV2_DOCTOR_ALLOW_RUNTIME_REPAIR:-0}" = 1 ]; then
				# Enabling managed mode starts the resolvers the segments use.
				# Checked before that, every segment of a router that was just
				# unmanaged reads as down, and managed mode could never come back.
				printf 'dns_segments=warn:repair-required\n'
			else
				printf 'dns_segments=degraded:%s\n' \
					"$(sed -n 's/^failure_ids=//p' "$dns_segments_status_file" | tail -n1)"
				ok=0
			fi
		fi
	fi

	# PBR still holding policies of a release that routed through it routes
	# the same destinations behind ours until the next Apply retires them.
	if [ "$(getv globals configured)" = 1 ] && pbr_holds_ours; then
		printf 'pbr_policies=notice:retired-at-next-apply\n'
	fi
	sing_box_version="$(pkg_version sing-box)"
	if pkg_version_at_least sing-box 1.13.19; then
		printf 'sing_box_fakeip=ok:%s-upstream-fix\n' "$sing_box_version"
	elif [ "$(defaultv domains engine nftset)" = fakeip ]; then
		printf 'sing_box_fakeip=invalid:%s-metadata-save-race\n' \
			"${sing_box_version:-missing}"
		ok=0
	else
		printf 'sing_box_fakeip=notice:%s\n' "${sing_box_version:-missing}"
	fi
	# Report the watcher's last result instead of probing here: the canary
	# crosses the tunnel, and this report also feeds the setup page.
	if [ "$(defaultv domains engine nftset)" = fakeip ] &&
	     [ -x /usr/libexec/ikev2-domain-router ]; then
		case "$(/usr/libexec/ikev2-domain-router data-plane-state 2>/dev/null)" in
			ok) printf 'fakeip_data_plane=ok\n' ;;
			degraded | restarting | restarted) printf 'fakeip_data_plane=warn:degraded\n' ;;
			tunnel-dns-down) printf 'fakeip_data_plane=warn:tunnel-dns-down\n' ;;
			tunnel-down) printf 'fakeip_data_plane=notice:tunnel-down\n' ;;
			*) printf 'fakeip_data_plane=notice:unchecked\n' ;;
		esac
	fi
	doctor_strongswan
	if [ "$(getv globals configured)" = 1 ]; then
		# A pause leaves the fail-closed routes in place and refuses what reaches
		# the tunnel; the block is reported, and the watcher restores it.
		if [ "$(defaultv domains paused 0)" = 1 ]; then
			if pause_block_present; then
				printf 'routing_pause=notice:blocking\n'
			else
				printf 'routing_pause=warn:block-missing\n'
			fi
		fi
		if failclosed_check; then
			printf 'failclosed_route=ok\n'
		else
			# Report drift without blocking apply_system, which is the repair
			# path that recreates the PBR table and validates it afterwards.
			printf 'failclosed_route=warn:missing\n'
			[ "${IKEV2_DOCTOR_ALLOW_RUNTIME_REPAIR:-0}" = 1 ] || ok=0
		fi
		if failclosed_ipv6_check; then
			printf 'failclosed_ipv6_route=ok\n'
		else
			printf 'failclosed_ipv6_route=warn:missing\n'
			[ "${IKEV2_DOCTOR_ALLOW_RUNTIME_REPAIR:-0}" = 1 ] || ok=0
		fi
		# The virtual IP belongs to ipsec-out alone. A copy on another interface
		# means charon installs it itself, and then removes it on every SA
		# teardown: the drop-in that disables that is not being read.
		tunnel_vip="$(cat /var/run/ikev2-vip4 2>/dev/null || true)"
		if [ -n "$tunnel_vip" ]; then
			if ip -4 -o addr show to "$tunnel_vip/32" 2>/dev/null |
				awk '{ print $2 }' | grep -vqx ipsec-out; then
				printf 'tunnel_vip_placement=warn:charon-managed\n'
			else
				printf 'tunnel_vip_placement=ok\n'
			fi
		fi
		doctor_tunnels
	fi

	# Reserved XFRM if_id 42 (ipsec-out), 43 (ipsec-in) and 52-57 (ipsec-out2
	# to ipsec-out7, see tunnel.sh). A foreign xfrm interface holding one
	# collides with the ones this app creates.
	xfrm_conflict="$(
		ip -d link show type xfrm 2>/dev/null | awk '
			/^[0-9]+:/ { name = $2; sub(/@.*/, "", name); sub(/:$/, "", name); next }
			/if_id/ {
				for (i = 1; i <= NF; i++)
					if ($i == "if_id") id = $(i + 1)
				n = (id ~ /^0x/) ? sprintf("%d", strtonum_hex(id)) : id + 0
				if (n == 42 && name == "ipsec-out") next
				if (n == 43 && name == "ipsec-in") next
				if (n >= 52 && n <= 57 && name == "ipsec-out" (n - 50)) next
				if (n == 42 || n == 43 || (n >= 52 && n <= 57))
					print name ":" id
			}
			function strtonum_hex(h,   i, c, v) {
				v = 0
				h = tolower(substr(h, 3))
				for (i = 1; i <= length(h); i++) {
					c = index("0123456789abcdef", substr(h, i, 1)) - 1
					if (c < 0) return -1
					v = v * 16 + c
				}
				return v
			}
		'
	)"
	if [ -n "$xfrm_conflict" ]; then
		printf 'xfrm_ifid_conflict=%s\n' "$(printf '%s' "$xfrm_conflict" | tr '\n' ',')"
		ok=0
	else
		printf 'xfrm_ifid_conflict=none\n'
	fi

	xfrm_name_conflicts=''
	for name_id in 'ipsec-out:42:0x2a' 'ipsec-in:43:0x2b' 'ipsec-out2:52:0x34' \
		'ipsec-out3:53:0x35' 'ipsec-out4:54:0x36' 'ipsec-out5:55:0x37' \
		'ipsec-out6:56:0x38' 'ipsec-out7:57:0x39'; do
		name="${name_id%%:*}"
		rest="${name_id#*:}"
		expected_dec="${rest%%:*}"
		expected_hex="${rest#*:}"
		link="$(ip -d link show dev "$name" 2>/dev/null || true)"
		[ -n "$link" ] || continue
		if ! printf '%s\n' "$link" | grep -q ' xfrm '; then
			xfrm_name_conflicts="${xfrm_name_conflicts}${name}:not-xfrm,"
			continue
		fi
		actual="$(printf '%s\n' "$link" |
			awk '/if_id/ { for (i=1; i<=NF; i++) if ($i=="if_id") { print $(i+1); exit } }')"
		[ "$actual" = "$expected_dec" ] || [ "$actual" = "$expected_hex" ] ||
			xfrm_name_conflicts="${xfrm_name_conflicts}${name}:${actual:-unknown},"
	done
	if [ -n "$xfrm_name_conflicts" ]; then
		printf 'xfrm_name_conflict=%s\n' "${xfrm_name_conflicts%,}"
		ok=0
	else
		printf 'xfrm_name_conflict=none\n'
	fi

	if pkg_dnsmasq_has_nftset; then
		printf 'dnsmasq_nftset=ok\n'
	else
		printf 'dnsmasq_nftset=missing\n'
		ok=0
		dependencies_ok=0
	fi
	if lsmod 2>/dev/null | grep -Eq '^(nft_tproxy|nf_tproxy_ipv4) '; then
		printf 'nft_tproxy=ok\n'
	else
		printf 'nft_tproxy=missing\n'
		ok=0
		dependencies_ok=0
	fi

	for plugin in kernel-netlink vici openssl eap-mschapv2 x509; do
		if find /usr/lib/ipsec/plugins -name "libstrongswan-${plugin}.so" -print 2>/dev/null |
			grep -q .; then
			printf 'strongswan_%s=ok\n' "$(sanitize "$plugin")"
		else
			printf 'strongswan_%s=missing\n' "$(sanitize "$plugin")"
			ok=0
			dependencies_ok=0
		fi
	done

	printf 'configured=%s\n' "$(getv globals configured)"
	printf 'dependencies_ok=%s\n' "$dependencies_ok"
	printf 'doctor_ok=%s\n' "$ok"
	[ "$ok" -eq 1 ]
}

doctor_ui_cache_invalidate() {
	rm -f "$doctor_ui_cache_file"
}

# Compute the report the setup page shows and store it for doctor_ui_report.
doctor_ui_write_cache() {
	local tmp result=ok
	tmp="${doctor_ui_cache_file}.new.$$"
	mkdir -p "${doctor_ui_cache_file%/*}"
	IKEV2_DOCTOR_SKIP_PROBES=1
	export IKEV2_DOCTOR_SKIP_PROBES
	doctor >"$tmp" || result=degraded
	printf 'diagnostic_status=%s\n' "$result" >>"$tmp"
	mv "$tmp" "$doctor_ui_cache_file"
}

# Refresh the stored report behind the page. The worker takes the lock itself,
# so a second stale read while one refresh runs starts nothing new.
doctor_ui_refresh_background() {
	if command -v start-stop-daemon >/dev/null 2>&1; then
		start-stop-daemon -b -q -S -x "$0" -- _doctor-ui-refresh || :
	else
		setsid "$0" _doctor-ui-refresh </dev/null >/dev/null 2>&1 &
	fi
}

# The setup page never waits for the full report once one exists. A fresh copy
# is returned as is; an expired one is returned too, and replaced in the
# background for the next load. Only a missing copy - no report yet, or one an
# action has just invalidated - is computed while the page waits, so the first
# load after a change is never stale.
doctor_ui_report() {
	local now modified ttl=300
	if [ -s "$doctor_ui_cache_file" ]; then
		now="$(date +%s)"
		modified="$(date -r "$doctor_ui_cache_file" +%s 2>/dev/null ||
			stat -c %Y "$doctor_ui_cache_file" 2>/dev/null ||
			stat -f %m "$doctor_ui_cache_file" 2>/dev/null || true)"
		case "$modified" in '' | *[!0-9]*) modified=0 ;; esac
		cat "$doctor_ui_cache_file"
		[ $((now - modified)) -le "$ttl" ] || doctor_ui_refresh_background
		return 0
	fi
	doctor_ui_write_cache
	cat "$doctor_ui_cache_file"
}
