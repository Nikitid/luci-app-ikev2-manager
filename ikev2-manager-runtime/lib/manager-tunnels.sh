#!/bin/sh
# Outbound tunnels after the first: their strongSwan connections and secrets,
# and bringing them up. Tunnel 1 is the client section and keeps its own code
# in ikev2-manager. Sourced by ikev2-manager, whose configuration helpers and
# globals it uses, after tunnel.sh.

extra_tunnels_conf="$root/etc/swanctl/conf.d/21-proxy-out-extra.conf"
extra_tunnels_secret="$root/etc/swanctl/conf.d/92-proxy-out-extra-secret.conf"
# One line per tunnel: index, EAP identity, the password as a swanctl 0s value.
tunnels_secret_db="$root/etc/ikev2-manager/tunnels.secret"
tunnel_attempt_dir="${IKEV2_TUNNEL_ATTEMPT_DIR:-/var/run/ikev2-tunnel-attempt}"

# The indexes of the configured tunnel sections after the first, in order.
extra_tunnel_indexes() {
	uci -q show "$uci_config" 2>/dev/null |
		sed -n "s/^$uci_config\\.tunnel_\\([2-8]\\)=tunnel\$/\\1/p" | sort -n
}

extra_tunnels_enabled() {
	local index
	for index in $(extra_tunnel_indexes); do
		[ "$(getv "tunnel_$index" enabled)" = 1 ] && echo "$index"
	done
	return 0
}

# Whether the EAP secrets have to name the server as well as the user: two
# tunnels with the same user name and different passwords are otherwise one
# match each, and strongSwan takes whichever it finds first.
tunnel_secrets_need_server() {
	[ -n "$(extra_tunnels_enabled)" ]
}

tunnel_secret_get() {
	local index="$1" line_index line_user line_secret
	[ -r "$tunnels_secret_db" ] || return 1
	while IFS="$(printf '\t')" read -r line_index line_user line_secret; do
		[ "$line_index" = "$index" ] || continue
		printf '%s\t%s\n' "$line_user" "$line_secret"
		return 0
	done <"$tunnels_secret_db"
	return 1
}

# tunnel_secret_put INDEX USER [PASSWORD]: without a password the stored one
# is kept under the new user name.
tunnel_secret_put() {
	local index="$1" username="$2" password="${3-}" encoded='' line_index line_user line_secret
	if [ -n "$password" ]; then
		encoded="0s$(printf '%s' "$password" | openssl base64 -A)" || return 1
	elif ! encoded="$(tunnel_secret_get "$index" | cut -f2)" || [ -z "$encoded" ]; then
		return 0
	fi
	mkdir -p "${tunnels_secret_db%/*}" || return 1
	{
		if [ -r "$tunnels_secret_db" ]; then
			while IFS="$(printf '\t')" read -r line_index line_user line_secret; do
				[ "$line_index" = "$index" ] ||
					printf '%s\t%s\t%s\n' "$line_index" "$line_user" "$line_secret"
			done <"$tunnels_secret_db"
		fi
		printf '%s\t%s\t%s\n' "$index" "$username" "$encoded"
	} >"$tunnels_secret_db.new" || return 1
	atomic_install "$tunnels_secret_db.new" "$tunnels_secret_db" 600
}

tunnel_secret_delete() {
	local index="$1" line_index line_user line_secret
	[ -r "$tunnels_secret_db" ] || return 0
	while IFS="$(printf '\t')" read -r line_index line_user line_secret; do
		[ "$line_index" = "$index" ] ||
			printf '%s\t%s\t%s\n' "$line_index" "$line_user" "$line_secret"
	done <"$tunnels_secret_db" >"$tunnels_secret_db.new" || return 1
	atomic_install "$tunnels_secret_db.new" "$tunnels_secret_db" 600
}

# Every enabled tunnel after the first, with the same proposals and lifetimes
# as the first, on its own XFRM interface.
render_extra_tunnels() {
	local tmp="${extra_tunnels_conf}.new" secret_tmp="${extra_tunnels_secret}.new"
	local index remote_address remote_id username dpd remote_addrs secret count=0
	{
		echo '# Managed by IKEv2 Manager. Outbound tunnels after the first.'
		echo 'connections {'
	} >"$tmp" || return 1
	{
		echo '# Managed by IKEv2 Manager. Secrets of the outbound tunnels after the first.'
		echo 'secrets {'
	} >"$secret_tmp" || return 1
	if [ -n "$(extra_tunnels_enabled)" ] &&
	   "$system_helper" strongswan-security client >/dev/null 2>&1; then
		sync_client_ca || return 1
		for index in $(extra_tunnels_enabled); do
			tunnel_names "$index"
			remote_address="$(getv "$tunnel_section" remote_address)"
			remote_id="$(getv "$tunnel_section" remote_id)"
			username="$(getv "$tunnel_section" username)"
			dpd="$(getv_default "$tunnel_section" dpd 30)"
			remote_addrs="$(normalize_host_list "$remote_address" | sed 's/ /, /g')"
			[ -n "$remote_addrs" ] && [ -n "$remote_id" ] && [ -n "$username" ] || continue
			cat >>"$tmp" <<EOF
	$tunnel_conn {
		version = 2
		remote_addrs = $remote_addrs
		proposals = aes256gcm16-prfsha384-ecp384
		vips = 0.0.0.0
		mobike = yes
		fragmentation = yes
		dpd_delay = ${dpd}s
		reauth_time = 0
		keyingtries = 0

		local {
			auth = eap-mschapv2
			id = $username
			eap_id = $username
		}

		remote {
			auth = pubkey
			id = $remote_id
		}

		children {
			$tunnel_child {
				local_ts = 0.0.0.0/0
				remote_ts = 0.0.0.0/0
				esp_proposals = aes256gcm16-ecp384
				if_id_in = $tunnel_if_id
				if_id_out = $tunnel_if_id
				start_action = start
				dpd_action = restart
				close_action = start
			}
		}
	}
EOF
			count=$((count + 1))
			secret="$(tunnel_secret_get "$index" | cut -f2)" || secret=''
			[ -n "$secret" ] || continue
			cat >>"$secret_tmp" <<EOF
	eap-$tunnel_conn {
		id-user = "$username"
		id-server = "$remote_id"
		secret = $secret
	}
EOF
		done
	fi
	echo '}' >>"$tmp" || return 1
	echo '}' >>"$secret_tmp" || return 1
	atomic_install "$secret_tmp" "$extra_tunnels_secret" 600 || return 1
	atomic_install "$tmp" "$extra_tunnels_conf" 600
}

# Bring up every enabled tunnel after the first that has no CHILD_SA, each at
# most once per its own cooldown. Called by ensure-client, which holds the
# auto-connect lock.
ensure_extra_tunnels() {
	local index now last cooldown rc=0
	[ -n "$(extra_tunnels_enabled)" ] || return 0
	mkdir -p "$tunnel_attempt_dir" || return 1
	for index in $(extra_tunnels_enabled); do
		tunnel_names "$index"
		"$sa_helper" installed "$tunnel_conn" "$tunnel_child" && continue
		now="$(date +%s)"
		cooldown="$(getv_default "$tunnel_section" reconnect_cooldown 15)"
		in_range "$cooldown" 15 300 || cooldown=15
		last="$(cat "$tunnel_attempt_dir/$index" 2>/dev/null || echo 0)"
		case "$last" in '' | *[!0-9]*) last=0 ;; esac
		[ $((now - last)) -ge "$cooldown" ] || continue
		# WAN hotplug and the watcher can both get here: the first to claim the
		# tunnel initiates it.
		if ! mkdir "$tunnel_attempt_dir/$index.lock" 2>/dev/null; then
			last="$(cat "$tunnel_attempt_dir/$index.lock/pid" 2>/dev/null || :)"
			[ -z "$last" ] || ! kill -0 "$last" 2>/dev/null || continue
			rm -f "$tunnel_attempt_dir/$index.lock/pid"
			rmdir "$tunnel_attempt_dir/$index.lock" 2>/dev/null || continue
			mkdir "$tunnel_attempt_dir/$index.lock" 2>/dev/null || continue
		fi
		printf '%s\n' "$$" >"$tunnel_attempt_dir/$index.lock/pid"
		printf '%s\n' "$now" >"$tunnel_attempt_dir/$index"
		swanctl --initiate --child "$tunnel_child" --timeout 20 >/dev/null 2>&1 || rc=1
		rm -f "$tunnel_attempt_dir/$index.lock/pid"
		rmdir "$tunnel_attempt_dir/$index.lock" 2>/dev/null || :
	done
	return "$rc"
}

# The settings of every tunnel after the first, one "key=value" per line,
# each tunnel opened by "tunnel=N". The password is never printed.
tunnels_get() {
	local index key
	for index in $(extra_tunnel_indexes); do
		printf 'tunnel=%s\n' "$index"
		for key in name enabled remote_address remote_id username; do
			printf '%s=%s\n' "$key" "$(getv "tunnel_$index" "$key")"
		done
		printf 'dpd=%s\n' "$(getv_default "tunnel_$index" dpd 30)"
		printf 'mtu=%s\n' "$(getv_default "tunnel_$index" mtu 1400)"
		printf 'backup=%s\n' "$(getv_default "tunnel_$index" backup 1)"
		if tunnel_secret_get "$index" >/dev/null; then
			printf 'password_set=1\n'
		else
			printf 'password_set=0\n'
		fi
	done
}

# The first tunnel index not configured, for a new tunnel.
free_tunnel_index() {
	local index
	for index in 2 3 4 5 6 7 8; do
		uci -q get "$uci_config.tunnel_$index" >/dev/null 2>&1 || {
			echo "$index"
			return 0
		}
	done
	return 1
}

valid_tunnel_name() {
	[ -n "$1" ] && [ "${#1}" -le 32 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9 _.-]*$'
}

restore_tunnels_state() {
	local directory="$1"
	restored=1
	uci -q revert "$uci_config" >/dev/null 2>&1 || true
	restore_path "$uci_config_dir/$uci_config" "$directory" uci || restored=0
	restore_path "$tunnels_secret_db" "$directory" secret || restored=0
	restore_path "$extra_tunnels_conf" "$directory" profile || restored=0
	restore_path "$extra_tunnels_secret" "$directory" rendered_secret || restored=0
	restore_path "$outbound_secret" "$directory" client_secret || restored=0
	[ "$restored" -eq 1 ]
}

# Input lines: action (save or delete), tunnel index or "new", name, enabled,
# remote addresses, remote identity, user name, DPD, MTU, backup, password
# (empty keeps the stored one).
consume_tunnel_input() {
	local input="$1" action index name enabled remote_address remote_id username dpd mtu backup password extra
	[ -f "$input" ] || die 'Tunnel input is missing'
	[ ! -L "$input" ] || die 'Tunnel input must not be a symbolic link'
	input_bytes="$(wc -c <"$input" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) die 'Invalid tunnel input size' ;; esac
	[ "$input_bytes" -le 8192 ] || {
		rm -f "$input"
		die 'Tunnel input is too large'
	}
	chmod 600 "$input" || die 'Unable to protect tunnel input'
	action="$(sed -n '1p' "$input")"
	index="$(sed -n '2p' "$input")"
	name="$(sed -n '3p' "$input")"
	enabled="$(sed -n '4p' "$input")"
	remote_address="$(sed -n '5p' "$input")"
	remote_id="$(sed -n '6p' "$input")"
	username="$(sed -n '7p' "$input")"
	dpd="$(sed -n '8p' "$input")"
	mtu="$(sed -n '9p' "$input")"
	backup="$(sed -n '10p' "$input")"
	password="$(sed -n '11p' "$input")"
	extra="$(sed -n '12,$p' "$input" | sed '/^[[:space:]]*$/d')"
	rm -f "$input"
	[ -z "$extra" ] || die 'Tunnel input contains unexpected fields'

	[ "$(getv globals configured)" = 1 ] || die 'Complete and enable Overview first'
	case "$action" in
		save | delete) ;;
		*) die 'Invalid tunnel action' ;;
	esac
	case "$index" in
		new)
			[ "$action" = save ] || die 'Invalid tunnel'
			index="$(free_tunnel_index)" || die 'At most eight tunnels can be configured'
			;;
		[2-8])
			uci -q get "$uci_config.tunnel_$index" >/dev/null 2>&1 || die 'Unknown tunnel'
			;;
		*) die 'Invalid tunnel' ;;
	esac
	if [ "$action" = save ]; then
		valid_tunnel_name "$name" || die 'Tunnel name: letters, digits, spaces, dots, dashes, up to 32 characters'
		[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || die 'Invalid enabled value'
		valid_host_list "$remote_address" || die 'Invalid remote address list'
		valid_host "$remote_id" || die 'Invalid remote identity'
		valid_user "$username" || die 'Invalid username'
		[ -z "$password" ] || valid_password "$password" ||
			die 'Password must be at most 256 characters without control characters'
		[ -n "$password" ] || tunnel_secret_get "$index" >/dev/null ||
			die 'EAP password is required for a new tunnel'
		in_range "$dpd" 10 300 || die 'DPD must be 10-300 seconds'
		in_range "$mtu" 1280 1500 || die 'MTU must be 1280-1500'
		[ "$backup" = 0 ] || [ "$backup" = 1 ] || die 'Invalid backup value'
	fi

	pid_lock_acquire "$config_lock_dir" ||
		die 'Another configuration change is already in progress'
	tunnel_state="$(mktemp -d)" || {
		pid_lock_release "$config_lock_dir"
		die 'Unable to prepare tunnel configuration rollback'
	}
	if ! snapshot_path "$uci_config_dir/$uci_config" "$tunnel_state" uci ||
	   ! snapshot_path "$tunnels_secret_db" "$tunnel_state" secret ||
	   ! snapshot_path "$extra_tunnels_conf" "$tunnel_state" profile ||
	   ! snapshot_path "$extra_tunnels_secret" "$tunnel_state" rendered_secret ||
	   ! snapshot_path "$outbound_secret" "$tunnel_state" client_secret; then
		rm -rf "$tunnel_state"
		pid_lock_release "$config_lock_dir"
		die 'Unable to back up current tunnel configuration'
	fi
	trap 'restore_tunnels_state "$tunnel_state"; rm -rf "$tunnel_state"; pid_lock_release "$config_lock_dir"; exit 1' INT TERM HUP
	if ! commit_tunnel_settings "$action" "$index"; then
		tunnels_restored=0
		restore_tunnels_state "$tunnel_state" && tunnels_restored=1
		rm -rf "$tunnel_state"
		pid_lock_release "$config_lock_dir"
		trap - INT TERM HUP
		[ "$tunnels_restored" = 1 ] &&
			die 'Unable to save tunnel settings; previous configuration restored'
		die 'Unable to save tunnel settings and automatic rollback was incomplete'
	fi
	rm -rf "$tunnel_state"
	pid_lock_release "$config_lock_dir"
	trap - INT TERM HUP
	printf 'tunnel=%s\n' "$index"
	start_action tunnels-apply
}

commit_tunnel_settings() {
	local action="$1" index="$2" section="tunnel_$2"
	if [ "$action" = delete ]; then
		uci delete "$uci_config.$section" || return 1
		uci commit "$uci_config" || return 1
		tunnel_secret_delete "$index" || return 1
	else
		uci set "$uci_config.$section=tunnel" || return 1
		uci set "$uci_config.$section.name=$name" || return 1
		uci set "$uci_config.$section.enabled=$enabled" || return 1
		uci set "$uci_config.$section.remote_address=$(normalize_host_list "$remote_address")" || return 1
		uci set "$uci_config.$section.remote_id=$remote_id" || return 1
		uci set "$uci_config.$section.username=$username" || return 1
		uci set "$uci_config.$section.dpd=$dpd" || return 1
		uci set "$uci_config.$section.mtu=$mtu" || return 1
		uci set "$uci_config.$section.backup=$backup" || return 1
		uci commit "$uci_config" || return 1
		tunnel_secret_put "$index" "$username" "$password" || return 1
	fi
	render_client_secret || return 1
	render_extra_tunnels
}

# Put the tunnels into effect: their links, the firewall zone, strongSwan,
# routing and the FakeIP resolver, which has an outbound per tunnel. A tunnel
# disabled or removed has its IKE_SA ended and its address taken off its link.
tunnels_apply_action() {
	local index rc=0
	/etc/init.d/ikev2-xfrm start || return 1
	"$system_helper" _sync-firewall || return 1
	swanctl_quiet --load-all >/dev/null || return 1
	for index in 2 3 4 5 6 7 8; do
		[ "$(getv "tunnel_$index" enabled)" != 1 ] || continue
		tunnel_names "$index"
		if "$sa_helper" present "$tunnel_conn"; then
			swanctl_quiet --terminate --ike "$tunnel_conn" --timeout 5 >/dev/null 2>&1 || :
		fi
		rm -f "/var/run/ikev2-vip4-$index"
		ip -4 addr flush dev "$tunnel_link" scope global 2>/dev/null || :
	done
	ensure_extra_tunnels || rc=1
	/usr/libexec/ikev2-sync-vips || :
	/usr/libexec/ikev2-routing sync-all || return 1
	/usr/libexec/ikev2-domain-router refresh || return 1
	return "$rc"
}
