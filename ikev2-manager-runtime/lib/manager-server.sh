#!/bin/sh
# Inbound server configuration for the LuCI backend: the rendered swanctl
# connection, the server certificate and the settings transaction. Sourced by
# ikev2-manager, whose configuration helpers and globals it uses.

# One inbound connection: its name, the peer identities it answers to and the
# networks it offers. Both connections share the pool, the certificate and the
# EAP accounts.
server_connection() {
	cat <<EOF
	$1 {
		version = 2
		send_cert = always
		proposals = aes256gcm16-prfsha384-ecp384,aes256-sha256-modp2048
		# Managed users are device-specific. Replace a stale SA for the same EAP
		# identity before its virtual address can conflict with a reconnect.
		unique = replace
		dpd_delay = ${dpd}s
		rekey_time = ${ike_rekey}s
		mobike = $([ "$mobike" = 1 ] && echo yes || echo no)
		fragmentation = $([ "$fragmentation" = 1 ] && echo yes || echo no)
		pools = router_pool4

		local {
			auth = pubkey
			certs = ikev2.pem
			id = $identity
		}

		remote {
			auth = eap-mschapv2
			eap_id = %any
			id = $2
		}

		children {
			net {
				esp_proposals = aes256gcm16-ecp384,aes256gcm16-ecp256,aes256gcm16-modp2048,aes256gcm16,aes256-sha256-modp2048,aes256-sha256
				local_ts = $3
				if_id_in = 43
				if_id_out = 43
				rekey_time = ${child_rekey}s
				dpd_action = clear
				start_action = none
			}
			}
		}
EOF
}

render_server() {
	enabled="$(getv server enabled)"
	tmp="${inbound_conf}.new"

	if [ "$enabled" != 1 ]; then
		echo '# Managed by IKEv2 Manager. Inbound server is disabled.' >"$tmp"
		atomic_install "$tmp" "$inbound_conf" 600
		return
	fi

	if [ "$(getv_default server custom_config 0)" = 1 ]; then
		[ -s "$inbound_custom" ] || die 'Inbound custom configuration is missing'
		cp "$inbound_custom" "$tmp"
		atomic_install "$tmp" "$inbound_conf" 600
		return
	fi

	identity="$(getv server identity)"
	pool4="$(getv server pool4)"
	dns4="$(getv server dns4)"
	dpd="$(getv server dpd)"
	ike_rekey="$(getv server ike_rekey)"
	child_rekey="$(getv server child_rekey)"
	mobike="$(getv server mobike)"
	fragmentation="$(getv server fragmentation)"
	local_ts="$(normalize_list "$(getv_default server local_ts 0.0.0.0/0)" | sed 's/ /, /g')"
	managed_subnet=''
	if [ -f "$root/etc/ikev2-manager/clients/initialized" ]; then
		managed_subnet="$(ucode "${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}/client-access-runtime.uc" subnet "$root/etc/ikev2-manager/clients" '' '' 2>/dev/null)" || managed_subnet=''
		valid_ipv4_cidr_list "$managed_subnet" || managed_subnet=''
	fi
	{
		printf 'connections {\n'
		server_connection ikev2-in %any "$local_ts"
		# Managed desktop devices name themselves in this domain and are offered
		# the virtual subnet alone: a client that takes its routes from the
		# traffic selectors then sends nothing else into the tunnel.
		[ -z "$managed_subnet" ] || server_connection ikev2-in-managed '*@managed.ikev2-manager' "$managed_subnet"
		printf '}\n'
		cat <<EOF
pools {
	router_pool4 {
		addrs = $pool4
		dns = $dns4
	}
}
EOF
	} >"$tmp"
	atomic_install "$tmp" "$inbound_conf" 600
}

validate_server_certificate_files() {
	local cert="$1" key="$2" identity="$3" work
	work="$(mktemp -d)" || return 1
	if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1 ||
	   ! openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1 ||
	   ! openssl pkey -in "$key" -noout >/dev/null 2>&1 ||
	   ! openssl x509 -in "$cert" -pubkey -noout 2>/dev/null |
		openssl pkey -pubin -outform DER >"$work/cert.pub" 2>/dev/null ||
	   ! openssl pkey -in "$key" -pubout -outform DER >"$work/key.pub" 2>/dev/null ||
	   ! cmp -s "$work/cert.pub" "$work/key.pub"; then
		rm -rf "$work"
		return 1
	fi
	if valid_ipv4 "$identity" || valid_ipv6 "$identity"; then
		openssl x509 -in "$cert" -checkip "$identity" -noout >/dev/null 2>&1 || {
			rm -rf "$work"
			return 1
		}
	else
		openssl x509 -in "$cert" -checkhost "$identity" -noout >/dev/null 2>&1 || {
			rm -rf "$work"
			return 1
		}
	fi
	rm -rf "$work"
}

restore_server_certificate_backup() {
	local stage="$1" x509_dir="$2" private_dir="$3" ca_dir="$4" old
	rm -f "$x509_dir/ikev2.pem" "$private_dir/ikev2.key" \
		"$ca_dir"/ikev2-server-chain-*.pem
	[ ! -f "$stage/backup/ikev2.pem" ] ||
		cp "$stage/backup/ikev2.pem" "$x509_dir/ikev2.pem"
	[ ! -f "$stage/backup/ikev2.key" ] ||
		cp "$stage/backup/ikev2.key" "$private_dir/ikev2.key"
	for old in "$stage/backup"/ikev2-server-chain-*.pem; do
		[ -f "$old" ] && cp "$old" "$ca_dir/${old##*/}"
	done
}

certificate_is_self_signed() {
	local pem="$1" subject issuer
	subject="$(openssl x509 -in "$pem" -noout -subject -nameopt RFC2253 2>/dev/null |
		sed 's/^subject=//')"
	issuer="$(openssl x509 -in "$pem" -noout -issuer -nameopt RFC2253 2>/dev/null |
		sed 's/^issuer=//')"
	[ -n "$subject" ] && [ "$subject" = "$issuer" ] || return 1
	openssl verify -CAfile "$pem" "$pem" >/dev/null 2>&1
}

certificate_is_issued_by() {
	local certificate="$1" issuer="$2"
	openssl verify -partial_chain -CAfile "$issuer" "$certificate" >/dev/null 2>&1
}

sync_server_certificate() {
	local identity cert_file key_file cert_source x509_dir ca_dir private_dir
	local stage index current line chain_index pem old certificate_index
	[ "$(getv server enabled)" = 1 ] || return 0
	identity="$(getv server identity)"
	cert_file="$(getv server cert_file)"
	key_file="$(getv server key_file)"
	cert_source="$(getv server cert_source)"
	[ -n "$cert_file" ] || cert_file="$cert_source/$identity.fullchain.crt"
	[ -n "$key_file" ] || key_file="$cert_source/$identity.key"
	[ -s "$cert_file" ] || die "Server certificate not found: $cert_file"
	[ -s "$key_file" ] || die "Server private key not found: $key_file"
	validate_server_certificate_files "$cert_file" "$key_file" "$identity" ||
		die 'Server certificate is expired, does not match its identity, or does not match the private key'

	x509_dir="$root/etc/swanctl/x509"
	ca_dir="$root/etc/swanctl/x509ca"
	private_dir="$root/etc/swanctl/private"
	mkdir -p "$x509_dir" "$ca_dir" "$private_dir"
	stage="$(mktemp -d)" || die 'Unable to stage server certificate'
	umask 077
	cp "$key_file" "$stage/ikev2.key" || { rm -rf "$stage"; die 'Unable to stage server key'; }
	mkdir -p "$stage/chain" "$stage/backup"
	index=0
	current=
	while IFS= read -r line; do
		case "$line" in
			'-----BEGIN CERTIFICATE-----')
				index=$((index + 1))
				current="$stage/cert-$index.pem"
				;;
		esac
		[ -n "$current" ] && printf '%s\n' "$line" >>"$current"
		case "$line" in '-----END CERTIFICATE-----') current= ;; esac
	done <"$cert_file"
	[ "$index" -ge 1 ] || { rm -rf "$stage"; die 'Server certificate contains no PEM certificate'; }
	cp "$stage/cert-1.pem" "$stage/ikev2.pem" || {
		rm -rf "$stage"
		die 'Unable to stage the server leaf certificate'
	}
	certificate_index=1
	while [ "$certificate_index" -lt "$index" ]; do
		certificate_is_issued_by "$stage/cert-$certificate_index.pem" \
			"$stage/cert-$((certificate_index + 1)).pem" || {
			rm -rf "$stage"
			die 'Server certificate chain is not ordered or contains an unrelated certificate'
		}
		certificate_index=$((certificate_index + 1))
	done
	chain_index=0
	certificate_index=2
	while [ "$certificate_index" -le "$index" ]; do
		pem="$stage/cert-$certificate_index.pem"
		[ -s "$pem" ] || {
			rm -rf "$stage"
			die 'Server certificate chain is incomplete'
		}
		openssl x509 -in "$pem" -noout >/dev/null 2>&1 || {
			rm -rf "$stage"
			die 'Server certificate chain contains an invalid certificate'
		}
		# A self-signed root is a trust anchor, not part of the server chain. A
		# self-issued rollover or cross-signed certificate is retained when its
		# signature cannot be verified by its own public key.
		if ! certificate_is_self_signed "$pem"; then
			chain_index=$((chain_index + 1))
			cp "$pem" "$stage/chain/ikev2-server-chain-$chain_index.pem"
		fi
		certificate_index=$((certificate_index + 1))
	done
	[ ! -f "$x509_dir/ikev2.pem" ] || cp "$x509_dir/ikev2.pem" "$stage/backup/ikev2.pem"
	[ ! -f "$private_dir/ikev2.key" ] || cp "$private_dir/ikev2.key" "$stage/backup/ikev2.key"
	for pem in "$ca_dir"/ikev2-server-chain-*.pem; do
		[ -f "$pem" ] && cp "$pem" "$stage/backup/${pem##*/}"
	done

	if ! cp "$stage/ikev2.pem" "$x509_dir/ikev2.pem.new" ||
	   ! chmod 644 "$x509_dir/ikev2.pem.new" ||
	   ! mv "$x509_dir/ikev2.pem.new" "$x509_dir/ikev2.pem" ||
	   ! cp "$stage/ikev2.key" "$private_dir/ikev2.key.new" ||
	   ! chmod 600 "$private_dir/ikev2.key.new" ||
	   ! mv "$private_dir/ikev2.key.new" "$private_dir/ikev2.key"; then
		rm -f "$x509_dir/ikev2.pem.new" "$private_dir/ikev2.key.new"
		restore_server_certificate_backup "$stage" "$x509_dir" "$private_dir" "$ca_dir"
		rm -rf "$stage"
		die 'Unable to install the server certificate; previous certificate restored'
	fi
	rm -f "$ca_dir"/ikev2-server-chain-*.pem
	for pem in "$stage/chain"/*.pem; do
		[ -f "$pem" ] || continue
		cp "$pem" "$ca_dir/${pem##*/}.new" && chmod 644 "$ca_dir/${pem##*/}.new" &&
			mv "$ca_dir/${pem##*/}.new" "$ca_dir/${pem##*/}" || {
				restore_server_certificate_backup "$stage" "$x509_dir" "$private_dir" "$ca_dir"
				rm -rf "$stage"
				die 'Unable to install the server certificate chain; previous certificate restored'
			}
	done
	rm -rf "$stage"
}

validate_server_settings() {
	[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || die 'Invalid enabled value'
	[ -z "$identity" ] || valid_host "$identity" || die 'Invalid server identity'
	[ "$enabled" = 0 ] || [ -n "$identity" ] || die 'Server identity is required'
	valid_ipv4_pool "$pool4" || die 'Invalid IPv4 pool'
	valid_ipv4_cidr "$gateway4" || die 'Invalid IPv4 gateway/prefix'
	valid_server_pool_layout "$pool4" "$gateway4" ||
		die 'Client pool must be ordered, inside the gateway subnet, exclude the gateway, and contain at most 4096 addresses'
	if [ -z "$root" ] && pool_overlaps_connected_network "$pool4"; then
		die 'Client pool overlaps an existing connected IPv4 network'
	fi
	valid_ipv4 "$dns4" || die 'Invalid IPv4 DNS'
	valid_path_or_empty "$cert_source" || die 'Invalid certificate directory'
	valid_path_or_empty "$cert_file" || die 'Invalid certificate path'
	valid_path_or_empty "$key_file" || die 'Invalid private key path'
	in_range "$dpd" 10 300 || die 'DPD must be 10-300 seconds'
	in_range "$ike_rekey" 3600 86400 || die 'IKE rekey must be 3600-86400 seconds'
	in_range "$child_rekey" 900 86400 || die 'CHILD rekey must be 900-86400 seconds'
	in_range "$mtu" 1280 1500 || die 'MTU must be 1280-1500'
	[ "$mobike" = 0 ] || [ "$mobike" = 1 ] || die 'Invalid MOBIKE value'
	[ "$fragmentation" = 0 ] || [ "$fragmentation" = 1 ] ||
		die 'Invalid fragmentation value'
	if [ "$enabled" = 1 ]; then
		_certf="$cert_file"
		_keyf="$key_file"
		[ -n "$_certf" ] || _certf="$cert_source/$identity.fullchain.crt"
		[ -n "$_keyf" ] || _keyf="$cert_source/$identity.key"
		[ -s "$_certf" ] ||
			die "Server certificate not found: $_certf (issue or install it before enabling the server)"
		[ -s "$_keyf" ] || die "Server private key not found: $_keyf"
		validate_server_certificate_files "$_certf" "$_keyf" "$identity" ||
			die 'Server certificate is expired, does not match its identity, or does not match the private key'
	fi
}

validate_server_access_settings() {
	valid_ipv4_cidr_list "$local_ts" || die 'Invalid IPv4 traffic selector list'
	for value in "$allow_internet" "$allow_lan" "$allow_router"; do
		[ "$value" = 0 ] || [ "$value" = 1 ] || die 'Invalid access toggle'
	done
	valid_port_list "$router_ports" ||
		die 'Router ports must contain ports or ranges separated by spaces'
	valid_name_list "$lan_zones" || die 'Invalid LAN firewall zone list'
	valid_name "$firewall_zone" || die 'Invalid inbound firewall zone'
	valid_name "$outbound_zone" || die 'Invalid outbound firewall zone'
	[ "$firewall_zone" != "$outbound_zone" ] ||
		die 'Inbound and outbound firewall zones must be different'
	if [ -z "$root" ]; then
		zone_error="$("$system_helper" validate-server-zones \
			"$firewall_zone" "$outbound_zone" 2>&1)" ||
			die "${zone_error:-Unable to validate managed firewall zone names}"
	fi
}

snapshot_server_state() {
	local directory="$1" pem
	mkdir -p "$directory/chain" || return 1
	snapshot_path "$uci_config_dir/$uci_config" "$directory" uci || return 1
	snapshot_path "$inbound_conf" "$directory" profile || return 1
	snapshot_path "$root/etc/swanctl/x509/ikev2.pem" "$directory" certificate || return 1
	snapshot_path "$root/etc/swanctl/private/ikev2.key" "$directory" private_key || return 1
	for pem in "$root/etc/swanctl/x509ca"/ikev2-server-chain-*.pem; do
		[ -f "$pem" ] || continue
		cp -p "$pem" "$directory/chain/${pem##*/}" || return 1
	done
}

restore_server_state() {
	local directory="$1" pem ca_dir
	uci -q revert "$uci_config" >/dev/null 2>&1 || true
	restore_path "$uci_config_dir/$uci_config" "$directory" uci || return 1
	restore_path "$inbound_conf" "$directory" profile || return 1
	restore_path "$root/etc/swanctl/x509/ikev2.pem" "$directory" certificate || return 1
	restore_path "$root/etc/swanctl/private/ikev2.key" "$directory" private_key || return 1
	ca_dir="$root/etc/swanctl/x509ca"
	mkdir -p "$ca_dir" || return 1
	for pem in "$directory/chain"/ikev2-server-chain-*.pem; do
		[ -f "$pem" ] || continue
		cp -p "$pem" "$ca_dir/${pem##*/}.restore.$$" || {
			rm -f "$ca_dir"/*.restore.$$ 2>/dev/null || true
			return 1
		}
	done
	rm -f "$ca_dir"/ikev2-server-chain-*.pem \
		"$inbound_conf.new" "$root/etc/swanctl/x509/ikev2.pem.new" \
		"$root/etc/swanctl/private/ikev2.key.new"
	for pem in "$ca_dir"/ikev2-server-chain-*.pem.restore.$$; do
		[ -f "$pem" ] || continue
		mv "$pem" "${pem%.restore.$$}" || return 1
	done
}

commit_server_settings() {
	uci set "$uci_config.server.enabled=$enabled" || return 1
	uci set "$uci_config.server.identity=$identity" || return 1
	uci set "$uci_config.server.pool4=$pool4" || return 1
	uci set "$uci_config.server.gateway4=$gateway4" || return 1
	uci set "$uci_config.server.dns4=$dns4" || return 1
	uci set "$uci_config.server.cert_source=$cert_source" || return 1
	uci set "$uci_config.server.cert_file=$cert_file" || return 1
	uci set "$uci_config.server.key_file=$key_file" || return 1
	uci set "$uci_config.server.dpd=$dpd" || return 1
	uci set "$uci_config.server.ike_rekey=$ike_rekey" || return 1
	uci set "$uci_config.server.child_rekey=$child_rekey" || return 1
	uci set "$uci_config.server.mtu=$mtu" || return 1
	uci set "$uci_config.server.mobike=$mobike" || return 1
	uci set "$uci_config.server.fragmentation=$fragmentation" || return 1
	uci set "$uci_config.server.local_ts=$(normalize_list "$local_ts")" || return 1
	uci set "$uci_config.server.allow_internet=$allow_internet" || return 1
	uci set "$uci_config.server.allow_lan=$allow_lan" || return 1
	uci set "$uci_config.server.allow_router=$allow_router" || return 1
	uci set "$uci_config.server.router_ports=$(normalize_list "$router_ports")" || return 1
	set_list server lan_zone "$lan_zones" || return 1
	uci set "$uci_config.server.firewall_zone=$firewall_zone" || return 1
	uci set "$uci_config.server.outbound_zone=$outbound_zone" || return 1
	uci commit "$uci_config" || return 1
	[ "$enabled" = 0 ] || ( sync_server_certificate ) || return 1
	( render_server )
}

consume_server_input() {
	local input_bytes extra action_output
	[ -n "$server_input_file" ] || die 'Server input is missing'
	[ -f "$server_input_file" ] || die 'Server input is missing'
	[ ! -L "$server_input_file" ] || die 'Server input must not be a symbolic link'
	input_bytes="$(wc -c <"$server_input_file" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) die 'Invalid server input size' ;; esac
	[ "$input_bytes" -le 32768 ] || {
		rm -f "$server_input_file"
		die 'Server input is too large'
	}
	chmod 600 "$server_input_file" || die 'Unable to protect server input'
	enabled="$(sed -n '1p' "$server_input_file")"
	identity="$(sed -n '2p' "$server_input_file")"
	pool4="$(sed -n '3p' "$server_input_file")"
	gateway4="$(sed -n '4p' "$server_input_file")"
	dns4="$(sed -n '5p' "$server_input_file")"
	cert_source="$(sed -n '6p' "$server_input_file")"
	cert_file="$(sed -n '7p' "$server_input_file")"
	key_file="$(sed -n '8p' "$server_input_file")"
	dpd="$(sed -n '9p' "$server_input_file")"
	ike_rekey="$(sed -n '10p' "$server_input_file")"
	child_rekey="$(sed -n '11p' "$server_input_file")"
	mtu="$(sed -n '12p' "$server_input_file")"
	mobike="$(sed -n '13p' "$server_input_file")"
	fragmentation="$(sed -n '14p' "$server_input_file")"
	local_ts="$(sed -n '15p' "$server_input_file")"
	allow_internet="$(sed -n '16p' "$server_input_file")"
	allow_lan="$(sed -n '17p' "$server_input_file")"
	allow_router="$(sed -n '18p' "$server_input_file")"
	router_ports="$(sed -n '19p' "$server_input_file")"
	lan_zones="$(sed -n '20p' "$server_input_file")"
	firewall_zone="$(sed -n '21p' "$server_input_file")"
	outbound_zone="$(sed -n '22p' "$server_input_file")"
	extra="$(sed -n '23,$p' "$server_input_file" | sed '/^[[:space:]]*$/d')"
	rm -f "$server_input_file"
	[ -z "$extra" ] || die 'Server input contains unexpected fields'
	validate_server_settings
	validate_server_access_settings
	if [ "$enabled" = 1 ] && [ "$(getv_default server custom_config 0)" = 1 ]; then
		[ -s "$inbound_custom" ] || die 'Inbound custom configuration is missing'
	fi
	old_enabled="$(getv_default server enabled 0)"
	pid_lock_acquire "$config_lock_dir" ||
		die 'Another configuration change is already in progress'
	server_state="$(mktemp -d)" || {
		pid_lock_release "$config_lock_dir"
		die 'Unable to prepare server configuration rollback'
	}
	if ! snapshot_server_state "$server_state"; then
		rm -rf "$server_state"
		pid_lock_release "$config_lock_dir"
		die 'Unable to back up current server configuration'
	fi
	trap 'restore_server_state "$server_state"; rm -rf "$server_state"; pid_lock_release "$config_lock_dir"; exit 1' INT TERM HUP
	if ! commit_server_settings; then
		server_restored=0
		restore_server_state "$server_state" && server_restored=1
		rm -rf "$server_state"
		pid_lock_release "$config_lock_dir"
		trap - INT TERM HUP
		[ "$server_restored" = 1 ] &&
			die 'Unable to save server settings; previous configuration restored'
		die 'Unable to save server settings and automatic rollback was incomplete'
	fi
	cp -p "$uci_config_dir/$uci_config" "$server_state/applied.uci" || {
		server_restored=0
		restore_server_state "$server_state" && server_restored=1
		rm -rf "$server_state"
		pid_lock_release "$config_lock_dir"
		trap - INT TERM HUP
		[ "$server_restored" = 1 ] &&
			die 'Unable to preserve the server rollback checkpoint; previous configuration restored'
		die 'Unable to preserve the server rollback checkpoint and automatic rollback was incomplete'
	}
	if [ "$(getv globals configured)" = 1 ]; then
		[ "$old_enabled" = "$enabled" ] && pbr_changed=0 || pbr_changed=1
		if ! action_output="$(start_action server-apply "$pbr_changed" "$server_state")"; then
			server_restored=0
			restore_server_state "$server_state" && server_restored=1
			rm -rf "$server_state"
			pid_lock_release "$config_lock_dir"
			trap - INT TERM HUP
			[ "$server_restored" = 1 ] &&
				die 'Unable to start server apply; previous configuration restored'
			die 'Unable to start server apply and automatic rollback was incomplete'
		fi
	else
		rm -rf "$server_state"
		action_output=''
	fi
	pid_lock_release "$config_lock_dir"
	trap - INT TERM HUP
	[ -z "$action_output" ] || printf '%s\n' "$action_output"
}
