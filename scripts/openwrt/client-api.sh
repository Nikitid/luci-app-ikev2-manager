#!/bin/sh
# Real HTTP/TLS and filesystem permissions in a disposable OpenWrt container.
set -eu
sh /src/scripts/openwrt/client-setup.sh
sh /src/scripts/openwrt/client-mail.sh
sh /src/scripts/openwrt/client-admin.sh
work="$(mktemp -d)"
server_pid=''
catalog_pid=''
api_pid=''
test_step=baseline
refused_pid=''
procd_pid=''
ubus_pid=''
cleanup() {
 test_rc=$?
 [ -z "$refused_pid" ] || { kill "$refused_pid" 2>/dev/null || :; wait "$refused_pid" 2>/dev/null || :; }
 [ "$test_rc" = 0 ] || printf "client-api: failed step=%s\n" "$test_step" >&2
 if [ -n "$procd_pid" ]; then
  /etc/init.d/ikev2-client-access stop >/dev/null 2>&1 || :
  kill "$procd_pid" 2>/dev/null || :; wait "$procd_pid" 2>/dev/null || :
 fi
 [ -z "$ubus_pid" ] || { kill "$ubus_pid" 2>/dev/null || :; wait "$ubus_pid" 2>/dev/null || :; }
 [ -z "$api_pid" ] || { kill "$api_pid" 2>/dev/null || :; wait "$api_pid" 2>/dev/null || :; }
 rm -rf /etc/ikev2-manager/test-api-tls
	[ -z "$catalog_pid" ] || { kill "$catalog_pid" 2>/dev/null || :; wait "$catalog_pid" 2>/dev/null || :; }
	rm -f /etc/ikev2-manager/services.d/api.lst /etc/ikev2-manager/services.d/other.lst
	[ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || :
	rm -rf "$work" /etc/ikev2-manager/clients /var/run/ikev2-client-reports
}
trap cleanup EXIT INT TERM
mkdir -p "$work/root" /etc/ikev2-manager/clients
chmod 700 /etc/ikev2-manager/clients
state=/etc/ikev2-manager/clients/state.json
fixture=/src/scripts/openwrt/client-api-state.uc
ucode "$fixture" /etc/ikev2-manager/clients seed
# Issue through the installed command, with one-shot private output. Neither
# the endpoint nor raw invitation may be accepted as a caller-selected secret.
issuer=/usr/libexec/ikev2-manager.d/client-access-invitation-control.uc
(
 umask 077
 ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); print(sprintf("%J", {version:1, expected_generation:0, endpoint:"https://"+s.publication.server.address+"/client/v1/enroll", id:"cli-laptop", selected_services:[s.publication.services[0].id], lifetime_seconds:600}));' "$state" >"$work/invitation-request"
 ucode "$issuer" issue <"$work/invitation-request" >"$work/invitation-result"
 ucode -e 'import {readfile} from "fs"; import {sha256} from "digest"; let r=json(readfile(ARGV[0])), j=json(readfile(ARGV[1])); let t=split(r.invitation,"#")[1]; if(r.id!="cli-laptop" || r.generation!=1 || !match(t,/^[a-f0-9]{64}$/) || j.ledger.invitations[0].token_sha256!=sha256(t) || index(readfile(ARGV[1]),t)>=0) die("CLI invitation contract failed");' "$work/invitation-result" /etc/ikev2-manager/clients/invitations.json
 if ucode "$issuer" issue <"$work/invitation-request" >"$work/invitation-refused" 2>"$work/invitation-error"; then
  printf '%s\n' 'client-api: stale CLI invitation accepted' >&2; exit 1
 fi
 [ ! -s "$work/invitation-refused" ]
 grep -Fxq 'client-access-invitation: issuance refused or unavailable' "$work/invitation-error"
)
printf '%s\n' 'client-api: installed invitation command, private output and stale refusal OK'
mkdir "$work/store-test"
chmod 700 "$work/store-test"
ucode /src/scripts/openwrt/client-state.uc "$work/store-test"
mkdir "$work/enrollment-test"
chmod 700 "$work/enrollment-test"
ucode /src/scripts/openwrt/client-enrollment.uc "$work/enrollment-test"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
	-keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
uhttpd -f -h "$work/root" -D -S -p 127.0.0.1:18080 -s 127.0.0.1:18443 \
	-C "$work/cert.pem" -K "$work/key.pem" -n 4 -N 8 -t 5 -T 5 -k 0 \
	-o /client/v1 -O /usr/libexec/ikev2-manager.d/client-access-http.uc >"$work/server.log" 2>&1 &
server_pid=$!
i=0
until curl -sk --max-time 2 https://127.0.0.1:18443/ >/dev/null; do
	i=$((i + 1)); [ "$i" -lt 20 ] || { cat "$work/server.log"; exit 1; }
	sleep 1
done
first=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
second=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
url=https://127.0.0.1:18443/client/v1/policy
request() {
	expected="$1"; shift
	status="$(curl -sk --max-time 5 -D "$work/headers" -o "$work/body" -w '%{http_code}' "$@")"
	[ "$status" = "$expected" ] || { printf 'client-api: expected %s, got %s\n' "$expected" "$status" >&2; cat "$work/server.log" >&2; exit 1; }
}
request 403 -H "Authorization: Bearer $first" http://127.0.0.1:18080/client/v1/policy
request 401 "$url"
request 401 -H 'Authorization: Bearer invalid' "$url"
request 401 -H "Authorization: Bearer $second" "$url"
request 401 -H 'Authorization: Bearer cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' "$url"
request 200 -H "Authorization: Bearer $first" "$url"
grep -qi '^Cache-Control: no-store' "$work/headers"
ucode -e "import {readfile} from 'fs'; let p=json(readfile('$work/body')); if(p.id!='team' || p.revision!=1) die('Wrong device policy');"
request 404 -H "Authorization: Bearer $first" "$url?device=second"
# The answer came from the caller's own view: one file named by the digest of
# its key, made with the state and standing for that very state file.
views="$(readlink /etc/ikev2-manager/clients/views)"
[ "$views" = views-1 ] && [ -s "/etc/ikev2-manager/clients/$views/t-$(printf %s "$first" | sha256sum | cut -c1-64).json" ]
[ "$(ucode /usr/libexec/ikev2-manager.d/client-access-control.uc views)" = generation=1 ]
[ "$(ls -ld "/etc/ikev2-manager/clients/$views" | cut -c1-10)" = drwx------ ]
request 405 -X POST -H "Authorization: Bearer $first" "$url"
request 400 -X GET -d '{}' -H "Authorization: Bearer $first" "$url"
request 404 https://127.0.0.1:18443/ubus
request 404 https://127.0.0.1:18443/cgi-bin/luci
request 401 https://127.0.0.1:18443/client/v1/services
request 200 -H "Authorization: Bearer $first" https://127.0.0.1:18443/client/v1/services
ucode -e "import {readfile} from 'fs'; let s=json(readfile('$work/body')); if(length(keys(s))!=8 || type(s.names_https)!='bool' || s.mode!='services' || s.block_without_tunnel!==true || s.version!==1 || s.id!='team' || s.revision!=1 || type(s.available)!='array' || length(s.selected)<1 || type(s.selected[0].id)!='string' || s.selected[0].domains<1 || length(keys(s.selected[0]))!=2) die('Device service list is wrong');"
! grep -q 'example.com' "$work/body"
request 401 https://127.0.0.1:18443/client/v1/release
request 200 -H "Authorization: Bearer $first" https://127.0.0.1:18443/client/v1/release
[ "$(jsonfilter -i "$work/body" -e '@.release')" = "$(cat /usr/share/ikev2-manager/version)" ]
[ "$(jsonfilter -i "$work/body" -e '@.version')" = 1 ]
# A person who opens their link in a browser is offered the program for the
# computer in front of them; the page loads nothing from elsewhere and the
# programs' own POST to the same address is untouched.
page=https://127.0.0.1:18443/client/v1/enroll
version="$(cat /usr/share/ikev2-manager/version)"
request 200 -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' -H 'Accept-Language: ru-RU,ru;q=0.9' "$page"
grep -qi '^Content-Type: text/html' "$work/headers"; grep -qi "^Content-Security-Policy: default-src 'none'" "$work/headers"
grep -q "class=\"main\" href=\"https://github.com/Nikitid/luci-app-ikev2-manager/releases/download/v$version/WaypointSetup.exe\"" "$work/body"
grep -q "class=\"plain\" href=\"[^\"]*/Waypoint-$version.pkg\"" "$work/body"; grep -q 'Скачать для Windows' "$work/body"
request 200 -A 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15' "$page"
grep -q "class=\"main\" href=\"[^\"]*/Waypoint-$version.pkg\"" "$work/body"; grep -q 'Download for macOS' "$work/body"
request 200 -A 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15' "$page"
! grep -q 'href=' "$work/body"; grep -q 'VPN profile' "$work/body"
request 200 -A 'curl/8' "$page"
[ "$(grep -o 'class="main"' "$work/body" | wc -l)" = 2 ]
! grep -qi '<script\|src=' "$work/body"
request 401 -X POST "$page"
printf '%s\n' 'client-api: the link opened in a browser offers the program for that computer'
# A report is taken only from a device the administrator asked, once, whole
# and within the limit; the administrator then reads exactly what was sent.
report=https://127.0.0.1:18443/client/v1/report
request 401 "$report"
request 401 -H "Authorization: Bearer $second" "$report"
request 200 -H "Authorization: Bearer $first" "$report"
[ "$(jsonfilter -i "$work/body" -e '@.wanted')" = false ]
request 409 -X POST -H 'Content-Type: application/json' -d '{"state":"unasked"}' -H "Authorization: Bearer $first" "$report"
[ ! -e /var/run/ikev2-client-reports/team.json ]
if /usr/libexec/ikev2-client-admin client-admin-report-request unknown-device >/dev/null 2>&1; then echo 'client-api: a report was asked of an unknown device' >&2; exit 1; fi
/usr/libexec/ikev2-client-admin client-admin-report-request team | grep -Fxq 'requested=1'
ucode /usr/libexec/ikev2-manager.d/client-access-control.uc inspect >"$work/report-inspection"
ucode -e 'import {readfile} from "fs"; let d=filter(json(readfile(ARGV[0])).devices, d => d.id=="team")[0]; if(d.report_wanted!==true || d.report_seconds!=null) die("A requested report is not shown as awaited");' "$work/report-inspection"
request 200 -H "Authorization: Bearer $first" "$report"
[ "$(jsonfilter -i "$work/body" -e '@.wanted')" = true ]
request 400 -X POST -H 'Content-Type: application/json' -d 'not json' -H "Authorization: Bearer $first" "$report"
request 400 -X POST -H 'Content-Type: application/json' -d '["a list"]' -H "Authorization: Bearer $first" "$report"
head -c 40000 /dev/zero | tr '\0' 'a' >"$work/oversized"
request 400 -X POST -H 'Content-Type: application/json' --data-binary "@$work/oversized" -H "Authorization: Bearer $first" "$report"
request 401 -X POST -H 'Content-Type: application/json' -d '{"state":"other"}' -H "Authorization: Bearer $second" "$report"
[ ! -e /var/run/ikev2-client-reports/team.json ]
ucode -e 'let faults=[]; for (let i=0;i<40;i++) push(faults, "2026-01-01T00:00:00Z tick Fault " + i); print(sprintf("%J", {state:"error", faults:faults, padding: substr(sprintf("%1024s",""),0,1000)}));' >"$work/report-sent"
request 200 -X POST -H 'Content-Type: application/json' --data-binary "@$work/report-sent" -H "Authorization: Bearer $first" "$report"
/usr/libexec/ikev2-client-admin client-admin-report team >"$work/report-read"
ucode -e 'import {readfile} from "fs"; let r=json(readfile(ARGV[0])), sent=json(readfile(ARGV[1])); if(r.id!="team" || r.version!==1 || type(r.received_at)!="int" || sprintf("%J",r.report)!=sprintf("%J",sent)) die("The stored report differs from the one sent");' "$work/report-read" "$work/report-sent"
[ "$(ls -l /var/run/ikev2-client-reports/team.json | cut -c1-10)" = -rw------- ]
request 200 -H "Authorization: Bearer $first" "$report"
[ "$(jsonfilter -i "$work/body" -e '@.wanted')" = false ]
request 409 -X POST -H 'Content-Type: application/json' -d '{"state":"again"}' -H "Authorization: Bearer $first" "$report"
ucode /usr/libexec/ikev2-manager.d/client-access-control.uc inspect >"$work/report-inspection"
ucode -e 'import {readfile} from "fs"; let d=filter(json(readfile(ARGV[0])).devices, d => d.id=="team")[0]; if(d.report_wanted!==false || type(d.report_seconds)!="int") die("A received report is not shown");' "$work/report-inspection"
printf '%s\n' 'client-api: a report is taken only when asked, whole, and read back unchanged'
request 401 https://127.0.0.1:18443/client/v1/readiness
request 400 -H "Authorization: Bearer $first" https://127.0.0.1:18443/client/v1/readiness
request 503 -H "Authorization: Bearer $first" -H 'X-Client-Address: 10.25.0.10' https://127.0.0.1:18443/client/v1/readiness
request 401 -H "Authorization: Bearer $second" -H 'X-Client-Address: 10.25.0.10' https://127.0.0.1:18443/client/v1/readiness
ucode "$fixture" /etc/ikev2-manager/clients update
request 200 -H "Authorization: Bearer $first" "$url"
ucode -e "import {readfile} from 'fs'; let p=json(readfile('$work/body')); if(p.revision!=2 || length(filter(p.resources, r => r.domain == 'updated.example.com')) != 1) die('Stale catalog policy returned');"
ucode "$fixture" /etc/ikev2-manager/clients enable-second
request 200 -H "Authorization: Bearer $second" "$url"
ucode -e "import {readfile} from 'fs'; let p=json(readfile('$work/body')); if(p.id!='other' || p.revision!=1) die('Wrong second policy');"
ucode "$fixture" /etc/ikev2-manager/clients disable-first
request 401 -H "Authorization: Bearer $first" "$url"
ucode "$fixture" /etc/ikev2-manager/clients seed
ucode "$fixture" /etc/ikev2-manager/clients invalid-policy
request 503 -H "Authorization: Bearer $first" "$url"
! grep -q 'must-never-be-returned' "$work/body"
ucode "$fixture" /etc/ikev2-manager/clients seed
ucode "$fixture" /etc/ikev2-manager/clients duplicate-token
request 503 -H "Authorization: Bearer $first" "$url"
ucode "$fixture" /etc/ikev2-manager/clients seed
ucode "$fixture" /etc/ikev2-manager/clients inconsistent
request 503 -H "Authorization: Bearer $first" "$url"
ucode "$fixture" /etc/ikev2-manager/clients seed
chmod 644 "$state"
request 503 -H "Authorization: Bearer $first" "$url"
chmod 600 "$state"
chmod 755 /etc/ikev2-manager/clients
request 503 -H "Authorization: Bearer $first" "$url"
chmod 700 /etc/ikev2-manager/clients
mv "$state" "$work/real-state"
ln -s "$work/real-state" "$state"
request 503 -H "Authorization: Bearer $first" "$url"
ucode "$fixture" /etc/ikev2-manager/clients seed
ucode -e "import {readfile} from 'fs'; let s=json(readfile('$state')); let d=s.publication; delete d.allocations; for(let v in d.devices) delete v.previous_policy; print(sprintf('%J', {version:1, expected_generation:s.generation, desired:d}));" >"$work/publication.json"
control=/usr/libexec/ikev2-manager.d/client-access-control.uc
ucode "$control" publish <"$work/publication.json" >"$work/result"
grep -Fxq 'generation=2' "$work/result"
if ucode "$control" publish <"$work/publication.json" >"$work/result" 2>"$work/error"; then
	printf '%s\n' 'client-api: stale administrative update accepted' >&2
	exit 1
fi
[ ! -s "$work/result" ]
! grep -q "$first" "$work/error"
ucode "$control" status >"$work/result"
grep -Fxq 'generation=2' "$work/result"
grep -Fxq 'devices=2' "$work/result"
ucode -e "import {readfile} from 'fs'; let r=json(readfile('$work/publication.json')); r.expected_generation=0; print(sprintf('%J',r));" >"$work/initial.json"
if ucode "$control" initialize <"$work/initial.json" >/dev/null 2>&1; then
	printf '%s\n' 'client-api: administrative reinitialization accepted' >&2
	exit 1
fi
# This removal resets only the disposable test container's fixture.
rm -rf /etc/ikev2-manager/clients
ucode "$control" initialize <"$work/initial.json" >"$work/result"
grep -Fxq 'generation=1' "$work/result"
request 200 -H "Authorization: Bearer $first" "$url"
# Verify an existing authenticated API client sees the background catalog
# publication, rather than testing API and administrative updates separately.
mkdir -p /etc/ikev2-manager/services.d
ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); for(let name in s.publication.services[0].domains) print(name+"\n");' "$state" >/etc/ikev2-manager/services.d/api.lst
printf 'other.example.com\n' >/etc/ikev2-manager/services.d/other.lst
cp /usr/libexec/ikev2-client-catalog "$work/catalog-worker.sh"
IKEV2_CLIENT_CATALOG_RUNTIME="$work/catalog-runtime" IKEV2_CLIENT_CATALOG_INTERVAL=1 IKEV2_CLIENT_CATALOG_RETRY=1 sh "$work/catalog-worker.sh" watch >"$work/catalog.log" 2>&1 &
catalog_pid=$!
printf 'central.api.example.com\n' >>/etc/ikev2-manager/services.d/api.lst
i=0
while :; do
 request 200 -H "Authorization: Bearer $first" "$url"
 if ucode -e 'import {readfile} from "fs"; let p=json(readfile(ARGV[0])); if(p.revision!=2 || length(filter(p.resources,r=>r.domain=="central.api.example.com"))!=1) exit(1);' "$work/body"; then break; fi
 i=$((i + 1)); [ "$i" -lt 15 ] || { cat "$work/catalog.log" >&2; exit 1; }
 sleep 1
done
kill "$catalog_pid"
wait "$catalog_pid" 2>/dev/null || :
catalog_pid=''
printf '%s\n' 'client-api: background catalog update reached authenticated HTTPS client'
printf '%s\n' 'client-api: TLS, device isolation, updates, revocation, schema and permissions OK'

# Exercise the installed persistent TLS launcher, not a hand-written uhttpd line.
case "${CLIENT_API_MUTATION:-}" in
 key-mode) sed -i 's/(private_key \&\& (info.mode \& 0077) != 0)/false/' /usr/libexec/ikev2-manager.d/client-api-settings.uc ;;
 tls-validation) sed -i '/^openssl verify /c\:' /usr/libexec/ikev2-client-api ;;
 certificate-watch) sed -i 's@procd_set_param file /etc/config/ikev2-manager "\$api_certificate" "\$api_key"@procd_set_param file /etc/config/ikev2-manager@' /etc/init.d/ikev2-client-access ;;
esac
tls=/etc/ikev2-manager/test-api-tls
mkdir -m 700 "$tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=vpn.example.com' -addext 'subjectAltName=DNS:vpn.example.com' -keyout "$tls/key.pem" -out "$tls/certificate.pem" >/dev/null 2>&1
chmod 600 "$tls/key.pem" "$tls/certificate.pem"
uci set ikev2-manager.client_access=client_access
uci set ikev2-manager.client_access.enabled=1
uci set ikev2-manager.client_access.port=19443
uci set ikev2-manager.server.enabled=1
uci set ikev2-manager.server.identity=vpn.example.com
uci set ikev2-manager.server.cert_file="$tls/certificate.pem"
uci set ikev2-manager.server.key_file="$tls/key.pem"
uci commit ikev2-manager
launcher=/usr/libexec/ikev2-client-api
test_step=launcher-start
"$launcher" serve >"$work/launcher-log" 2>&1 &
api_pid=$!
i=0
until curl --noproxy '*' -s --cacert "$tls/certificate.pem" --resolve vpn.example.com:19443:127.0.0.1 --max-time 2 https://vpn.example.com:19443/client/v1/policy -o "$work/launcher-body" -w '%{http_code}' | grep -qx 401; do
 i=$((i+1)); [ "$i" -lt 15 ] || { cat "$work/launcher-log" >&2; exit 1; }; sleep 1
done
test_step=request-limit
# One address that opens connections far faster than a client ever does is
# dropped, and served again once it slows down; the limit goes with the server.
nft list table inet ikev2_client_api | grep -q 'tcp dport 19443'
# In a subshell, so that waiting for the flood does not wait for the server.
(
 flood=0
 while [ "$flood" -lt 160 ]; do
  curl --noproxy '*' -s --cacert "$tls/certificate.pem" --resolve vpn.example.com:19443:127.0.0.1 --connect-timeout 1 --max-time 1 https://vpn.example.com:19443/client/v1/policy -o /dev/null &
  flood=$((flood + 1))
 done
 wait
) || :
nft list set inet ikev2_client_api recent4 | grep -q '127.0.0.1'
sleep 12
curl --noproxy '*' -s --cacert "$tls/certificate.pem" --resolve vpn.example.com:19443:127.0.0.1 --max-time 3 https://vpn.example.com:19443/client/v1/policy -o /dev/null
test_step=authenticated
status="$(curl --noproxy '*' -s --cacert "$tls/certificate.pem" --resolve vpn.example.com:19443:127.0.0.1 --max-time 5 -H "Authorization: Bearer $first" https://vpn.example.com:19443/client/v1/policy -o "$work/launcher-body" -w '%{http_code}')"
[ "$status" = 200 ]
test_step=isolation
for path in /ubus /cgi-bin/luci /certificate.pem /key.pem; do
 status="$(curl --noproxy '*' -s --cacert "$tls/certificate.pem" --resolve vpn.example.com:19443:127.0.0.1 --max-time 5 "https://vpn.example.com:19443$path" -o "$work/launcher-body" -w '%{http_code}')"
 [ "$status" = 404 ]
done
# IPv6 reaches the same strict TLS API when the container supports IPv6.
test_step=ipv6
if [ -f /proc/net/if_inet6 ] && grep -q '00000000000000000000000000000001' /proc/net/if_inet6; then
 status="$(curl --noproxy '*' -s --cacert "$tls/certificate.pem" --resolve 'vpn.example.com:19443:[::1]' --max-time 5 https://vpn.example.com:19443/client/v1/policy -o "$work/launcher-body" -w '%{http_code}')"
 [ "$status" = 401 ]
 printf '%s\n' 'client-api: trusted HTTPS over IPv6 verified'
fi
test_step=shutdown
kill "$api_pid"; wait "$api_pid"; api_pid=''
if curl --noproxy '*' -sk --max-time 2 https://127.0.0.1:19443/client/v1/policy >/dev/null; then echo 'API child survived launcher stop' >&2; exit 1; fi
refuse_launcher() {
 "$launcher" serve >"$work/launcher-refused" 2>&1 &
 refused_pid=$!
 attempt=0
 while kill -0 "$refused_pid" 2>/dev/null; do
  attempt=$((attempt+1))
  if [ "$attempt" -ge 4 ]; then
   kill "$refused_pid" 2>/dev/null || :; wait "$refused_pid" 2>/dev/null || :; refused_pid=''
   printf "Unsafe API configuration remained running at %s\n" "$test_step" >&2; exit 1
  fi
  sleep 1
 done
 refused_rc=0; wait "$refused_pid" || refused_rc=$?; refused_pid=''
 [ "$refused_rc" != 0 ] || { echo 'Unsafe API configuration accepted' >&2; exit 1; }
 grep -Fxq 'Client HTTPS API configuration refused.' "$work/launcher-refused"
}
test_step=disabled
uci set ikev2-manager.client_access.enabled=0; refuse_launcher
uci set ikev2-manager.client_access.enabled=1
test_step=port
uci set ikev2-manager.client_access.port=443; refuse_launcher
uci set ikev2-manager.client_access.port=19443
test_step=identity
uci set ikev2-manager.server.identity=other.example.com; refuse_launcher
uci set ikev2-manager.server.identity=vpn.example.com
test_step=key-permissions
chmod 644 "$tls/key.pem"; refuse_launcher
chmod 600 "$tls/key.pem"
test_step=key-mismatch
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tls/wrong.key" >/dev/null 2>&1
chmod 600 "$tls/wrong.key"
uci set ikev2-manager.server.key_file="$tls/wrong.key"; refuse_launcher
uci set ikev2-manager.server.key_file="$tls/key.pem"
test_step=expired-certificate
# OpenSSL25 rejects negative -days; explicit dates work on both releases.
printf '01\n' >"$tls/serial"
: >"$tls/index"
cat >"$tls/ca.conf" <<EOF
[ca]
default_ca=local
[local]
database=$tls/index
serial=$tls/serial
new_certs_dir=$tls
default_md=sha256
policy=subject
x509_extensions=server
[subject]
commonName=supplied
[server]
subjectAltName=DNS:vpn.example.com
basicConstraints=critical,CA:FALSE
extendedKeyUsage=serverAuth
EOF
openssl req -new -key "$tls/key.pem" -subj '/CN=vpn.example.com' -out "$tls/expired.csr" >/dev/null 2>&1
openssl ca -batch -selfsign -config "$tls/ca.conf" -keyfile "$tls/key.pem" -cert "$tls/certificate.pem" -in "$tls/expired.csr" -out "$tls/expired.pem" -notext -startdate 20000101000000Z -enddate 20000102000000Z >/dev/null 2>&1
chmod 600 "$tls/expired.pem"
uci set ikev2-manager.server.cert_file="$tls/expired.pem"; refuse_launcher
uci set ikev2-manager.server.cert_file="$tls/certificate.pem"
test_step=key-symlink
mv "$tls/key.pem" "$tls/retained.key"; ln -s "$tls/retained.key" "$tls/key.pem"; refuse_launcher
rm "$tls/key.pem"; mv "$tls/retained.key" "$tls/key.pem"
printf '%s\n' 'client-api: installed TLS launcher, trusted HTTPS, IPv6, isolation, shutdown and unsafe configuration refusal OK'

# Actual OpenWrt service supervision, reload and disable in this container.
mkdir -p /var/run/ubus
/sbin/ubusd >"$work/ubus-log" 2>&1 &
ubus_pid=$!
test_step=procd-start
/sbin/procd -S >"$work/procd-log" 2>&1 &
procd_pid=$!
i=0
until ubus list service >/dev/null 2>&1; do
 i=$((i+1)); [ "$i" -lt 15 ] || { cat "$work/procd-log" >&2; exit 1; }; sleep 1
done
/etc/init.d/ikev2-client-access start
probe_service() {
 service_port="$1"
 i=0
 until curl --noproxy '*' -s --cacert "$tls/certificate.pem" --resolve "vpn.example.com:$service_port:127.0.0.1" --max-time 2 "https://vpn.example.com:$service_port/client/v1/policy" -o "$work/launcher-body" -w '%{http_code}' | grep -qx 401; do
  i=$((i+1)); [ "$i" -lt 15 ] || { cat "$work/procd-log" >&2; exit 1; }; sleep 1
 done
}
test_step=procd-probe
probe_service 19443
ubus call service list '{"name":"ikev2-client-access"}' >"$work/service-before"
uci set ikev2-manager.client_access.port=19444; uci commit ikev2-manager
test_step=procd-reload
/etc/init.d/ikev2-client-access reload
probe_service 19444
ucode /usr/libexec/ikev2-manager.d/client-access-control.uc inspect >"$work/api-inspection"
ucode -e 'import {readfile} from "fs"; let s=json(readfile(ARGV[0])); if(s.api_endpoint!="https://vpn.example.com:19444/client/v1/enroll") die("Administrative invitation endpoint did not follow configured port");' "$work/api-inspection"
ubus call service list '{"name":"ikev2-client-access"}' >"$work/service-after"
ucode -e 'import {readfile} from "fs"; let before=json(readfile(ARGV[0]))["ikev2-client-access"].instances, after=json(readfile(ARGV[1]))["ikev2-client-access"].instances; for(let name in ["access","catalog","enrollment"]) if(type(before[name].pid)!="int" || before[name].pid!=after[name].pid) die("API reload restarted another client controller");' "$work/service-before" "$work/service-after"
if curl --noproxy '*' -sk --max-time 2 https://127.0.0.1:19443/client/v1/policy >/dev/null; then echo 'Old API listener survived reload' >&2; exit 1; fi
test_step=certificate-reload
openssl req -x509 -key "$tls/key.pem" -days 2 -subj '/CN=vpn.example.com' -addext 'subjectAltName=DNS:vpn.example.com' -out "$tls/renewed.pem" >/dev/null 2>&1
chmod 600 "$tls/renewed.pem"; mv "$tls/renewed.pem" "$tls/certificate.pem"
/etc/init.d/ikev2-client-access reload
probe_service 19444
. /usr/libexec/ikev2-manager.d/package-manager.sh
pkg_run_bounded 6 openssl s_client -connect 127.0.0.1:19444 -servername vpn.example.com -CAfile "$tls/certificate.pem" -verify_return_error -showcerts </dev/null >"$work/peer-certificate" 2>/dev/null || :
openssl x509 -in "$work/peer-certificate" -fingerprint -sha256 -noout >"$work/peer-fingerprint"
openssl x509 -in "$tls/certificate.pem" -fingerprint -sha256 -noout >"$work/expected-fingerprint"
cmp -s "$work/peer-fingerprint" "$work/expected-fingerprint"
printf '%s\n' 'client-api: certificate renewal reload served the new peer certificate'
uci set ikev2-manager.client_access.enabled=0; uci commit ikev2-manager
/etc/init.d/ikev2-client-access reload
sleep 1
if curl --noproxy '*' -sk --max-time 2 https://127.0.0.1:19444/client/v1/policy >/dev/null; then echo 'Disabled API listener remained open' >&2; exit 1; fi
printf '%s\n' 'client-api: actual procd startup, configuration reload and disable passed'
