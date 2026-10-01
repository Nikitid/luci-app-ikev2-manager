#!/bin/sh

# The health watcher is a shell script; the running instance keeps executing the
# copy it already read, so after an upgrade it behaves like the previous version
# until something restarts it. Upgrading 1.1.x to 1.2.x that way left the
# inbound user policy never created, because the older watcher has no such step.
#
# Both packaging paths carry the same block; run it against a stub init script.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# Inbound admission has its own event-driven watcher. The general health loop
# must never rebuild that table because slow outbound or DNS probes would delay
# newly connected clients and create two competing writers.
if grep -Fq 'refresh_inbound_user_policy' \
	"$root/ikev2-manager-runtime/ikev2-health.sh"; then
	printf '%s\n' 'general health loop still owns inbound admission refreshes' >&2
	exit 1
fi
grep -Fq 'procd_set_param command /usr/libexec/ikev2-user-policy watch' \
	"$root/ikev2-manager-runtime/ikev2-user-policy.init"
grep -Fq 'procd_set_param respawn' \
	"$root/ikev2-manager-runtime/ikev2-user-policy.init"
grep -Fq 'procd_send_signal ikev2-user-policy' \
	"$root/ikev2-manager-runtime/ikev2-user-policy.init"
if grep -Fq '/usr/libexec/ikev2-domains-restart' \
	"$root/ikev2-manager-runtime/ikev2-health.sh"; then
	printf '%s\n' 'health watcher can still trigger a global PBR rebuild' >&2
	exit 1
fi

cat >"$tmp/init" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$INIT_LOG"
case "$1" in
	running) exit "${INIT_RUNNING_RC:-0}" ;;
	restart) exit "${INIT_RESTART_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$tmp/init"
mkdir -p "$tmp/rc.d"
ln -s ../init.d/ikev2-health "$tmp/rc.d/S96ikev2-health"
ln -s ../init.d/ikev2-health "$tmp/rc.d/K96ikev2-health"

extract() {
	source="$1"
	unescape="$2"
	sed -n '/# health-restart begin/,/# health-restart end/p' "$source" >"$tmp/block"
	[ -s "$tmp/block" ] || {
		printf 'no health-restart block in %s\n' "$source" >&2
		exit 1
	}
	if [ "$unescape" = 1 ]; then
		sed 's/\$\$/$/g' "$tmp/block" >"$tmp/block.sh"
	else
		cp "$tmp/block" "$tmp/block.sh"
	fi
	sh -n "$tmp/block.sh"
}

INIT_RUNNING_RC=0
INIT_RESTART_RC=0

run() {
	: >"$tmp/init.log"
	INIT_LOG="$tmp/init.log" \
	INIT_RUNNING_RC="$INIT_RUNNING_RC" \
	INIT_RESTART_RC="$INIT_RESTART_RC" \
	IKEV2_HEALTH_INIT="$tmp/init" \
	IKEV2_RC_DIR="$tmp/rc.d" \
		sh "$tmp/block.sh" >"$tmp/out" 2>&1
}

for source in Makefile scripts/stage-package.sh; do
	case "$source" in
		Makefile) extract "$root/$source" 1 ;;
		*) extract "$root/$source" 0 ;;
	esac

	# A running watcher is restarted so it picks up the installed version.
	INIT_RUNNING_RC=0
	run
	grep -qx 'restart' "$tmp/init.log" || {
		printf '%s did not restart a running watcher\n' "$source" >&2
		exit 1
	}
	grep -qx 'disable' "$tmp/init.log" && grep -qx 'enable' "$tmp/init.log" || {
		printf '%s did not migrate the enabled watcher rc links\n' "$source" >&2
		exit 1
	}
	grep -Fq 'Updated the health watcher shutdown order' "$tmp/out" || {
		printf '%s refreshed rc links silently\n' "$source" >&2
		exit 1
	}
	grep -Fq 'Restarted the health watcher' "$tmp/out" || {
		printf '%s restarted the watcher silently\n' "$source" >&2
		exit 1
	}

	# A stopped watcher is left stopped: an installation that deliberately keeps
	# the runtime down must not be started by a package upgrade.
	INIT_RUNNING_RC=1
	run
	grep -qx 'restart' "$tmp/init.log" && {
		printf '%s started a watcher that was not running\n' "$source" >&2
		exit 1
	}
	grep -qx 'disable' "$tmp/init.log" && grep -qx 'enable' "$tmp/init.log" || {
		printf '%s did not preserve autostart for a stopped watcher\n' "$source" >&2
		exit 1
	}
	INIT_RUNNING_RC=0

	# A failed restart is reported but never fails the package transaction.
	INIT_RESTART_RC=1
	if ! run; then
		printf '%s failed the transaction because a restart failed\n' "$source" >&2
		exit 1
	fi
	grep -Fq 'Could not restart the health watcher' "$tmp/out" || {
		printf '%s hid a failed restart\n' "$source" >&2
		exit 1
	}
	INIT_RESTART_RC=0

	# A missing init script is a plain no-op.
	IKEV2_HEALTH_INIT="$tmp/absent" sh "$tmp/block.sh" >"$tmp/out" 2>&1 || {
		printf '%s failed when the init script is absent\n' "$source" >&2
		exit 1
	}
done

# The new inbound watcher has an independent package lifecycle. Test both
# packaging paths: active generated servers are reloaded/started, while a
# disabled or custom server retires a previously running watcher.
cat >"$tmp/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = -q ] && shift
[ "${1:-}" = get ] || exit 1
case "${2:-}" in
	ikev2-manager.globals.configured) echo "${POLICY_CONFIGURED:-1}" ;;
	ikev2-manager.server.enabled) echo "${POLICY_ENABLED:-1}" ;;
	ikev2-manager.server.custom_config) echo "${POLICY_CUSTOM:-0}" ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/policy-init" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$POLICY_INIT_LOG"
case "$1" in running) exit "${POLICY_RUNNING_RC:-0}" ;; *) exit 0 ;; esac
EOF
chmod 755 "$tmp/uci" "$tmp/policy-init"

extract_policy() {
	source="$1"
	unescape="$2"
	sed -n '/# inbound-policy-watcher begin/,/# inbound-policy-watcher end/p' \
		"$source" >"$tmp/policy-block"
	[ -s "$tmp/policy-block" ] || {
		printf 'no inbound-policy-watcher block in %s\n' "$source" >&2
		exit 1
	}
	if [ "$unescape" = 1 ]; then
		sed 's/\$\$/$/g' "$tmp/policy-block" >"$tmp/policy-block.sh"
	else
		cp "$tmp/policy-block" "$tmp/policy-block.sh"
	fi
	sh -n "$tmp/policy-block.sh"
}

run_policy_block() {
	: >"$tmp/policy-init.log"
	PATH="$tmp:$PATH" \
	POLICY_INIT_LOG="$tmp/policy-init.log" \
	POLICY_RUNNING_RC="${POLICY_RUNNING_RC:-0}" \
	POLICY_CONFIGURED="${POLICY_CONFIGURED:-1}" \
	POLICY_ENABLED="${POLICY_ENABLED:-1}" \
	POLICY_CUSTOM="${POLICY_CUSTOM:-0}" \
	IKEV2_USER_POLICY_INIT="$tmp/policy-init" \
		sh "$tmp/policy-block.sh" >"$tmp/policy.out" 2>&1
}

for source in Makefile scripts/stage-package.sh; do
	case "$source" in
		Makefile) extract_policy "$root/$source" 1 ;;
		*) extract_policy "$root/$source" 0 ;;
	esac
	POLICY_RUNNING_RC=0 POLICY_CONFIGURED=1 POLICY_ENABLED=1 POLICY_CUSTOM=0 \
		run_policy_block
	grep -Fxq reload "$tmp/policy-init.log"
	if grep -Fxq start "$tmp/policy-init.log"; then
		printf '%s re-started an already running inbound watcher\n' "$source" >&2
		exit 1
	fi
	POLICY_RUNNING_RC=1 POLICY_CONFIGURED=1 POLICY_ENABLED=1 POLICY_CUSTOM=0 \
		run_policy_block
	grep -Fxq start "$tmp/policy-init.log"
	POLICY_RUNNING_RC=0 POLICY_CONFIGURED=1 POLICY_ENABLED=0 POLICY_CUSTOM=0 \
		run_policy_block
	grep -Fxq stop "$tmp/policy-init.log"
	grep -Fxq disable "$tmp/policy-init.log"
	if grep -Eq '^(reload|start)$' "$tmp/policy-init.log"; then
		printf '%s kept an inactive inbound watcher alive\n' "$source" >&2
		exit 1
	fi
done

printf 'health watcher restart tests OK\n'
