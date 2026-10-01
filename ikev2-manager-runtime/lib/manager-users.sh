#!/bin/sh
# VPN user accounts for the LuCI backend: the credential database, per-user
# policy sections and the transactions that change both together. Sourced by
# ikev2-manager, whose configuration helpers and globals it uses.

init_users() {
	[ -s "$users_db" ] && return 0

	mkdir -p "${users_db%/*}"
	chmod 700 "${users_db%/*}"
	tmp="${users_db}.new"
	awk '
		/^[[:space:]]*eap-[^[:space:]]+[[:space:]]*\{/ {
			in_eap = 1
			id = ""
			secret = ""
			next
		}
		in_eap && /^[[:space:]]*id[[:space:]]*=/ {
			id = $0
			sub(/^[^=]*=[[:space:]]*/, "", id)
			gsub(/^"|"$/, "", id)
			next
		}
		in_eap && /^[[:space:]]*secret[[:space:]]*=/ {
			secret = $0
			sub(/^[^=]*=[[:space:]]*/, "", secret)
			next
		}
		in_eap && /^[[:space:]]*\}/ {
			if (id != "" && secret != "")
				printf "%s\t%s\n", id, secret
			in_eap = 0
		}
	' "$inbound_secrets" 2>/dev/null >"$tmp" || :
	atomic_install "$tmp" "$users_db" 600
}

render_users() {
	local tmp="${inbound_secrets}.new" index user secret
	{
		echo 'secrets {'
		index=0
		while IFS="$(printf '\t')" read -r user secret; do
			[ -n "$user" ] || continue
			index=$((index + 1))
			# Keep section names independent from user-controlled identities.
			# Dots and other valid EAP-ID characters are not valid in every
			# strongSwan settings section name.
			printf '\teap-%s {\n' "$index"
			printf '\t\tid = "%s"\n' "$user"
			printf '\t\tsecret = %s\n' "$secret"
			echo '	}'
			echo
		done <"$users_db"
		echo '	private-key {'
		printf '\t\tfile = %s\n' "$root/etc/swanctl/private/ikev2.key"
		echo '	}'
		echo '}'
	} >"$tmp"
	atomic_install "$tmp" "$inbound_secrets" 600
}

reload_credentials() {
	# Replacing an EAP secret under the same identity does not reliably evict
	# the previous in-memory credential. Clear and immediately reload the full
	# credential set; established IKE SAs are not terminated by this operation.
	swanctl_quiet --load-creds --clear --noprompt >/dev/null
}

user_exists() {
	awk -F '\t' -v user="$1" '$1 == user { found = 1 } END { exit found ? 0 : 1 }' \
		"$users_db"
}

user_policy_section() {
	printf 'user_%s\n' "$(printf '%s' "$1" | sha256sum |
		awk '{ print substr($1, 1, 16) }')"
}

user_policy_value() {
	local user="$1" option="$2" fallback="$3" section saved_user value
	section="$(user_policy_section "$user")"
	saved_user="$(uci -q get "$uci_config.$section.username" 2>/dev/null || true)"
	if [ "$saved_user" = "$user" ]; then
		value="$(uci -q get "$uci_config.$section.$option" 2>/dev/null || true)"
	else
		value=''
	fi
	printf '%s\n' "${value:-$fallback}"
}

save_user_policy() {
	local user="$1" router="$2" internet="$3" lan="$4" pbr="$5" targets="$6" public_ports="$7"
	local section saved_user
	section="$(user_policy_section "$user")"
	saved_user="$(uci -q get "$uci_config.$section.username" 2>/dev/null || true)"
	if [ -n "$saved_user" ] && [ "$saved_user" != "$user" ]; then
		printf '%s\n' 'VPN user policy identifier collision' >&2
		return 1
	fi
	uci set "$uci_config.$section=user_policy" || return 1
	uci set "$uci_config.$section.username=$user" || return 1
	uci set "$uci_config.$section.router_access=$router" || return 1
	uci set "$uci_config.$section.internet_access=$internet" || return 1
	uci set "$uci_config.$section.lan_access=$lan" || return 1
	uci set "$uci_config.$section.pbr_mode=$pbr" || return 1
	uci set "$uci_config.$section.lan_targets=$targets" || return 1
	uci set "$uci_config.$section.public_ports=$public_ports" || return 1
	uci commit "$uci_config"
}

apply_user_policy_runtime() {
	[ "$(uci -q get "$uci_config.globals.configured" 2>/dev/null || echo 0)" = 1 ] ||
		return 0
	[ "$(uci -q get "$uci_config.server.enabled" 2>/dev/null || echo 0)" = 1 ] ||
		return 0
	"$system_helper" access-apply
}

restore_user_policy_backup() {
	local backup="$1"
	uci -q revert "$uci_config" >/dev/null 2>&1 || true
	cp -p "$backup" "$uci_config_dir/$uci_config"
}

add_user_with_policy_transaction() {
	local user="$1" secret="$2" router="$3" internet="$4" lan="$5" pbr="$6" targets="$7"
	local public_ports="$8"
	local backup rollback_policy
	backup="$(mktemp)" || return 1
	cp -p "$uci_config_dir/$uci_config" "$backup" || {
		rm -f "$backup"
		return 1
	}
	rollback_policy=1
	trap '
		if [ "$rollback_policy" = 1 ]; then
			restore_user_policy_backup "$backup" >/dev/null 2>&1 || true
		fi
		rm -f "$backup"
	' EXIT
	if ! save_user_policy "$user" "$router" "$internet" "$lan" "$pbr" "$targets" \
		"$public_ports"; then
		restore_user_policy_backup "$backup" >/dev/null 2>&1 || true
		rm -f "$backup"
		trap - EXIT
		return 1
	fi
	# Store the restrictive policy before loading the credential. A concurrent
	# health refresh can therefore never admit a new identity under global
	# defaults during the add operation.
	update_user "$user" "$secret"
	if apply_user_policy_runtime; then
		rollback_policy=0
		trap - EXIT
		rm -f "$backup"
		return 0
	fi
	# If credential removal itself fails, keep the restrictive policy instead
	# of restoring global inheritance for a credential that may still exist.
	rollback_policy=0
	delete_user "$user"
	restored=0
	restore_user_policy_backup "$backup" && restored=1
	rm -f "$backup"
	trap - EXIT
	[ "$restored" = 1 ] || return 1
	apply_user_policy_runtime >/dev/null 2>&1 || return 1
	return 1
}

update_user_policy_transaction() {
	local user="$1" router="$2" internet="$3" lan="$4" pbr="$5" targets="$6"
	local public_ports="$7"
	local backup restored
	backup="$(mktemp)" || return 1
	cp -p "$uci_config_dir/$uci_config" "$backup" || {
		rm -f "$backup"
		return 1
	}
	if save_user_policy "$user" "$router" "$internet" "$lan" "$pbr" "$targets" \
		"$public_ports" &&
	   apply_user_policy_runtime; then
		rm -f "$backup"
		return 0
	fi
	restored=0
	uci -q revert "$uci_config" >/dev/null 2>&1 || true
	cp -p "$backup" "$uci_config_dir/$uci_config" && restored=1
	rm -f "$backup"
	[ "$restored" = 1 ] || return 1
	apply_user_policy_runtime >/dev/null 2>&1 || return 1
	return 1
}

delete_user_policy() {
	local user="$1" section saved_user
	section="$(user_policy_section "$user")"
	saved_user="$(uci -q get "$uci_config.$section.username" 2>/dev/null || true)"
	[ "$saved_user" = "$user" ] || return 0
	uci -q delete "$uci_config.$section" || return 1
	uci commit "$uci_config" || return 1
	apply_user_policy_runtime
}

# Ends every session of USER. Reloading the credentials leaves established SAs
# running and nothing runs EAP on them again, so a deleted user, or one whose
# password was changed after a phone was lost, stayed connected for as long as
# the device kept the tunnel up.
terminate_user_sessions() {
	local user="$1" id
	for id in $("$sa_helper" session-ids ikev2-in "$user" 2>/dev/null); do
		case "$id" in '' | *[!0-9]*) continue ;; esac
		swanctl_quiet --terminate --ike-id "$id" --timeout 5 >/dev/null 2>&1 || :
	done
}

delete_user_account() {
	local user="$1"
	delete_user "$user"
	terminate_user_sessions "$user"
	delete_user_policy "$user" ||
		die 'VPN user was deleted, but live access rules could not be refreshed'
}

restore_user_files() {
	local db_backup="$1" secrets_backup="$2"
	restored=1
	cp "$db_backup" "${users_db}.restore" &&
		atomic_install "${users_db}.restore" "$users_db" 600 || restored=0
	cp "$secrets_backup" "${inbound_secrets}.restore" &&
		atomic_install "${inbound_secrets}.restore" "$inbound_secrets" 600 || restored=0
	reload_credentials >/dev/null 2>&1 || restored=0
	[ "$restored" -eq 1 ]
}

update_user() {
	local user="$1" secret="$2" db_backup secrets_backup tmp
	[ -f "$inbound_secrets" ] || render_users
	db_backup="${users_db}.rollback.$$"
	secrets_backup="${inbound_secrets}.rollback.$$"
	cp "$users_db" "$db_backup" || die 'Unable to back up VPN credentials'
	cp "$inbound_secrets" "$secrets_backup" || {
		rm -f "$db_backup"
		die 'Unable to back up VPN credentials'
	}
	tmp="${users_db}.new"
	awk -F '\t' -v user="$user" '$1 != user' "$users_db" >"$tmp"
	printf '%s\t%s\n' "$user" "$secret" >>"$tmp"
	# BusyBox sort has no -o: it would leave the file unsorted and print every
	# username/secret pair on this command's stdout, which LuCI reads back.
	sort "$tmp" >"${tmp}.sorted" || die 'Unable to store VPN credentials'
	mv "${tmp}.sorted" "$tmp"
	if ! atomic_install "$tmp" "$users_db" 600 ||
	   ! render_users || ! reload_credentials; then
		user_restored=0
		restore_user_files "$db_backup" "$secrets_backup" && user_restored=1
		rm -f "$db_backup" "$secrets_backup"
		[ "$user_restored" = 1 ] &&
			die 'Unable to reload VPN credentials; previous credentials restored'
		die 'Unable to reload VPN credentials and automatic rollback was incomplete'
	fi
	rm -f "$db_backup" "$secrets_backup"
}

delete_user() {
	local user="$1" db_backup secrets_backup tmp
	user_exists "$user" || die 'VPN user does not exist'
	[ -f "$inbound_secrets" ] || render_users
	db_backup="${users_db}.rollback.$$"
	secrets_backup="${inbound_secrets}.rollback.$$"
	cp "$users_db" "$db_backup" || die 'Unable to back up VPN credentials'
	cp "$inbound_secrets" "$secrets_backup" || {
		rm -f "$db_backup"
		die 'Unable to back up VPN credentials'
	}
	tmp="${users_db}.new"
	awk -F '\t' -v user="$user" '$1 != user' "$users_db" >"$tmp"
	if ! atomic_install "$tmp" "$users_db" 600 ||
	   ! render_users || ! reload_credentials; then
		user_restored=0
		restore_user_files "$db_backup" "$secrets_backup" && user_restored=1
		rm -f "$db_backup" "$secrets_backup"
		[ "$user_restored" = 1 ] &&
			die 'Unable to reload VPN credentials; previous credentials restored'
		die 'Unable to reload VPN credentials and automatic rollback was incomplete'
	fi
	rm -f "$db_backup" "$secrets_backup"
}
