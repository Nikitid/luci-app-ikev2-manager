#!/bin/sh
# Dependency installation, repair and removal for the system helper, including
# the strongSwan cohort and dnsmasq replacement transactions. Sourced by
# ikev2-manager-system, whose configuration helpers and globals it uses.

strongswan_security_check() {
	case "$1" in
		client)
			pkg_version_at_least strongswan 6.0.3 ||
				die 'Installed strongSwan is vulnerable to CVE-2025-62291; upgrade strongSwan before enabling the outbound EAP client'
			;;
		# Inbound compatibility is advisory. The installed OpenWrt package may be
		# older than the upstream fix, but operators can deliberately keep the
		# EAP server enabled; doctor reports the version without changing runtime.
		server) return 0 ;;
		*) die 'Expected strongSwan security mode: client or server' ;;
	esac
}

runtime_packages() {
	cat <<'EOF'
dnsproxy
sing-box
strongswan
strongswan-charon
strongswan-swanctl
strongswan-mod-aes
strongswan-mod-attr
strongswan-mod-constraints
strongswan-mod-eap-identity
strongswan-mod-eap-mschapv2
strongswan-mod-gcm
strongswan-mod-gmp
strongswan-mod-hmac
strongswan-mod-kdf
strongswan-mod-kernel-netlink
strongswan-mod-md4
strongswan-mod-openssl
strongswan-mod-pem
strongswan-mod-pkcs1
strongswan-mod-pubkey
strongswan-mod-random
strongswan-mod-sha2
strongswan-mod-socket-default
strongswan-mod-vici
strongswan-mod-x509
kmod-xfrm-interface
kmod-nft-tproxy
kmod-nf-tproxy
ip-full
openssl-util
curl
libcurl4
conntrack
swanmon
socat
acme
luci-app-acme
acme-acmesh-dnsapi
EOF
}

# Print the one version every installed strongSwan package shares. Fail when
# they differ, when a version is unknown, or when plugins are installed without
# the base package. One pass over the listing: a query per package cost more
# than a second with the full plugin set installed.
strongswan_cohort_version() {
	local listing
	listing="$(pkg_installed_versions)" || return 1
	[ -n "$listing" ] || return 1
	printf '%s\n' "$listing" | awk '
		$1 == "strongswan" || $1 ~ /^strongswan-/ {
			found = 1
			if ($1 == "strongswan") base = 1
			if ($2 == "") bad = 1
			else if (cohort == "") cohort = $2
			else if ($2 != cohort) bad = 1
		}
		END {
			if (bad || (found && !base)) exit 1
			print cohort
		}'
}

# Preserve an already installed strongSwan build as one versioned cohort.
# Adding a missing plugin must fail if that exact build is no longer present in
# the feed; it must never upgrade only the base library or an arbitrary subset.
runtime_install_arguments() {
	local package cohort
	cohort="$(strongswan_cohort_version)" || return 1
	for package in "$@"; do
		case "$package" in
			strongswan | strongswan-*)
				if [ -n "$cohort" ]; then
					case "$(pkg_manager_name)" in
						apk) printf '%s=%s\n' "$package" "$cohort" ;;
						# opkg has no reliable version constraint syntax. Do not pass
						# installed cohort members back to `opkg install`, and refuse
						# automatic repair if one of them is absent.
						opkg) pkg_installed "$package" || return 1 ;;
						*) return 1 ;;
					esac
				else
					printf '%s\n' "$package"
				fi
				;;
			*) printf '%s\n' "$package" ;;
		esac
	done
}

verify_install_plan() {
	package_names="$(runtime_packages | tr '\n' ' ')"
	packages="$(runtime_install_arguments $package_names | tr '\n' ' ')" || {
		deps_status error 'Installed strongSwan packages do not form one version cohort'
		return 1
	}
	plan_allow_dns=0
	pkg_installed dnsmasq-full || plan_allow_dns=1
	if ! PKG_PLAN_ALLOW_DNSMASQ_SWAP="$plan_allow_dns" \
		pkg_install_plan_safe dnsmasq-full $packages; then
		deps_status error 'Required packages do not match this firmware/kernel or are missing from configured feeds'
		return 1
	fi
}

cleanup_dnsmasq_transaction() {
	rm -rf /tmp/ikev2-manager-dns-packages
	rm -f /tmp/ikev2-manager-dhcp.before-deps
}


deps_status() {
	status_tmp="${deps_status_file}.new.$$"
	{
		[ -z "${DEPS_ACTION_ID:-}" ] || printf 'action_id=%s\n' "$DEPS_ACTION_ID"
		printf 'state=%s\n' "$1"
		printf 'updated=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
		[ -z "${2:-}" ] || printf 'message=%s\n' "$2"
	} >"$status_tmp"
	mv "$status_tmp" "$deps_status_file"
}

rollback_dependency_install() {
	cleanup_dnsmasq_transaction
	deps_state_captured || return 1
	deps_state_restore || return 1
	deps_state_clear
}

# Heavy installer body. Runs detached (see install_deps) and reports progress
# through deps_status_file so the LuCI page can poll instead of blocking on a
# long XHR that would otherwise time out during package updates/installations.
run_install_deps() {
	DEPS_ACTION_ID="${1:-}"
	exec >>/tmp/ikev2-manager-deps.log 2>&1
	if ! acquire_action_lock_announced dependencies "$DEPS_ACTION_ID" deps_status; then
		deps_status error 'Another router action is still running.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM
	[ -r /etc/openwrt_release ] || { deps_status error 'This command must run on OpenWrt'; exit 1; }
	. /etc/openwrt_release
	package_manager="$(pkg_manager_name)"
	case "$(openwrt_release_support "${DISTRIB_RELEASE:-}" "$package_manager")" in
		supported | newer) ;;
		*)
			deps_status error "OpenWrt 24.10.x with opkg, or 25.12.x or newer with apk, is required; found ${DISTRIB_RELEASE:-unknown} with $package_manager"
			exit 1
			;;
	esac
	if ! preflight >/tmp/ikev2-manager-preflight.last 2>&1; then
		deps_status error 'Compatibility preflight failed; run ikev2-manager-system preflight'
		exit 1
	fi
	if [ -e "$deps_state_dir" ] && [ "$(deps_state_version)" = 2 ]; then
		# Version 2 compared every future package against the original baseline and
		# could claim packages installed later by an administrator. Discard it and
		# establish a conservative version-3 baseline instead of deleting anything.
		deps_status running 'Resetting an unsafe legacy dependency ownership record...'
		deps_state_clear
	elif [ -e "$deps_state_dir" ] && ! deps_state_ready; then
		deps_status running 'Recovering an interrupted dependency installation...'
		if ! rollback_dependency_install; then
			deps_status error 'An interrupted installation could not be rolled back; see /tmp/ikev2-manager-deps.log'
			exit 1
		fi
	fi
	if deps_state_ready && [ "$(deps_state_version)" = 1 ] &&
	   ! deps_state_upgrade_v1; then
		deps_status error 'Legacy dependency ownership could not be upgraded safely'
		exit 1
	fi

	deps_status running 'Creating a recovery backup...'
	backup="/tmp/ikev2-manager-deps-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
	if ! sysupgrade -b "$backup"; then
		deps_status error 'Unable to create the pre-install sysupgrade backup'
		exit 1
	fi

	deps_status running 'Updating package lists...'
	if ! pkg_update; then
		deps_status error 'Package list update failed; check WAN and DNS connectivity'
		exit 1
	fi

	deps_status running 'Checking firmware, kernel ABI, storage and package availability...'
	if ! verify_install_plan; then
		exit 1
	fi
	packages="$(runtime_packages | tr '\n' ' ')"
	if deps_state_ready; then
		if ! pkg_installed dnsmasq-full || ! pkg_dnsmasq_has_nftset; then
			deps_status error 'Installed dependency state is inconsistent with dnsmasq; use Remove Dependencies before reinstalling'
			exit 1
		fi
		missing=''
		for package in $packages; do
			pkg_installed "$package" || missing="${missing}${missing:+ }$package"
		done
		if [ -n "$missing" ]; then
			deps_status running 'Repairing missing runtime packages...'
			install_args="$(runtime_install_arguments $missing | tr '\n' ' ')" || {
				deps_status error 'Installed strongSwan packages do not form one version cohort'
				exit 1
			}
			if ! pkg_install_plan_safe $install_args; then
				deps_status error 'Missing packages are unavailable without changing the installed runtime cohort'
				exit 1
			fi
			if ! repair_snapshot="$(mktemp /tmp/ikev2-manager-repair-before.XXXXXX)" ||
			   ! pkg_list_installed_names >"$repair_snapshot"; then
				deps_status error 'Unable to snapshot installed packages before dependency repair'
				exit 1
			fi
			if ! pkg_install $install_args; then
				pkg_remove_added_since "$repair_snapshot" >/dev/null 2>&1 || true
				rm -f "$repair_snapshot"
				deps_status error 'Dependency repair failed; the previous runtime packages were kept'
				exit 1
			fi
		fi
		doctor >/tmp/ikev2-manager-doctor.last 2>&1 || true
		if ! grep -q '^dependencies_ok=1' /tmp/ikev2-manager-doctor.last; then
			[ -z "$missing" ] || pkg_remove_added_since "$repair_snapshot" >/dev/null 2>&1 || true
			[ -z "${repair_snapshot:-}" ] || rm -f "$repair_snapshot"
			deps_status error 'Dependency repair failed package checks; the previous runtime packages were kept'
			exit 1
		fi
		if [ -n "$missing" ] && ! deps_state_record_added_since "$repair_snapshot"; then
			pkg_remove_added_since "$repair_snapshot" >/dev/null 2>&1 || true
			rm -f "$repair_snapshot"
			deps_status error 'Repaired package ownership could not be saved; newly added packages were removed'
			exit 1
		fi
		[ -z "${repair_snapshot:-}" ] || rm -f "$repair_snapshot"
		deps_status ok 'All runtime dependencies are installed and verified.'
		return 0
	fi

	cache="/tmp/ikev2-manager-dns-packages"
	dnsmasq_provider=''
	if ! pkg_installed dnsmasq-full; then
		dnsmasq_provider="$(pkg_dnsmasq_provider || true)"
		if [ -z "$dnsmasq_provider" ]; then
			deps_status error 'No supported dnsmasq provider is installed; dependency installation stopped'
			exit 1
		fi
		rm -rf "$cache"
		mkdir -p "$cache"
		if [ "$package_manager" = opkg ]; then
			deps_status running 'Downloading DNS rollback packages...'
			if ! (cd "$cache" && pkg_download "$dnsmasq_provider" dnsmasq-full); then
				deps_status error 'Unable to download dnsmasq packages before replacement'
				cleanup_dnsmasq_transaction
				exit 1
			fi
			full_pkg="$(pkg_package_file "$cache" dnsmasq-full)"
			previous_pkg="$(pkg_package_file "$cache" "$dnsmasq_provider")"
			if [ ! -s "$full_pkg" ] || [ ! -s "$previous_pkg" ]; then
				deps_status error 'DNS rollback packages were not downloaded'
				cleanup_dnsmasq_transaction
				exit 1
			fi
		fi
	fi

	if ! deps_state_capture; then
		deps_status error 'Unable to save the pre-install package and DNS state'
		cleanup_dnsmasq_transaction
		exit 1
	fi
	if [ "$package_manager" = opkg ] && [ -n "$dnsmasq_provider" ]; then
		previous_pkg="$(pkg_package_file "$cache" "$dnsmasq_provider")"
		if ! deps_state_store_dnsmasq_package "$previous_pkg"; then
			deps_state_clear
			deps_status error 'Unable to preserve the original dnsmasq package for rollback'
			cleanup_dnsmasq_transaction
			exit 1
		fi
	fi

	if [ -n "$dnsmasq_provider" ]; then
		deps_status running 'Replacing dnsmasq with dnsmasq-full...'
		if ! dns_snapshot="$(mktemp /tmp/ikev2-manager-dns-before.XXXXXX)" ||
		   ! pkg_list_installed_names >"$dns_snapshot"; then
			deps_status error 'Unable to snapshot packages before replacing dnsmasq'
			rollback_dependency_install || true
			exit 1
		fi
		if ! pkg_switch_dnsmasq_full "$cache" "$dnsmasq_provider"; then
			deps_state_record_added_since "$dns_snapshot" || true
			rm -f "$dns_snapshot"
			if rollback_dependency_install; then
				deps_status error 'dnsmasq-full installation failed; previous dnsmasq provider restored'
			else
				deps_status error 'dnsmasq-full installation failed and rollback failed; see /tmp/ikev2-manager-deps.log'
			fi
			exit 1
		fi
		if ! deps_state_record_added_since "$dns_snapshot"; then
			rm -f "$dns_snapshot"
			rollback_dependency_install || true
			deps_status error 'dnsmasq-full was installed but package ownership could not be saved; previous state restored'
			exit 1
		fi
		rm -f "$dns_snapshot"
		if ! cp "$(deps_state_file dhcp.before)" /etc/config/dhcp; then
			if rollback_dependency_install; then
				deps_status error 'Unable to restore DHCP configuration after dnsmasq replacement; previous state restored'
			else
				deps_status error 'DHCP configuration restore and automatic rollback failed; see /tmp/ikev2-manager-deps.log'
			fi
			exit 1
		fi
		rm -f /etc/config/dhcp.apk-new /etc/config/dhcp-opkg
		if ! pkg_installed dnsmasq-full || ! pkg_dnsmasq_has_nftset; then
			if rollback_dependency_install; then
				deps_status error 'dnsmasq-full verification failed; previous dnsmasq provider restored'
			else
				deps_status error 'dnsmasq-full verification failed and rollback failed; see /tmp/ikev2-manager-deps.log'
			fi
			exit 1
		fi
		if ! /etc/init.d/dnsmasq restart >/dev/null 2>&1; then
			rollback_dependency_install || true
			deps_status error 'dnsmasq-full was installed but DNS service did not restart; previous state restored'
			exit 1
		fi
		cleanup_dnsmasq_transaction
	fi

	deps_status running 'Installing strongSwan, sing-box and XFRM packages...'
	install_args="$(runtime_install_arguments $packages | tr '\n' ' ')" || {
		rollback_dependency_install || true
		deps_status error 'Installed strongSwan packages do not form one version cohort'
		exit 1
	}
	if ! runtime_snapshot="$(mktemp /tmp/ikev2-manager-runtime-before.XXXXXX)" ||
	   ! pkg_list_installed_names >"$runtime_snapshot"; then
		rollback_dependency_install || true
		deps_status error 'Unable to snapshot packages before runtime installation'
		exit 1
	fi
	if ! pkg_install $install_args; then
		deps_state_record_added_since "$runtime_snapshot" || true
		rm -f "$runtime_snapshot"
		if rollback_dependency_install; then
			deps_status error 'Package installation failed; the pre-install package and DNS state was restored'
		else
			deps_status error 'Package installation failed; automatic rollback also failed; see /tmp/ikev2-manager-deps.log'
		fi
		exit 1
	fi
	if ! deps_state_record_added_since "$runtime_snapshot"; then
		rm -f "$runtime_snapshot"
		if rollback_dependency_install; then
			deps_status error 'Installed package ownership could not be saved; the pre-install state was restored'
		else
			deps_status error 'Installed package ownership could not be saved and rollback failed; see /tmp/ikev2-manager-deps.log'
		fi
		exit 1
	fi
	rm -f "$runtime_snapshot"
	doctor >/tmp/ikev2-manager-doctor.last 2>&1 || true
	if ! grep -q '^dependencies_ok=1' /tmp/ikev2-manager-doctor.last; then
		if rollback_dependency_install; then
			deps_status error 'Installed packages failed dependency checks; the pre-install state was restored'
		else
			deps_status error 'Installed packages failed dependency checks and rollback failed; see /tmp/ikev2-manager-deps.log'
		fi
		exit 1
	fi
	if ! deps_state_mark_installed; then
		if rollback_dependency_install; then
			deps_status error 'Dependency ownership could not be saved; the pre-install state was restored'
		else
			deps_status error 'Dependency ownership could not be saved and rollback failed; see /tmp/ikev2-manager-deps.log'
		fi
		exit 1
	fi
	deps_status ok 'All runtime dependencies installed.'
}

install_deps() {
	DEPS_ACTION_ID="$(date +%s)-$$"
	deps_status running 'Starting dependency installation...'
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _install-deps-run "$DEPS_ACTION_ID"; then
			deps_status error 'Unable to start dependency installation'
			die 'Unable to start dependency installation'
		fi
	else
		setsid "$0" _install-deps-run "$DEPS_ACTION_ID" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$DEPS_ACTION_ID"
}

# Restore only packages recorded as application-owned at installation time,
# together with the DNS provider and DHCP file present before installation.
run_remove_deps() {
	DEPS_ACTION_ID="${1:-}"
	exec >>/tmp/ikev2-manager-deps.log 2>&1
	if ! acquire_action_lock_announced dependencies "$DEPS_ACTION_ID" deps_status; then
		deps_status error 'Another router action is still running.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM
	if ! deps_state_ready; then
		deps_status error 'Dependency ownership is unavailable; install dependencies once with this version before using Remove'
		return 1
	fi
	# FakeIP goes first. Restoring the original DNS with FakeIP still running
	# re-pointed sing-box at it while the segment resolvers were already
	# stopped, and the probe that followed failed on a name sing-box still
	# sent to a stopped segment. Everything FakeIP holds is removed below.
	fakeip_was_active=0
	if [ "$(defaultv domains engine nftset)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		fakeip_was_active=1
		deps_status running 'Stopping FakeIP routing...'
		if ! /usr/libexec/ikev2-domain-router deactivate; then
			deps_status error 'FakeIP routing could not be stopped; dependency removal stopped before removing packages'
			return 1
		fi
	fi
	if [ "$(defaultv dns managed 0)" = 1 ] ||
	   { [ "$(defaultv dns saved 0)" = 1 ] && [ -d "$dns_original_dir" ]; }; then
		deps_status running 'Restoring the DNS configuration used before this application...'
		if ! "$0" _dns-apply-inner 0 '' '' '' '' '' ''; then
			[ "$fakeip_was_active" = 0 ] ||
				/usr/libexec/ikev2-domain-router activate >/dev/null 2>&1 || true
			deps_status error 'Original DNS could not be restored; dependency removal stopped before removing packages'
			return 1
		fi
	fi
	deps_status running 'Disabling managed configuration...'
	if ! disable_managed; then
		deps_status error 'Managed routing could not be disabled; dependency removal stopped before removing packages'
		return 1
	fi
	swanctl --terminate --ike proxy-out --timeout 3 >/dev/null 2>&1 || true
	swanctl --terminate --ike ikev2-in --timeout 3 >/dev/null 2>&1 || true
	swanctl --unload-conn proxy-out >/dev/null 2>&1 || true
	swanctl --unload-conn ikev2-in >/dev/null 2>&1 || true
	if [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router deactivate >/dev/null 2>&1 || true
	fi
	if [ -x /etc/init.d/ikev2-xfrm ]; then
		/etc/init.d/ikev2-xfrm stop >/dev/null 2>&1 || {
			deps_status error 'XFRM interfaces could not be stopped; dependency removal stopped'
			return 1
		}
		/etc/init.d/ikev2-xfrm disable >/dev/null 2>&1 || {
			deps_status error 'XFRM service could not be disabled; dependency removal stopped'
			return 1
		}
	fi

	deps_status running 'Restoring the pre-install DNS and package state...'
	if ! deps_state_restore; then
		doctor >/tmp/ikev2-manager-doctor.last 2>&1 || true
		deps_status error 'Runtime dependency restore failed; see /tmp/ikev2-manager-deps.log'
		return 1
	fi
	retained_packages="$(printf '%s\n' "${deps_state_retained:-}" | tr '\n' ' ' | sed 's/ *$//')"
	[ -z "$retained_packages" ] ||
		printf 'Packages retained because other software requires them: %s\n' "$retained_packages"
	deps_status running 'Resetting application settings...'
	if ! reset_application_state; then
		deps_status error 'Dependencies were restored, but application settings could not be reset completely'
		return 1
	fi
	deps_state_clear
	doctor >/tmp/ikev2-manager-doctor.last 2>&1 || true
	if [ -n "$retained_packages" ]; then
		deps_status ok 'Router state restored. Shared packages required by other software were kept.'
	else
		deps_status ok 'Pre-install packages, settings and managed routing state were restored.'
	fi
}

reset_application_state() {
	[ -r "$default_app_config" ] || return 1
	config_tmp="${uci_config_dir}/${config}.new.$$"
	cp "$default_app_config" "$config_tmp" || return 1
	chmod 600 "$config_tmp" || { rm -f "$config_tmp"; return 1; }
	mv "$config_tmp" "${uci_config_dir}/${config}" || return 1

	if uci -q get acme.ikev2 >/dev/null 2>&1; then
		uci -q delete acme.ikev2 || return 1
		uci commit acme || return 1
	fi

	rm -f /etc/ikev2-manager/client.secret /etc/ikev2-manager/users.db
	rm -f /etc/ikev2-manager/domain-router-cache.db
	rm -f /etc/ikev2-manager/domain-router-rules.json
	rm -f /etc/ikev2-manager/domain-router.json /etc/ikev2-manager/pbr-set4.dump
	rm -f /etc/ikev2-dnsmasq.servers /etc/ikev2-manager/domain-router-bypass.json
	# Addresses learned for the old selection, kept for the next boot; a
	# reinstall would otherwise start routing them again.
	rm -f /etc/ikev2-manager/routing-dst4.dump /etc/ikev2-manager/routing-dst6.dump
	rm -rf /etc/ikev2-manager/dns-original /etc/pbr-ikev2-community-cache
	rm -f /etc/swanctl/conf.d/20-proxy-out.conf
	rm -f /etc/swanctl/conf.d/30-inbound.conf
	rm -f /etc/swanctl/conf.d/90-proxy-out-secret.conf
	rm -f /etc/swanctl/conf.d/91-inbound-secrets.conf
	rm -f /etc/swanctl/x509/ikev2.pem /etc/swanctl/private/ikev2.key
	rm -f /etc/swanctl/x509ca/ikev2-le-isrg-root-*.pem
	rm -f /etc/swanctl/x509ca/ikev2-server-chain-*.pem
	for file in /etc/pbr-ikev2-domains.txt \
		/etc/pbr-ikev2-domains.manual.txt \
		/etc/pbr-ikev2-addresses.manual.txt \
		/etc/pbr-ikev2-domains.exclude.txt \
		/etc/pbr-ikev2-addresses.exclude.txt \
		/etc/pbr-ikev2-domains.bypass.txt \
		/etc/pbr-ikev2-addresses.bypass.txt \
		/etc/pbr-ikev2-community-selected.txt; do
		: >"$file" || return 1
		chmod 600 "$file" || return 1
	done
}

remove_deps() {
	DEPS_ACTION_ID="$(date +%s)-$$"
	deps_status running 'Starting dependency removal...'
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _remove-deps-run "$DEPS_ACTION_ID"; then
			deps_status error 'Unable to start dependency removal'
			die 'Unable to start dependency removal'
		fi
	else
		setsid "$0" _remove-deps-run "$DEPS_ACTION_ID" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$DEPS_ACTION_ID"
}
