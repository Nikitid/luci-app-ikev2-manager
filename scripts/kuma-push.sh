#!/bin/sh
# shellcheck disable=SC2154 # T_* tokens are defined in the sourced config
#
# Push IKEv2 manager health to Uptime Kuma push monitors. Runs on the router
# from cron and changes nothing: every check below is a read-only status call
# or a single HTTPS request.
#
# Config, kept on the router only (tokens are secrets):
#   /etc/ikev2-kuma/kuma.conf
#     KUMA=http://kuma-host:port
#     PBR_DOMAIN=<a domain the policy routes through the tunnel>
#     CONTROL_DOMAIN=<a domain that must stay on WAN>
#     LOCAL_NAMES="<name>=<address> ..."   optional split-DNS answers to verify
#     CERT=/etc/swanctl/x509/<server>.pem  optional
#     T_services= T_tunnel= T_domains= T_dns= T_inbound= T_cert=
#     T_security=   optional: doctor security findings
#
# Usage: kuma-push.sh

CONF="${CONF:-/etc/ikev2-kuma/kuma.conf}"
# shellcheck disable=SC1090 # path is set at run time
. "$CONF" || exit 1
SYS=/usr/libexec/ikev2-manager-system
DR=/usr/libexec/ikev2-domain-router

push() {
	curl -s -o /dev/null -m 10 -G "$KUMA/api/push/$1" --data-urlencode "status=$2" \
		--data-urlencode "msg=$3" --data-urlencode "ping=$4"
}

# field <name>=<value> from "key=value" lines on stdin
field() { sed -n "s/^$1=//p" | head -n 1; }

# cloudflare trace: prints "ip loc" for the path a request to <host> takes
trace() {
	curl -s -m 10 ${2:+--interface $2} "https://$1/cdn-cgi/trace" 2>/dev/null |
		awk -F= '$1=="ip"{i=$2} $1=="loc"{l=$2} END{if (i!="") print i" "l}'
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
report "$T_services" "FakeIP работает, маршрутизация не на паузе"

# 2. outbound tunnel
sas=$(swanctl --list-sas 2>/dev/null)
echo "$sas" | grep -q 'proxy4:.*INSTALLED' || fail "CHILD_SA proxy4 не установлен"
vip=$(ip -4 -o addr show dev ipsec-out 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}' | head -n 1)
[ -n "$vip" ] || fail "на ipsec-out нет виртуального адреса"
fc=$($SYS failclosed-check 2>/dev/null | field failclosed_route)
[ "$fc" = ok ] || fail "fail-closed маршрут: ${fc:-нет}"
tun=$(trace www.cloudflare.com ipsec-out); tun_ip=${tun%% *}
if [ -z "$tun_ip" ]; then fail "через туннель нет ответа"
elif [ "$tun_ip" = "$wan_ip" ]; then fail "туннель выходит с домашнего IP $wan_ip"; fi
rtt=$(ping -c 3 -W 2 -q -I ipsec-out 1.1.1.1 2>/dev/null | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p')
report "$T_tunnel" "туннель поднят, выход $tun, задержка ${rtt%.*} мс" "${rtt%.*}"

# 3. domain policy: PBR domain via FakeIP and tunnel, control on WAN
fake=$(nslookup "$PBR_DOMAIN" 127.0.0.1 2>/dev/null | awk '/^Address/ && $NF !~ /:/ && NR>2 {print $NF; exit}')
case "$fake" in 198.18.*) ;; *) fail "$PBR_DOMAIN резолвится в ${fake:-ничего}, а не в FakeIP";; esac
pbr=$(trace "$PBR_DOMAIN"); pbr_ip=${pbr%% *}
[ -n "$pbr_ip" ] && [ "$pbr_ip" = "$tun_ip" ] || fail "$PBR_DOMAIN выходит с ${pbr:-нет ответа}, а не через туннель"
[ -n "$wan_ip" ] && [ "$wan_ip" != "$tun_ip" ] || fail "$CONTROL_DOMAIN выходит не через WAN (${wan:-нет ответа})"
report "$T_domains" "$PBR_DOMAIN через туннель ($pbr), $CONTROL_DOMAIN напрямую ($wan)"

# 4. DNS
nslookup example.com 127.0.0.1 >/dev/null 2>&1 || fail "роутер не резолвит example.com"
for k in dns_segments fakeip_data_plane; do
	v=$(echo "$doctor" | field "$k"); case "$v" in ok*) ;; *) fail "doctor $k: ${v:-нет}";; esac
done
report "$T_dns" "резолв, DNS-сегменты и FakeIP в порядке"

# 5. inbound server
if [ "$(echo "$state" | field server_enabled)" = 1 ]; then
	swanctl --list-conns 2>/dev/null | grep -q '^ikev2-in:' || fail "соединение ikev2-in не загружено"
	ip link show ipsec-in 2>/dev/null | grep -q '[<,]UP[,>]' || fail "ipsec-in не поднят"
	/usr/libexec/ikev2-user-policy check >/dev/null 2>&1 || fail "политика пользователей не отвечает"
	gw=$(ip -4 -o addr show dev ipsec-in 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}' | head -n 1)
	for p in $LOCAL_NAMES; do
		n=${p%%=*}; want=${p#*=}
		got=$(nslookup "$n" "${gw:-127.0.0.1}" 2>/dev/null | awk '/^Address/ && $NF !~ /:/ && NR>2 {print $NF; exit}')
		[ "$got" = "$want" ] || fail "VPN-клиентам $n отдаётся ${got:-ничего}, ждали $want"
	done
else
	fail "входящий сервер выключен"
fi
report "$T_inbound" "сервер принимает, клиентов: $(echo "$sas" | grep -c 'EAP:')"

# 6. server certificate
if [ -n "$CERT" ] && [ -f "$CERT" ]; then
	# BusyBox date takes only YYYY-MM-DD; openssl prints "Dec  9 20:03:42 2026 GMT"
	end=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2 |
		awk '{m=index("JanFebMarAprMayJunJulAugSepOctNovDec",$1); printf "%s-%02d-%02d %s", $4, (m+2)/3, $2, $3}')
	left=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
	cn=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
	[ "$left" -gt 21 ] || fail "$cn истекает через $left дн."
	report "$T_cert" "$cn действует ещё $left дн."
fi

# 7. security findings from doctor (only when a token is configured)
if [ -n "$T_security" ]; then
	[ "$(echo "$doctor" | field security_ok)" = 1 ] ||
		fail "doctor: $(echo "$doctor" | grep '_security=' | grep -v '=ok' | tr '\n' ' ')"
	report "$T_security" "замечаний безопасности нет"
fi
exit 0
