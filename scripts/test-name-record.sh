#!/bin/sh
# Recording the names one device asks for: dnsmasq is given query logging and
# restarted, only that device's names are shown, and the end takes the logging
# out again, keeps the device's names and deletes the log of everyone.
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { printf 'name record: %s\n' "$*" >&2; exit 1; }
# Where the package is installed (the OpenWrt scenarios) the helper drops the
# overrides the tests rely on; the copy tested here keeps them, and nothing
# else differs.
helper="$tmp/name-record.sh"
sed '/^if \[ -e \/usr\/share\/ikev2-manager\/version \]; then$/,/^fi$/d' \
	"$root/luci-ikev2-domains/name-record.sh" >"$helper"
! grep -q '/usr/share/ikev2-manager/version' "$helper" || fail 'the installed-package guard was not taken out of the copy'

mkdir -p "$tmp/bin" "$tmp/confdir" "$tmp/run"
cat >"$tmp/bin/uci" <<EOF
#!/bin/sh
[ "\$1" = -q ] && shift
# As uci prints them: anonymous sections by position unless -X is given.
case "\$*" in
	'-X show dhcp') echo 'dhcp.cfg01411c=dnsmasq' ;;
	'show dhcp') echo 'dhcp.@dnsmasq[0]=dnsmasq' ;;
	'get dhcp.cfg01411c.confdir') echo '$tmp/confdir' ;;
	*) exit 1 ;;
esac
EOF
# dnsmasq: each restart is recorded with the files its confdir held then; a
# start can be made to fail.
cat >"$tmp/bin/dnsmasq-init" <<EOF
#!/bin/sh
case "\$1" in
	restart) printf 'restart %s\n' "\$(ls '$tmp/confdir' | tr '\n' ' ')" >>'$tmp/restarts'
		[ ! -e '$tmp/fail' ] ;;
	running) [ ! -e '$tmp/fail' ] ;;
esac
EOF
cat >"$tmp/bin/start-stop-daemon" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$tmp/timers'
EOF
chmod 755 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" IKEV2_RECORD_DIR="$tmp/state" IKEV2_RECORD_LOG="$tmp/run/ikev2-name-record.log" \
	IKEV2_DNSMASQ_INIT="$tmp/bin/dnsmasq-init"

# Refused before anything is touched.
for bad in '192.168.1 5' '192.168.1.300 5' '192.168.1.3 0' '192.168.1.3 31' '192.168.1.3 x'; do
	# shellcheck disable=SC2086
	if sh "$helper" start $bad >/dev/null 2>&1; then fail "accepted: start $bad"; fi
done
[ ! -e "$tmp/restarts" ] || fail 'a refused start restarted dnsmasq'

# A start logs queries into the jail's run directory and arms its own end.
sh "$helper" start 192.168.1.3 5 >"$tmp/out"
grep -qx 'state=recording' "$tmp/out" || fail "start did not say it records: $(cat "$tmp/out")"
grep -qx 'log-queries=extra' "$tmp/confdir/ikev2-name-record.conf" &&
	grep -qx "log-facility=$tmp/run/ikev2-name-record.log" "$tmp/confdir/ikev2-name-record.conf" ||
	fail 'dnsmasq was not given query logging'
grep -qx 'restart ikev2-name-record.conf ' "$tmp/restarts" || fail 'dnsmasq was not restarted with the logging'
grep -q -- '_expire ' "$tmp/timers" || fail 'the recording has no end of its own'

# Only the chosen device's names, counted, without local or reverse names.
cat >"$tmp/run/ikev2-name-record.log" <<'EOF'
Oct 17 23:09:39 dnsmasq[1]: 101 192.168.1.3/50001 query[A] api.example.com from 192.168.1.3
Oct 17 23:09:39 dnsmasq[1]: 102 192.168.1.3/50002 query[AAAA] api.example.com from 192.168.1.3
Oct 17 23:09:40 dnsmasq[1]: 103 192.168.1.3/50003 query[HTTPS] CDN.Example.NET. from 192.168.1.3
Oct 17 23:09:40 dnsmasq[1]: 104 192.168.1.3/50004 query[PTR] 3.1.168.192.in-addr.arpa from 192.168.1.3
Oct 17 23:09:40 dnsmasq[1]: 105 192.168.1.3/50005 query[A] printer.lan from 192.168.1.3
Oct 17 23:09:41 dnsmasq[1]: 106 192.168.1.33/50006 query[A] other.example.org from 192.168.1.33
Oct 17 23:09:41 dnsmasq[1]: 106 192.168.1.33/50006 forwarded other.example.org to 1.1.1.1
Oct 17 23:09:41 dnsmasq[1]: 107 192.168.1.3/50007 query[A] wpad from 192.168.1.3
EOF
sh "$helper" status >"$tmp/status"
grep -qx 'state=recording' "$tmp/status" && grep -qx 'address=192.168.1.3' "$tmp/status" ||
	fail "status does not say what is recorded: $(cat "$tmp/status")"
[ "$(sed -n '/ /p' "$tmp/status" | tr '\n' ';')" = 'api.example.com 2;cdn.example.net 1;' ] ||
	fail "unexpected names: $(sed -n '/ /p' "$tmp/status" | tr '\n' ';')"

# The end: logging out, dnsmasq restarted without it, the device's names kept
# and everyone's log gone.
sh "$helper" stop
[ ! -e "$tmp/confdir/ikev2-name-record.conf" ] || fail 'the logging stayed in dnsmasq'
[ "$(tail -n 1 "$tmp/restarts")" = 'restart ' ] || fail 'dnsmasq was not restarted without the logging'
[ ! -e "$tmp/run/ikev2-name-record.log" ] || fail 'the log of every client was kept'
sh "$helper" status >"$tmp/status"
grep -qx 'state=done' "$tmp/status" || fail "a stopped recording is not done: $(cat "$tmp/status")"
grep -qx 'api.example.com 2' "$tmp/status" || fail 'the names were lost with the log'
grep -q 'other.example.org' "$tmp/status" && fail 'another device leaked into the result'

# The timer of an earlier recording does not end a later one.
sh "$helper" start 192.168.1.3 5 >/dev/null
sh "$helper" _expire 1 || :
grep -qx 'state=recording' "$tmp/state/state" || fail 'an old timer ended a newer recording'
sh "$helper" stop

# A dnsmasq that does not come back with the logging runs as before.
touch "$tmp/fail"
if sh "$helper" start 192.168.1.3 5 >/dev/null 2>&1; then fail 'a failed dnsmasq start was reported as recording'; fi
[ ! -e "$tmp/confdir/ikev2-name-record.conf" ] || fail 'the logging was left behind a failed start'
rm -f "$tmp/fail"
printf '%s\n' 'name record tests OK'
