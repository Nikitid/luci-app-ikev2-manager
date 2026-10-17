#!/bin/sh
# Which names one device on the network asks the router for, recorded for a
# few minutes, so the domains an application uses can be put into a service.
#
# dnsmasq logs the queries of every client while a recording runs; only the
# chosen device's names are ever shown, and the log is deleted when the
# recording ends. dnsmasq runs in a jail that may write nothing but its run
# directory, so the log lives there. Starting and stopping restart dnsmasq,
# which takes the router's DNS away for about a second each time.
#
#   ikev2-name-record start ADDRESS MINUTES
#   ikev2-name-record stop
#   ikev2-name-record status
set -u
# rpcd hands a page's environment to the helper unchanged; the IKEV2_*
# overrides are for the tests and are dropped where the package is installed.
if [ -e /usr/share/ikev2-manager/version ]; then
	PATH=/usr/sbin:/usr/bin:/sbin:/bin
	for ikev2_override in $(env | sed -n 's/^\(IKEV2_[A-Za-z0-9_]*\)=.*/\1/p'); do
		unset "$ikev2_override"
	done
fi
state_dir="${IKEV2_RECORD_DIR:-/var/run/ikev2-name-record}"
log_file="${IKEV2_RECORD_LOG:-/var/run/dnsmasq/ikev2-name-record.log}"
dnsmasq_init="${IKEV2_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
conf_name='ikev2-name-record.conf'
state_file="$state_dir/state"
result_file="$state_dir/result"
lock="$state_dir.lock"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

# One confdir per dnsmasq instance, where its init script points it.
confdirs() {
	local section confdir
	# -X names the sections as dnsmasq's init script does (cfg01411c), not as
	# "@dnsmasq[0]".
	for section in $(uci -X show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p'); do
		confdir="$(uci -q get "dhcp.$section.confdir" 2>/dev/null || echo "/tmp/dnsmasq.$section.d")"
		confdir="${confdir%%,*}"
		case "$confdir" in /*) printf '%s\n' "$confdir" ;; esac
	done
}

valid_address() {
	printf '%s\n' "$1" | grep -Eqx '([0-9]{1,3}\.){3}[0-9]{1,3}' || return 1
	local IFS=.
	# shellcheck disable=SC2086
	set -- $1
	[ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] && [ "$4" -le 255 ]
}

state_value() {
	sed -n "s/^$1=//p" "$state_file" 2>/dev/null | tail -n 1
}

# The names ADDRESS asked for in the log, with how often: no reverse lookups,
# no local names, no single labels.
names_of() {
	[ -r "$log_file" ] || return 0
	awk -v from="$1" '
		/ query\[[A-Z0-9]+\] / && $NF == from && $(NF - 1) == "from" {
			name = tolower($(NF - 2))
			sub(/\.$/, "", name)
			if (name !~ /\./ || name ~ /\.(arpa|lan|local|localdomain|home\.arpa)$/) next
			if (name !~ /^[a-z0-9_.-]+$/) next
			count[name]++
		}
		END { for (name in count) printf "%d %s\n", count[name], name }' "$log_file" | sort -rn | awk '{ print $2, $1 }'
}

restart_dnsmasq() {
	"$dnsmasq_init" restart >/dev/null 2>&1
}

lock_take() {
	local i=0
	until mkdir "$lock" 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -lt 20 ] || die 'Another recording is being started or stopped'
		sleep 1
	done
	trap 'rmdir "$lock" 2>/dev/null' EXIT
}

# Takes the logging out and keeps what the device asked for; the log of every
# other client goes with it.
stop_recording() {
	local address dir
	address="$(state_value address)"
	for dir in $(confdirs); do
		rm -f "$dir/$conf_name"
	done
	restart_dnsmasq || :
	if [ -n "$address" ] && names_of "$address" >"$result_file.new"; then
		mv "$result_file.new" "$result_file"
	fi
	rm -f "$log_file"
	if [ -f "$state_file" ]; then
		sed 's/^state=.*/state=done/' "$state_file" >"$state_file.new" && mv "$state_file.new" "$state_file"
	fi
}

start() {
	local address="$1" minutes="$2" now until dir written=0
	valid_address "$address" || die 'Expected an IPv4 address'
	case "$minutes" in '' | *[!0-9]*) die 'Expected minutes from 1 to 30' ;; esac
	[ "$minutes" -ge 1 ] && [ "$minutes" -le 30 ] || die 'Expected minutes from 1 to 30'
	mkdir -p "$state_dir" && chmod 700 "$state_dir" || die 'Unable to create the recording directory'
	lock_take
	now="$(date +%s)"
	until=$((now + minutes * 60))
	rm -f "$result_file" "$log_file"
	for dir in $(confdirs); do
		[ -d "$dir" ] || continue
		printf 'log-queries=extra\nlog-facility=%s\n' "$log_file" >"$dir/$conf_name" && written=1
	done
	[ "$written" = 1 ] || die 'dnsmasq has no configuration directory'
	printf 'state=recording\naddress=%s\nstarted=%s\nuntil=%s\n' "$address" "$now" "$until" >"$state_file"
	# A dnsmasq that does not come back with the logging is put back without it.
	if ! restart_dnsmasq || ! "$dnsmasq_init" running >/dev/null 2>&1; then
		stop_recording
		rm -f "$state_file"
		die 'dnsmasq did not start with query logging; it runs as before'
	fi
	# The recording ends by itself, whatever happens to the page.
	start-stop-daemon -b -q -S -x "$0" -- _expire "$until" >/dev/null 2>&1 || :
	printf 'state=recording\nuntil=%s\n' "$until"
}

status() {
	local state address until
	state="$(state_value state)"
	address="$(state_value address)"
	until="$(state_value until)"
	printf 'state=%s\naddress=%s\nuntil=%s\nnow=%s\n' "${state:-idle}" "$address" "$until" "$(date +%s)"
	case "$state" in
		recording) names_of "$address" ;;
		done) cat "$result_file" 2>/dev/null || : ;;
	esac
}

case "${1:-}" in
	start)
		[ "$#" -eq 3 ] || die 'Expected: start ADDRESS MINUTES'
		start "$2" "$3"
		;;
	stop)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		[ "$(state_value state)" = recording ] || exit 0
		lock_take
		stop_recording
		;;
	status)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		status
		;;
	_expire)
		case "${2:-}" in '' | *[!0-9]*) exit 1 ;; esac
		while [ "$(date +%s)" -lt "$2" ]; do sleep 5; done
		# Only the recording this timer was started for.
		[ "$(state_value state)" = recording ] && [ "$(state_value until)" = "$2" ] || exit 0
		lock_take
		stop_recording
		;;
	*)
		die 'Usage: ikev2-name-record {start ADDRESS MINUTES|stop|status}'
		;;
esac
