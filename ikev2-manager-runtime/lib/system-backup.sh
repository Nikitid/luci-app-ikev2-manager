#!/bin/sh
# An encrypted copy of the application's settings, to restore on this router
# or to move to another one. Sourced by ikev2-manager-system.
#
# It holds what the operator made: the configuration, VPN users and their
# passwords, the outbound passwords, custom services and lists, raw strongSwan
# additions, the server certificate with its key and the ACME settings. It
# leaves out what this router owns: the WAN and protected networks, firewall
# zones, the snapshots of the DNS it had before, the domain-routing engine,
# the configuration schemas and whether routing is paused - an import keeps the
# router's own. openssl encrypts it with AES-256 under a key PBKDF2 derives
# from the passphrase.

backup_root_dir="${IKEV2_BACKUP_ROOT:-}"
backup_magic='IKEV2-MANAGER-BACKUP 1'
backup_max_bytes=4194304
backup_iterations=200000
# Read from the router and never from an archive: config.section.option.
backup_bound_options='globals.wan_interface globals.wan_zone globals.source_interface
globals.source_zone globals.schema_version globals.runtime_schema
globals.server_profile_schema globals.device_schema server.lan_zone
server.firewall_zone server.outbound_zone dns.saved dns.fallback_verified
domains.engine domains.paused domains.dns_saved domains.prev_noresolv
domains.prev_cachesize domains.prev_server'
backup_files='etc/ikev2-manager/users.db etc/ikev2-manager/client.secret
etc/ikev2-manager/tunnels.secret
etc/ikev2-manager/inbound.custom.conf etc/ikev2-manager/outbound.custom.conf
etc/pbr-ikev2-domains.manual.txt etc/pbr-ikev2-addresses.manual.txt
etc/pbr-ikev2-domains.exclude.txt etc/pbr-ikev2-addresses.exclude.txt
etc/pbr-ikev2-community-selected.txt etc/pbr-ikev2-exits.txt'

backup_input_file() {
	case "$1" in '' | *[!A-Za-z0-9-]*) die 'Invalid backup input token' ;; esac
	printf '/tmp/ikev2-manager-backup-%s.%s\n' "$1" "$2"
}

# A passphrase file the page wrote: regular, small, at least eight bytes.
backup_passphrase() {
	local file="$1" bytes
	[ -f "$file" ] && [ ! -L "$file" ] || die 'The passphrase is missing'
	bytes="$(wc -c <"$file" | tr -d ' ')"
	[ "$bytes" -ge 8 ] && [ "$bytes" -le 1024 ] || {
		rm -f "$file"
		die 'The passphrase must have at least eight characters'
	}
	chmod 600 "$file"
}

# Where the server certificate and key are read from, as the server finds them.
backup_certificate_paths() {
	local identity cert key source
	identity="$(getv server identity)"
	cert="$(getv server cert_file)"
	key="$(getv server key_file)"
	source="$(defaultv server cert_source /etc/ssl/acme)"
	[ -n "$cert" ] || cert="$source/$identity.fullchain.crt"
	[ -n "$key" ] || key="$source/$identity.key"
	printf '%s\n%s\n' "$cert" "$key"
}

# Collect the archive's contents into DIR.
backup_stage() {
	local dir="$1" path cert key
	mkdir -p "$dir/files" "$dir/services.d" || return 1
	cp "$uci_config_dir/$config" "$dir/config" || return 1
	for path in $backup_files; do
		[ -f "$backup_root_dir/$path" ] || continue
		mkdir -p "$dir/files/${path%/*}" && cp "$backup_root_dir/$path" "$dir/files/$path" || return 1
	done
	for path in "$backup_root_dir"/etc/ikev2-manager/services.d/*; do
		[ -f "$path" ] || continue
		cp "$path" "$dir/services.d/" || return 1
	done
	{
		read -r cert
		read -r key
	} <<EOF
$(backup_certificate_paths)
EOF
	if [ -s "$backup_root_dir$cert" ] && [ -s "$backup_root_dir$key" ]; then
		cp "$backup_root_dir$cert" "$dir/certificate" && cp "$backup_root_dir$key" "$dir/key" || return 1
	fi
	uci -q show acme.ikev2 >"$dir/acme" 2>/dev/null || :
	printf 'acme.email=%s\n' "$(uci -q get 'acme.@acme[0].account_email' 2>/dev/null || true)" >>"$dir/acme"
	{
		printf '%s\n' "$backup_magic"
		printf 'version=%s\n' "$(cat /usr/share/ikev2-manager/version 2>/dev/null || echo unknown)"
		printf 'created=%s\n' "$(date +%s)"
	} >"$dir/manifest"
}

# The encrypted archive, Base64-encoded on stdout for the page to save.
backup_export() {
	local token="$1" pass work rc=0
	pass="$(backup_input_file "$token" pass)"
	backup_passphrase "$pass"
	work="$(mktemp -d)" || { rm -f "$pass"; die 'Unable to create a temporary directory'; }
	chmod 700 "$work"
	if ! backup_stage "$work/stage" ||
	   ! tar -C "$work/stage" -czf "$work/archive.tgz" . ||
	   ! { printf '%s\n' "$backup_magic" &&
	       openssl enc -aes-256-cbc -pbkdf2 -iter "$backup_iterations" -md sha256 -salt \
	           -in "$work/archive.tgz" -pass "file:$pass"; } >"$work/backup"; then
		rc=1
	fi
	rm -f "$pass"
	if [ "$rc" = 0 ] && [ "$(wc -c <"$work/backup" | tr -d ' ')" -le "$backup_max_bytes" ]; then
		openssl base64 -A <"$work/backup" && printf '\n'
	else
		rc=1
	fi
	rm -rf "$work"
	[ "$rc" = 0 ] || die 'Unable to create the backup'
}

# Decrypt the uploaded archive into DIR and check that it holds only what an
# export writes.
backup_open() {
	local input="$1" pass="$2" dir="$3" bytes entry
	[ -f "$input" ] && [ ! -L "$input" ] || die 'The backup file is missing'
	bytes="$(wc -c <"$input" | tr -d ' ')"
	[ "$bytes" -le $((backup_max_bytes * 2)) ] || die 'The backup file is too large'
	mkdir -p "$dir" && chmod 700 "$dir" || return 1
	openssl base64 -d -A <"$input" >"$dir/backup" 2>/dev/null || die 'This is not a backup of this application'
	[ "$(head -n 1 "$dir/backup")" = "$backup_magic" ] || die 'This is not a backup of this application'
	tail -n +2 "$dir/backup" >"$dir/backup.enc"
	openssl enc -d -aes-256-cbc -pbkdf2 -iter "$backup_iterations" -md sha256 \
		-in "$dir/backup.enc" -out "$dir/archive.tgz" -pass "file:$pass" 2>/dev/null ||
		die 'The passphrase does not open this backup'
	tar -tzf "$dir/archive.tgz" >"$dir/list" 2>/dev/null || die 'The backup is damaged'
	# Plain files and directories only: a link could point anywhere.
	tar -tvzf "$dir/archive.tgz" 2>/dev/null | grep -q '^[^-d]' &&
		die 'The backup holds a file it should not'
	while IFS= read -r entry; do
		case "${entry#./}" in
			'' | manifest | config | certificate | key | acme | files/ | services.d/ ) ;;
			files/etc/ | files/etc/ikev2-manager/ ) ;;
			services.d/*/* | *..* ) die 'The backup holds a file it should not' ;;
			services.d/[a-z0-9_]*.lst | services.d/[a-z0-9_]*.cidrs | services.d/[a-z0-9_]*.name | \
			services.d/[a-z0-9_]*.origin | services.d/[a-z0-9_]*.mode ) ;;
			files/*)
				case " $(printf '%s' "$backup_files" | tr '\n' ' ') " in
					*" ${entry#./files/} "*) ;;
					*) die 'The backup holds a file it should not' ;;
				esac
				;;
			*) die 'The backup holds a file it should not' ;;
		esac
	done <"$dir/list"
	mkdir -p "$dir/stage" && tar -C "$dir/stage" -xzf "$dir/archive.tgz" || die 'The backup is damaged'
	[ -z "$(find "$dir/stage" -type l | head -n 1)" ] || die 'The backup holds a file it should not'
	[ "$(head -n 1 "$dir/stage/manifest" 2>/dev/null)" = "$backup_magic" ] &&
		[ -s "$dir/stage/config" ] || die 'The backup is damaged'
	uci -c "$dir/stage" -q show config >/dev/null 2>&1 ||
		die 'The settings in the backup cannot be read'
}

# The router's own value of each bound option, as a uci batch that puts it
# back over imported settings.
backup_bound_batch() {
	local item value
	for item in $backup_bound_options; do
		printf 'delete %s.%s\n' "$config" "$item"
		value="$(uci -q show "$config.$item" 2>/dev/null)" || continue
		value="${value#*=}"
		# A list prints as 'a' 'b'; each element is one add_list.
		printf '%s\n' "$value" | awk -v key="$config.$item" '
			{
				line = $0
				while (match(line, /\x27[^\x27]*\x27/)) {
					values[++n] = substr(line, RSTART + 1, RLENGTH - 2)
					line = substr(line, RSTART + RLENGTH)
				}
			}
			END {
				if (n == 1) printf "set %s=%s\n", key, values[1]
				else for (i = 1; i <= n; i++) printf "add_list %s=%s\n", key, values[i]
			}
		'
	done
}

# The files an import replaces, and the configuration it changes, for a
# rollback.
backup_snapshot() {
	local dir="$1"
	backup_stage "$dir" || return 1
	uci -q export acme >"$dir/acme.full" 2>/dev/null || :
}

# Put the contents of a staged archive in place, keeping this router's
# binding: the files it holds replace the router's and the ones it lacks are
# removed. Used for the import and, with the snapshot, for the rollback.
backup_install() {
	local dir="$1" bound="$2" path cert key line
	cp "$dir/config" "$uci_config_dir/$config.import.$$" &&
		chmod 600 "$uci_config_dir/$config.import.$$" &&
		mv "$uci_config_dir/$config.import.$$" "$uci_config_dir/$config" || return 1
	uci -q batch <"$bound" && uci commit "$config" || return 1
	for path in $backup_files; do
		if [ -f "$dir/files/$path" ]; then
			mkdir -p "$backup_root_dir/${path%/*}" &&
				cp "$dir/files/$path" "$backup_root_dir/$path.import" &&
				chmod 600 "$backup_root_dir/$path.import" &&
				mv "$backup_root_dir/$path.import" "$backup_root_dir/$path" || return 1
		else
			rm -f "$backup_root_dir/$path"
		fi
	done
	mkdir -p "$backup_root_dir/etc/ikev2-manager/services.d" &&
		chmod 700 "$backup_root_dir/etc/ikev2-manager/services.d" || return 1
	rm -f "$backup_root_dir"/etc/ikev2-manager/services.d/*
	for path in "$dir"/services.d/*; do
		[ -f "$path" ] || continue
		cp "$path" "$backup_root_dir/etc/ikev2-manager/services.d/" || return 1
	done
	chmod 600 "$backup_root_dir"/etc/ikev2-manager/services.d/* 2>/dev/null || :
	if [ -s "$dir/certificate" ] && [ -s "$dir/key" ]; then
		{
			read -r cert
			read -r key
		} <<EOF
$(backup_certificate_paths)
EOF
		case "$cert:$key" in /etc/*:/etc/*) ;; *) return 1 ;; esac
		case "$cert$key" in *..*) return 1 ;; esac
		mkdir -p "$backup_root_dir${cert%/*}" "$backup_root_dir${key%/*}" &&
			cp "$dir/certificate" "$backup_root_dir$cert" &&
			( umask 077; cp "$dir/key" "$backup_root_dir$key" ) || return 1
	fi
	if [ -s "$dir/acme.full" ]; then
		uci -q import acme <"$dir/acme.full" && uci commit acme || return 1
	elif [ -s "$dir/acme" ] && grep -q '^acme\.ikev2=' "$dir/acme"; then
		uci -q get acme >/dev/null 2>&1 || touch "$uci_config_dir/acme"
		uci -q delete acme.ikev2 || :
		sed -n 's/^\(acme\.ikev2[^=]*\)=\(.*\)$/\1 \2/p' "$dir/acme" |
			while read -r key line; do
				# One value is set; several, as uci shows a list, are added.
				printf '%s\n' "$line" | awk -v key="$key" '
					{
						rest = $0
						while (match(rest, /\x27[^\x27]*\x27/)) {
							values[++n] = substr(rest, RSTART + 1, RLENGTH - 2)
							rest = substr(rest, RSTART + RLENGTH)
						}
						if (n == 0) values[++n] = $0
					}
					END {
						if (key == "acme.ikev2") printf "set acme.ikev2=%s\n", values[1]
						else if (n == 1) printf "set %s=%s\n", key, values[1]
						else for (i = 1; i <= n; i++) printf "add_list %s=%s\n", key, values[i]
					}
				'
			done | uci -q batch || return 1
		line="$(sed -n 's/^acme\.email=//p' "$dir/acme")"
		if [ -n "$line" ]; then
			uci -q get 'acme.@acme[0]' >/dev/null 2>&1 || uci add acme acme >/dev/null
			uci set "acme.@acme[0].account_email=$line" || return 1
		fi
		uci commit acme || return 1
	fi
}

# Bring every runtime to the installed settings: the lists, DNS, then
# strongSwan, the firewall and routing through the manager's own reload.
backup_apply() {
	/usr/libexec/ikev2-domains-community apply >/dev/null || return 1
	( apply_saved_dns ) || return 1
	[ "$(defaultv globals configured 0)" != 1 ] ||
		/usr/libexec/ikev2-manager reload >/dev/null || return 1
}

backup_import() {
	local token="$1" input pass work bound
	input="$(backup_input_file "$token" in)"
	pass="$(backup_input_file "$token" pass)"
	backup_passphrase "$pass"
	work="$(mktemp -d)" || die 'Unable to create a temporary directory'
	chmod 700 "$work"
	backup_open "$input" "$pass" "$work/import" || { rm -rf "$work"; rm -f "$input" "$pass"; return 1; }
	rm -f "$input" "$pass"
	backup_bound_batch >"$work/bound" || { rm -rf "$work"; die 'Unable to read this router'\''s settings'; }
	backup_snapshot "$work/previous" || { rm -rf "$work"; die 'Unable to save the current settings'; }
	if backup_install "$work/import/stage" "$work/bound" && backup_apply; then
		rm -rf "$work"
		return 0
	fi
	if backup_install "$work/previous" "$work/bound" && backup_apply; then
		rm -rf "$work"
		die 'The imported settings did not apply; the previous settings were restored'
	fi
	rm -rf "$work"
	die 'The imported settings did not apply, and restoring the previous settings did not finish'
}
