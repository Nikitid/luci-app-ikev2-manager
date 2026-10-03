#!/bin/sh
# shellcheck disable=SC2154 # T_* tokens are defined in the sourced config
#
# Push IKEv2 manager health to Uptime Kuma push monitors. Runs on the router
# from cron and changes nothing: every check below is a read-only status call
# or a single HTTPS request.
#
# Config, kept on the router only (tokens are secrets):
#   /etc/ikev2-kuma/kuma.conf
#     KUMA=https://kuma-host:port   (push tokens travel in the URL)
#     PBR_DOMAIN=<a selected domain served by Cloudflare, e.g. chatgpt.com>
#     CONTROL_DOMAIN=<a domain that must stay on WAN>
#     LOCAL_NAMES="<name>=<address> ..."   optional split-DNS answers to verify
#     CERT=/etc/swanctl/x509/<server>.pem  optional
#     T_services= T_tunnel= T_domains= T_dns= T_inbound= T_cert=
#     T_security=   optional: doctor security findings
#     T_traffic=    optional: throughput of all the tunnels together
#     T_tunnel_2= ... T_tunnel_7=   optional: a monitor for each other tunnel
#
# Each monitor also charts a number as its "ping", the one that moves before
# its state does: the watcher's share of a CPU core, the tunnel's round trip,
# connections through the FakeIP router (or destinations learned when matching
# by address), how long an uncached name takes to resolve, connected inbound
# clients and the certificate's days left; T_traffic charts the tunnels'
# kbit/s. Rates come from counters kept in /var/run between runs. With more
# than one tunnel, T_tunnel also fails on what doctor finds wrong with any of
# them, and a T_tunnel_N monitor charts tunnel N's round trip.
#
# The domain check follows the router's settings: with FakeIP and the
# router's own traffic routed it checks where a request leaves; otherwise it
# checks the DNS answer, and when matching by address that the answer is in
# the routing set. Checks that do not apply to the setup report nothing.
#
# Usage: kuma-push.sh

CONF="${CONF:-/etc/ikev2-kuma/kuma.conf}"
# The config is run as root: refuse one that someone else could have written.
[ -n "$(find "$CONF" -maxdepth 0 -user root ! -perm -020 ! -perm -002 2>/dev/null)" ] || {
	printf 'kuma-push: %s must exist, belong to root and be writable only by root\n' "$CONF" >&2
	exit 1
}
# shellcheck disable=SC1090 # path is set at run time
. "$CONF" || exit 1
SYS=/usr/libexec/ikev2-manager-system
DR=/usr/libexec/ikev2-domain-router
SA=/usr/libexec/ikev2-sa

# One run at a time: a slow uplink can make a run outlast its cron interval.
exec 9>/var/run/ikev2-kuma.lock
flock -n 9 || exit 0

push() {
	curl -s -o /dev/null -m 10 -G "$KUMA/api/push/$1" --data-urlencode "status=$2" \
		--data-urlencode "msg=$3" --data-urlencode "ping=$4"
}

# field <name>=<value> from "key=value" lines on stdin
field() { sed -n "s/^$1=//p" | head -n 1; }

# the first IPv4 answer for <name> from <server>, past nslookup's own header
resolve() {
	nslookup "$1" "$2" 2>/dev/null |
		awk '/^Name:/ { n = 1 } n && /^Address/ && $NF !~ /:/ { print $NF; exit }'
}

# run a command, killing it after <seconds>: BusyBox has no timeout applet
bounded() {
	secs=$1; shift
	"$@" &
	pid=$!
	( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
	watchdog=$!
	wait "$pid"; rc=$?
	kill "$watchdog" 2>/dev/null
	return "$rc"
}

# cloudflare trace: prints "ip loc" for the path a request to <host> takes
trace() {
	curl -s -m 10 ${2:+--interface $2} "https://$1/cdn-cgi/trace" 2>/dev/null |
		awk -F= '$1=="ip"{i=$2} $1=="loc"{l=$2} END{if (i!="") print i" "l}'
}

# Counters from the previous run, for rates. /proc/uptime does not jump with
# the clock and counts in hundredths of a second.
STATE=/var/run/ikev2-kuma.state
uptime_cs() { awk '{ sub(/\./, "", $1); print $1 + 0 }' /proc/uptime; }
was=$(cat "$STATE" 2>/dev/null)
previous() { printf '%s\n' "$was" | sed -n "s/^$1=//p" | head -n 1; }
now_cs=$(uptime_cs)
then_cs=$(previous uptime_cs)
elapsed=$(( now_cs - ${then_cs:-$now_cs} ))

# the watcher run by procd, and the CPU it and what it waited for have used
watcher_pid=''
for p in $(pidof ikev2-health 2>/dev/null); do
	[ "$(awk '{ print $4 }' "/proc/$p/stat" 2>/dev/null)" = 1 ] && watcher_pid=$p
done
watcher_ticks=$(awk '{ print $14 + $15 + $16 + $17 }' "/proc/$watcher_pid/stat" 2>/dev/null)
# summed over every tunnel link
counter() {
	cat /sys/class/net/ipsec-out*/statistics/"$1" 2>/dev/null |
		awk '{ sum += $1 } END { if (NR) printf "%.0f\n", sum }'
}
rx=$(counter rx_bytes); tx=$(counter tx_bytes)
{
	printf 'uptime_cs=%s\n' "$now_cs"
	printf 'watcher_pid=%s\nwatcher_ticks=%s\n' "$watcher_pid" "$watcher_ticks"
	printf 'rx=%s\ntx=%s\n' "$rx" "$tx"
} >"$STATE.new" && mv "$STATE.new" "$STATE"
# <now> <before>: a per-second rate of the counter's growth over the interval;
# empty on the first run, after a restart or when it went backwards
rate() {
	[ -n "$1" ] && [ -n "$2" ] && [ "$elapsed" -gt 0 ] || return 0
	awk -v now="$1" -v was="$2" -v cs="$elapsed" 'BEGIN { if (now >= was) printf "%.2f", (now - was) * 100 / cs }'
}

# report: collect failures, then push; bad lines start with a cross
bad=""
fail() { bad="$bad
✗ $1"; }
report() {
	if [ -z "$bad" ]; then push "$1" up "✓ $2" "${3:-0}"
	else push "$1" down "${bad#?}" "${3:-0}"; fi
	bad=""
}

doctor=$($SYS doctor-ui 2>/dev/null)
state=$($SYS get 2>/dev/null)
dr=$($DR status 2>/dev/null)
wan=$(trace "$CONTROL_DOMAIN"); wan_ip=${wan%% *}

# 1. services
v=$(echo "$dr" | field service); [ "$v" = running ] || fail "FakeIP-маршрутизатор: ${v:-нет ответа}"
v=$(echo "$dr" | field healthy); [ "$v" = yes ] || fail "FakeIP нездоров: $(echo "$dr" | field message)"
v=$(echo "$state" | field routing_paused); [ "$v" = 0 ] || fail "маршрутизация на паузе"
v=$(echo "$doctor" | field dependencies_ok); [ -z "$v" ] || [ "$v" = 1 ] || fail "doctor: не хватает зависимостей"
# 100 ticks a second are a whole core, so ticks a second are percent
cpu=''
[ "$watcher_pid" != "$(previous watcher_pid)" ] ||
	cpu=$(rate "$watcher_ticks" "$(previous watcher_ticks)")
report "$T_services" "FakeIP работает, маршрутизация не на паузе${cpu:+, watcher $(printf '%.1f' "$cpu")% ядра}" \
	"$(printf '%.0f' "${cpu:-0}")"

# doctor's tunnels=warn:<list>, one problem per tunnel or exit, in words
tunnel_problems() {
	printf '%s\n' "${1#warn:}" | tr ',' '\n' | sed \
		-e 's/^\([1-7]\)-down$/туннель \1 не подключён/' \
		-e 's/^\([1-7]\)-no-link$/у туннеля \1 нет интерфейса/' \
		-e 's/^\([1-7]\)-no-password$/у туннеля \1 нет пароля/' \
		-e 's/^exit-\([1-7]\)s-no-tunnel$/туннель \1 выключен, привязанный к нему трафик отклоняется/' \
		-e 's/^exit-\([1-7]\)-no-tunnel$/трафику туннеля \1 не осталось туннеля, он отклоняется/' |
		awk 'NF { printf "%s%s", sep, $0; sep = "; " } END { print "" }'
}

# 2. outbound tunnel
$SA installed proxy-out proxy4 || fail "CHILD_SA proxy4 не установлен"
vip=$(ip -4 -o addr show dev ipsec-out 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}' | head -n 1)
[ -n "$vip" ] || fail "на ipsec-out нет виртуального адреса"
fc=$($SYS failclosed-check 2>/dev/null | field failclosed_route)
[ "$fc" = ok ] || fail "fail-closed маршрут: ${fc:-нет}"
# doctor reports tunnels only when there is more than one
v=$(echo "$doctor" | field tunnels); case "$v" in '' | ok*) ;; *) fail "$(tunnel_problems "$v")";; esac
tun=$(trace www.cloudflare.com ipsec-out); tun_ip=${tun%% *}
if [ -z "$tun_ip" ]; then fail "через туннель нет ответа"
elif [ "$tun_ip" = "$wan_ip" ]; then fail "туннель выходит с домашнего IP $wan_ip"; fi
rtt=$(ping -c 3 -W 2 -q -I ipsec-out 1.1.1.1 2>/dev/null | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p')
report "$T_tunnel" "туннель поднят, выход $tun, задержка ${rtt%.*} мс" "${rtt%.*}"

# 2b. each other tunnel with a token of its own: up, leaving from elsewhere
# than WAN, and its round trip
tunnels_status=$(/usr/libexec/ikev2-manager tunnels-status 2>/dev/null)
for n in 2 3 4 5 6 7; do
	eval "token=\${T_tunnel_$n:-}"
	[ -n "$token" ] || continue
	if [ "$(uci -q get "ikev2-manager.tunnel_$n.enabled")" != 1 ]; then
		fail "туннель $n выключен"
		report "$token" ""
		continue
	fi
	$SA installed "proxy-out-$n" "proxy4-$n" || fail "CHILD_SA proxy4-$n не установлен"
	ip -4 -o addr show dev "ipsec-out$n" 2>/dev/null | grep -q inet ||
		fail "на ipsec-out$n нет виртуального адреса"
	exit_n=$(trace www.cloudflare.com "ipsec-out$n"); exit_n_ip=${exit_n%% *}
	if [ -z "$exit_n_ip" ]; then fail "через туннель $n нет ответа"
	elif [ "$exit_n_ip" = "$wan_ip" ]; then fail "туннель $n выходит с домашнего IP $wan_ip"; fi
	rtt_n=$(ping -c 3 -W 2 -q -I "ipsec-out$n" 1.1.1.1 2>/dev/null | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p')
	carries=$(printf '%s\n' "$tunnels_status" | sed -n "s/^tunnel=$n .*carries=\([0-9,]*\).*/\1/p")
	report "$token" "туннель $n поднят, выход $exit_n, задержка ${rtt_n%.*} мс${carries:+, несёт выходы $carries}" \
		"${rtt_n%.*}"
done

# 3. domain policy: the selected domain takes the tunnel, the control one WAN
answer=$(resolve "$PBR_DOMAIN" 127.0.0.1)
how="через туннель"
if [ "$(echo "$dr" | field engine)" = fakeip ]; then
	# The controller listens on loopback; its secret goes in on stdin, not
	# on a command line every process can read.
	json=/etc/ikev2-manager/domain-router.json
	controller=$(jsonfilter -i "$json" -e '@.experimental.clash_api.external_controller' 2>/dev/null)
	secret=$(jsonfilter -i "$json" -e '@.experimental.clash_api.secret' 2>/dev/null)
	connections=$(printf 'header = "Authorization: Bearer %s"\n' "$secret" |
		curl -s -m 5 -K - "http://$controller/connections" 2>/dev/null |
		jsonfilter -e '@.connections[*].id' 2>/dev/null | grep -c .)
	count="соединений через FakeIP: $connections"
	case "$answer" in 198.18.*) ;; *) fail "$PBR_DOMAIN резолвится в ${answer:-ничего}, а не в FakeIP";; esac
	if [ "$(echo "$dr" | field route_router_traffic)" = 1 ]; then
		pbr=$(trace "$PBR_DOMAIN"); pbr_ip=${pbr%% *}
		[ -n "$pbr_ip" ] && [ "$pbr_ip" = "$tun_ip" ] ||
			fail "$PBR_DOMAIN выходит с ${pbr:-нет ответа}, а не через туннель"
		how="через туннель ($pbr)"
	else
		# The router's own requests are not routed: only the answer is checked.
		how="получает FakeIP $answer"
	fi
else
	# Matching by address: the answer must have reached the routing set.
	[ -n "$answer" ] && nft get element inet ikev2_routing dst4 "{ $answer }" >/dev/null 2>&1 ||
		fail "адреса $PBR_DOMAIN (${answer:-нет ответа}) нет в наборе маршрутизации"
	how="в наборе маршрутизации ($answer)"
	connections=$(nft list set inet ikev2_routing dst4 2>/dev/null | tr ',' '\n' |
		grep -c '[0-9]\.[0-9]*\.[0-9]')
	count="адресов в наборе: $connections"
fi
[ -n "$wan_ip" ] && [ "$wan_ip" != "$tun_ip" ] || fail "$CONTROL_DOMAIN выходит не через WAN (${wan:-нет ответа})"
report "$T_domains" "$PBR_DOMAIN $how, $CONTROL_DOMAIN напрямую ($wan), $count" "${connections:-0}"

# 4. DNS
[ -n "$(resolve example.com 127.0.0.1)" ] || fail "роутер не резолвит example.com"
# A name nobody asked for before goes all the way to the upstream; it does
# not exist, and the answer saying so is what is timed.
started=$(uptime_cs)
nslookup "kuma-$now_cs-$$.example.com" 127.0.0.1 >/dev/null 2>&1
lookup_ms=$(( ($(uptime_cs) - started) * 10 ))
# doctor reports these only where they apply; a notice is a check not run yet
for k in dns_segments fakeip_data_plane; do
	v=$(echo "$doctor" | field "$k"); case "$v" in '' | ok* | notice*) ;; *) fail "doctor $k: $v";; esac
done
report "$T_dns" "резолв, DNS-сегменты и FakeIP в порядке, новое имя за $lookup_ms мс" "$lookup_ms"

# 5. inbound server
if [ "$(echo "$state" | field server_enabled)" = 1 ]; then
	bounded 10 swanctl --list-conns 2>/dev/null | grep -q '^ikev2-in:' || fail "соединение ikev2-in не загружено"
	ip link show ipsec-in 2>/dev/null | grep -q '[<,]UP[,>]' || fail "ipsec-in не поднят"
	/usr/libexec/ikev2-user-policy check >/dev/null 2>&1 || fail "политика пользователей не отвечает"
	gw=$(ip -4 -o addr show dev ipsec-in 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}' | head -n 1)
	for p in $LOCAL_NAMES; do
		n=${p%%=*}; want=${p#*=}
		got=$(resolve "$n" "${gw:-127.0.0.1}")
		[ "$got" = "$want" ] || fail "VPN-клиентам $n отдаётся ${got:-ничего}, ждали $want"
	done
else
	fail "входящий сервер выключен"
fi
clients=$($SA sessions ikev2-in 2>/dev/null | grep -c .)
report "$T_inbound" "сервер принимает, клиентов: $clients" "$clients"

# 6. server certificate
if [ -n "$CERT" ] && [ -f "$CERT" ] && ! command -v openssl >/dev/null 2>&1; then
	fail "нет openssl для проверки сертификата"
	report "$T_cert" ""
elif [ -n "$CERT" ] && [ -f "$CERT" ]; then
	# BusyBox date takes only YYYY-MM-DD; openssl prints "Dec  9 20:03:42 2026 GMT"
	end=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2 |
		awk '{m=index("JanFebMarAprMayJunJulAugSepOctNovDec",$1); printf "%s-%02d-%02d %s", $4, (m+2)/3, $2, $3}')
	left=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
	cn=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
	[ "$left" -gt 21 ] || fail "$cn истекает через $left дн."
	report "$T_cert" "$cn действует ещё $left дн." "$left"
fi

# 7. tunnel throughput since the last run (only when a token is configured)
if [ -n "$T_traffic" ]; then
	down=$(rate "$rx" "$(previous rx)"); up=$(rate "$tx" "$(previous tx)")
	if [ -n "$down" ] && [ -n "$up" ]; then
		kbit=$(awk -v d="$down" -v u="$up" 'BEGIN { printf "%.0f", (d + u) * 8 / 1000 }')
		report "$T_traffic" "$(awk -v d="$down" -v u="$up" 'BEGIN {
			printf "через туннели: вниз %.2f, вверх %.2f Мбит/с", d * 8 / 1e6, u * 8 / 1e6 }')" "$kbit"
	else
		report "$T_traffic" "первый замер, скорость будет в следующем" 0
	fi
fi

# 8. security findings from doctor (only when a token is configured)
if [ -n "$T_security" ]; then
	# doctor prints security_ok only when it is 0
	[ "$(echo "$doctor" | field security_ok)" != 0 ] ||
		fail "doctor: $(echo "$doctor" | grep '_security=' | grep -v '=ok' | tr '\n' ' ')"
	report "$T_security" "замечаний безопасности нет"
fi
exit 0
