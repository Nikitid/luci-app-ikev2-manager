#!/bin/sh
# Actual HTTPS claim -> background strongSwan work -> initial credential bundle.
set -eu
umask 077
work="$(mktemp -d)"
server=''
worker=''
cleanup() {
	[ -z "$worker" ] || { kill "$worker" 2>/dev/null || :; wait "$worker" 2>/dev/null || :; }
	[ -z "$server" ] || kill "$server" 2>/dev/null || :
	rm -rf "$work" /etc/ikev2-manager/clients
}
trap cleanup EXIT INT TERM
rm -rf /etc/ikev2-manager/clients
mkdir -m 700 /etc/ikev2-manager/clients
mkdir "$work/root"
ucode /src/scripts/openwrt/client-runtime-state.uc /etc/ikev2-manager/clients seed
ucode /src/scripts/openwrt/client-enrollment-http.uc seed
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
	-keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
uhttpd -f -h "$work/root" -D -S -p 127.0.0.1:18080 -s 127.0.0.1:18443 \
	-C "$work/cert.pem" -K "$work/key.pem" -n 4 -N 8 -t 5 -T 5 -k 0 \
	-o /client/v1 -O /usr/libexec/ikev2-manager.d/client-access-http.uc >"$work/http.log" 2>&1 &
server=$!
i=0
until curl -sk --max-time 2 https://localhost:18443/ >/dev/null; do
	i=$((i + 1)); [ "$i" -lt 15 ] || exit 1
	sleep 1
done
invite=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
device=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
other=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
claim=https://localhost:18443/client/v1/enroll
poll=https://localhost:18443/client/v1/enrollment
request() {
	expected="$1"; shift
	status="$(curl --cacert "$work/cert.pem" --max-time 5 -D "$work/headers" -o "$work/body" -w '%{http_code}' "$@")"
	[ "$status" = "$expected" ] || { printf 'enrollment-http: expected %s, got %s\n' "$expected" "$status" >&2; exit 1; }
}
if curl --max-time 3 "$poll" >/dev/null 2>&1; then exit 1; fi
request 403 -X POST -H "Authorization: Bearer $invite" -H "X-Device-Token: $device" http://localhost:18080/client/v1/enroll
request 405 -H "Authorization: Bearer $invite" "$claim"
grep -qi '^Allow: POST' "$work/headers"
request 401 -X POST -H "X-Device-Token: $device" "$claim"
request 400 -X POST -H "Authorization: Bearer $invite" "$claim"
request 400 -X POST -H "Authorization: Bearer $invite" -H "X-Device-Token: $device" -d '{}' "$claim"
request 202 -X POST -H "Authorization: Bearer $invite" -H "X-Device-Token: $device" "$claim"
grep -qi '^Cache-Control: no-store' "$work/headers"
! grep -q 'password\|policy' "$work/body"
request 202 -X POST -H "Authorization: Bearer $invite" -H "X-Device-Token: $device" "$claim"
request 401 -X POST -H "Authorization: Bearer $invite" -H "X-Device-Token: $other" "$claim"
request 202 -H "Authorization: Bearer $device" "$poll"
request 401 -H "Authorization: Bearer $other" "$poll"
request 401 -H "Authorization: Bearer $invite" "$poll"
request 404 -H "Authorization: Bearer $device" "$poll?device=other"
request 404 https://localhost:18443/ubus
/usr/libexec/ikev2-client-enrollment watch >"$work/worker.log" 2>&1 &
worker=$!
i=0
while :; do
	status="$(curl --cacert "$work/cert.pem" --max-time 5 -o "$work/body" -w '%{http_code}' -H "Authorization: Bearer $device" "$poll")"
	[ "$status" = 200 ] && break
	[ "$status" = 202 ] || exit 1
	i=$((i + 1)); [ "$i" -lt 20 ] || exit 1
	sleep 1
done
ucode /src/scripts/openwrt/client-enrollment-http.uc bundle "$work/body"
request 200 -H "Authorization: Bearer $device" "$poll"
credential=/etc/ikev2-manager/clients/credentials/http-laptop.json
cp "$credential" "$work/credential"
chmod 644 "$credential"
request 503 -H "Authorization: Bearer $device" "$poll"
! grep -q 'password\|credentials' "$work/body"
chmod 600 "$credential"
ucode /src/scripts/openwrt/client-enrollment-http.uc wrong-password
request 503 -H "Authorization: Bearer $device" "$poll"
! grep -q 'password\|credentials' "$work/body"
cp "$work/credential" "$credential"
request 200 -H "Authorization: Bearer $device" "$poll"
cp /etc/ikev2-manager/clients/invitations.json "$work/invitations"
ucode /src/scripts/openwrt/client-enrollment-http.uc future-clock
request 503 -H "Authorization: Bearer $device" "$poll"
cp "$work/invitations" /etc/ikev2-manager/clients/invitations.json
# Registration opened the device: its policy is served at once, and its bundle
# stays retrievable by its own key until the invitation ends, open or closed.
request 200 -H "Authorization: Bearer $device" https://localhost:18443/client/v1/policy
ucode /src/scripts/openwrt/client-enrollment-http.uc disable
request 401 -H "Authorization: Bearer $device" https://localhost:18443/client/v1/policy
request 200 -H "Authorization: Bearer $device" "$poll"
ucode /src/scripts/openwrt/client-enrollment-http.uc enable
request 200 -H "Authorization: Bearer $device" "$poll"
request 401 -X POST -H "Authorization: Bearer $invite" -H "X-Device-Token: $other" "$claim"
ucode /src/scripts/openwrt/client-enrollment-http.uc expire
request 401 -H "Authorization: Bearer $device" "$poll"
printf '%s\n' 'client-enrollment-http: trusted TLS, one-device claim/retry, background credentials, protected storage, opening on registration, clock and expiry PASS'
