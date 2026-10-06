#!/bin/sh
# Dedicated TLS-only client API. No LuCI, CGI or ubus application is attached.
set -u
umask 077
ulimit -c 0
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset TMPDIR
for ikev2_override in $(env | sed -n 's/^\(IKEV2_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$ikev2_override"; done
[ "$#" = 1 ] && [ "$1" = serve ] || exit 2
work="$(mktemp -d /var/run/ikev2-client-api.XXXXXX)" || exit 1
server_pid=''
cleanup() {
 [ -z "$server_pid" ] || { kill "$server_pid" 2>/dev/null || :; wait "$server_pid" 2>/dev/null || :; }
 rm -rf "$work"
}
refuse() { cleanup; printf '%s\n' 'Client HTTPS API configuration refused.' >&2; exit 1; }
trap 'cleanup; exit 0' HUP INT TERM
/usr/bin/ucode /usr/libexec/ikev2-manager.d/client-api-settings.uc >"$work/settings" 2>/dev/null || refuse
identity="$(jsonfilter -i "$work/settings" -e '@.identity')" || refuse
port="$(jsonfilter -i "$work/settings" -e '@.port')" || refuse
cert="$(jsonfilter -i "$work/settings" -e '@.certificate')" || refuse
key="$(jsonfilter -i "$work/settings" -e '@.private_key')" || refuse
cp "$cert" "$work/certificate.pem" && cp "$key" "$work/key.pem" || refuse
chmod 600 "$work/certificate.pem" "$work/key.pem" || refuse
openssl verify -purpose sslserver -partial_chain -trusted "$work/certificate.pem" -verify_hostname "$identity" "$work/certificate.pem" >/dev/null 2>&1 || refuse
openssl x509 -in "$work/certificate.pem" -pubkey -noout 2>/dev/null |
 openssl pkey -pubin -outform DER >"$work/certificate.pub" 2>/dev/null || refuse
openssl pkey -in "$work/key.pem" -passin pass: -pubout -outform DER >"$work/key.pub" 2>/dev/null || refuse
cmp -s "$work/certificate.pub" "$work/key.pub" || refuse
mkdir "$work/www" || refuse
/usr/sbin/uhttpd -f -h "$work/www" -D -S -s "0.0.0.0:$port" -s "[::]:$port" \
 -C "$work/certificate.pem" -K "$work/key.pem" -n 4 -N 8 -t 5 -T 5 -k 0 \
 -o /client/v1 -O /usr/libexec/ikev2-manager.d/client-access-http.uc >/dev/null 2>&1 &
server_pid=$!
wait "$server_pid"
rc=$?
server_pid=''
cleanup
exit "$rc"
