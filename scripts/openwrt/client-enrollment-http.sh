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
# One link for two devices of one person: two places, each used once, both
# described as that person's, and nothing left for a third device.
control=/usr/libexec/ikev2-manager.d/client-access-control.uc
shown="$(ucode "$control" inspect)"
address="$(printf '%s' "$shown" | jsonfilter -e '@.server.address')"
service=api
generation="$(printf '%s' "$shown" | jsonfilter -e '@.enrollment_generation')"
link="$(printf '{"version":1,"expected_generation":%s,"endpoint":"https://%s:18443/client/v1/enroll","id":"family","selected_services":["%s"],"lifetime_seconds":86400,"count":2,"owner":"One Person","note":""}' \
	"$generation" "$address" "$service" | ucode /usr/libexec/ikev2-manager.d/client-access-invitation-control.uc issue | jsonfilter -e '@.invitation')"
shared="${link##*#}"
[ "${#shared}" = 64 ]
[ "$(ucode "$control" inspect | jsonfilter -e '@.waiting[@.owner="One Person"].id' | sort | tr '\n' ' ')" = 'family-1 family-2 ' ]
for place in 1111111111111111111111111111111111111111111111111111111111111111 2222222222222222222222222222222222222222222222222222222222222222; do
	request 202 -X POST -H "Authorization: Bearer $shared" -H "X-Device-Token: $place" "$claim"
	i=0
	while :; do
		status="$(curl --cacert "$work/cert.pem" --max-time 5 -o "$work/body" -w '%{http_code}' -H "Authorization: Bearer $place" "$poll")"
		[ "$status" = 200 ] && break
		[ "$status" = 202 ] || exit 1
		i=$((i + 1)); [ "$i" -lt 30 ] || exit 1
		sleep 1
	done
done
request 401 -X POST -H "Authorization: Bearer $shared" -H "X-Device-Token: 3333333333333333333333333333333333333333333333333333333333333333" "$claim"
shown="$(ucode "$control" inspect)"
[ "$(printf '%s' "$shown" | jsonfilter -e '@.devices[@.owner="One Person"].id' | sort | tr '\n' ' ')" = 'family-1 family-2 ' ]
[ -z "$(printf '%s' "$shown" | jsonfilter -e '@.waiting[@.owner="One Person"].id')" ]
# A lost link is replaced: the place it still held is closed and the old link
# registers nobody, the new one does.
generation="$(ucode "$control" inspect | jsonfilter -e '@.enrollment_generation')"
lost="$(printf '{"version":1,"expected_generation":%s,"endpoint":"https://%s:18443/client/v1/enroll","id":"spare","selected_services":["%s"],"lifetime_seconds":3600,"owner":"One Person","note":""}' \
	"$generation" "$address" "$service" | ucode /usr/libexec/ikev2-manager.d/client-access-invitation-control.uc issue | jsonfilter -e '@.invitation')"
generation="$(ucode "$control" inspect | jsonfilter -e '@.enrollment_generation')"
fresh="$(printf '{"version":1,"expected_generation":%s,"endpoint":"https://%s:18443/client/v1/enroll","id":"spare-2","selected_services":["%s"],"lifetime_seconds":3600,"cancel":["spare"],"owner":"One Person","note":""}' \
	"$generation" "$address" "$service" | ucode /usr/libexec/ikev2-manager.d/client-access-invitation-control.uc issue | jsonfilter -e '@.invitation')"
[ "$(ucode "$control" inspect | jsonfilter -e '@.waiting[*].id' | tr '\n' ' ')" = 'spare-2 ' ]
request 401 -X POST -H "Authorization: Bearer ${lost##*#}" -H "X-Device-Token: 4444444444444444444444444444444444444444444444444444444444444444" "$claim"
request 202 -X POST -H "Authorization: Bearer ${fresh##*#}" -H "X-Device-Token: 4444444444444444444444444444444444444444444444444444444444444444" "$claim"
# The ledger takes one registration at a time; let this one finish.
i=0
while :; do
	status="$(curl --cacert "$work/cert.pem" --max-time 5 -o "$work/body" -w '%{http_code}' -H "Authorization: Bearer 4444444444444444444444444444444444444444444444444444444444444444" "$poll")"
	[ "$status" = 200 ] && break
	[ "$status" = 202 ] || exit 1
	i=$((i + 1)); [ "$i" -lt 30 ] || exit 1
	sleep 1
done
# A free place can be closed without touching registered devices.
generation="$(ucode "$control" inspect | jsonfilter -e '@.enrollment_generation')"
printf '{"version":1,"expected_generation":%s,"endpoint":"https://%s:18443/client/v1/enroll","id":"extra","selected_services":["%s"],"lifetime_seconds":3600,"owner":"One Person","note":""}' \
	"$generation" "$address" "$service" | ucode /usr/libexec/ikev2-manager.d/client-access-invitation-control.uc issue >/dev/null
ucode "$control" inspect | jsonfilter -e '@.waiting[*].id' | grep -qx extra
printf '{"version":1,"expected_generation":%s,"operation":"close-place","payload":{"id":"extra"}}' "$(ucode "$control" inspect | jsonfilter -e '@.generation')" | ucode "$control" update >/dev/null
! ucode "$control" inspect | jsonfilter -e '@.waiting[*].id' | grep -qx extra
# One decision for all of a person's devices.
shown="$(ucode "$control" inspect)"
printf '{"version":1,"expected_generation":%s,"operation":"assign-devices","payload":{"ids":["family-1","family-2"],"enabled":false,"selected_services":["%s"],"owner":"One Person","note":"both"}}' \
	"$(printf '%s' "$shown" | jsonfilter -e '@.generation')" "$service" | ucode "$control" update >/dev/null
shown="$(ucode "$control" inspect)"
[ "$(printf '%s' "$shown" | jsonfilter -e '@.devices[@.note="both"].enabled' | sort -u)" = false ]
# The administrator may let a person's services go the ordinary way while the
# tunnel is down; the device is told, and told the rule when nothing was said.
first=1111111111111111111111111111111111111111111111111111111111111111
printf '{"version":1,"expected_generation":%s,"operation":"assign-devices","payload":{"ids":["family-1","family-2"],"enabled":true,"selected_services":["%s"],"owner":"One Person","note":"both"}}' \
	"$(printf '%s' "$shown" | jsonfilter -e '@.generation')" "$service" | ucode "$control" update >/dev/null
request 200 -H "Authorization: Bearer $first" https://localhost:18443/client/v1/services
[ "$(jsonfilter -i "$work/body" -e '@.block_without_tunnel')" = true ]
printf '{"version":1,"expected_generation":%s,"operation":"assign-devices","payload":{"ids":["family-1","family-2"],"enabled":true,"selected_services":["%s"],"owner":"One Person","note":"both","email":"one@example.com","block_without_tunnel":false}}' \
	"$(ucode "$control" inspect | jsonfilter -e '@.generation')" "$service" | ucode "$control" update >/dev/null
request 200 -H "Authorization: Bearer $first" https://localhost:18443/client/v1/services
[ "$(jsonfilter -i "$work/body" -e '@.block_without_tunnel')" = false ]
[ "$(ucode "$control" inspect | jsonfilter -e '@.devices[@.id="family-2"].email')" = one@example.com ]
# Everything into the tunnel: the device is told, and its account gets the
# rights of a VPN user; back to services alone, it has none again.
rights() { uci -q show ikev2-manager | sed -n "s/^ikev2-manager\.\(user_[a-f0-9]*\)\.username='family-1'$/\1/p" | while read -r section; do uci -q get "ikev2-manager.$section.internet_access"; done; }
[ "$(rights)" = deny ]
printf '{"version":1,"expected_generation":%s,"operation":"assign-devices","payload":{"ids":["family-1","family-2"],"enabled":true,"selected_services":["%s"],"owner":"One Person","note":"both","mode":"full"}}' \
	"$(ucode "$control" inspect | jsonfilter -e '@.generation')" "$service" | ucode "$control" update >/dev/null
request 200 -H "Authorization: Bearer $first" https://localhost:18443/client/v1/services
[ "$(jsonfilter -i "$work/body" -e '@.mode')" = full ]
[ "$(rights)" = inherit ]
printf '{"version":1,"expected_generation":%s,"operation":"assign-devices","payload":{"ids":["family-1","family-2"],"enabled":true,"selected_services":["%s"],"owner":"One Person","note":"both","mode":"services"}}' \
	"$(ucode "$control" inspect | jsonfilter -e '@.generation')" "$service" | ucode "$control" update >/dev/null
[ "$(rights)" = deny ]
printf '%s\n' 'client-enrollment-http: trusted TLS, one-device claim/retry, one link for two devices, a replaced link, a closed place, a shared decision, the full-tunnel mode, background credentials, protected storage, opening on registration, clock and expiry PASS'
