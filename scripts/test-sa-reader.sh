#!/bin/sh

# SA state was read by matching the `swanctl --raw` text: an outbound check
# that accepted a proxy4 CHILD_SA of any connection, and an inbound session
# parser that cut the listing into segments by pattern. The reader takes the
# swanmon JSON by key instead; these are the answers it must give.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
helper="$root/ikev2-manager-runtime/ikev2-sa.sh"
tmp="$(mktemp -d)"
finished=0
trap 'rm -rf "$tmp"; [ "$finished" = 1 ] || exit 1' EXIT
trap 'exit 1' INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib"
IKEV2_SA_JSON="$tmp/sa.json"
export IKEV2_RUNTIME_LIB_DIR IKEV2_SA_JSON

snapshot() { printf '{"errors":[],"data":[%s]}\n' "$1" >"$tmp/sa.json"; }
answers() { "$helper" "$@" 2>/dev/null; }
status() {
	local rc=0
	"$helper" "$@" >/dev/null 2>&1 || rc=$?
	printf '%s\n' "$rc"
}

# The outbound CHILD_SA counts only under this application's connection and
# only once installed.
snapshot '{"site-link":{"state":"ESTABLISHED","child-sas":{"proxy4-3":{"name":"proxy4","state":"INSTALLED"}}}}'
[ "$(status installed proxy-out proxy4)" = 1 ] || fail "another connection's proxy4 counted as ours"
snapshot '{"proxy-out":{"state":"ESTABLISHED","child-sas":{"proxy4-4":{"name":"proxy4","state":"REKEYING"}}}}'
[ "$(status installed proxy-out proxy4)" = 1 ] || fail 'a CHILD_SA that is not installed counted'
snapshot '{"proxy-out":{"state":"ESTABLISHED","child-sas":{"other-1":{"name":"other","state":"INSTALLED"},"proxy4-5":{"name":"proxy4","state":"INSTALLED"}}}}'
[ "$(status installed proxy-out proxy4)" = 0 ] || fail 'the installed outbound CHILD_SA was missed'
[ "$(status present proxy-out)" = 0 ] || fail 'the outbound IKE_SA was missed'
[ "$(status present ikev2-in)" = 1 ] || fail 'an absent connection was reported present'

# Virtual addresses: every one of ours, none of another connection's.
snapshot '{"proxy-out":{"local-vips":["10.20.20.10","fd00::10"]}},{"site-link":{"local-vips":["10.253.44.2"]}}'
[ "$(answers local-vips proxy-out | tr '\n' ' ')" = '10.20.20.10 fd00::10 ' ] ||
	fail "our virtual addresses were not listed: $(answers local-vips proxy-out)"
[ "$(status local-vips ikev2-in)" = 1 ] || fail 'a connection without addresses listed some'

# Inbound sessions: each EAP client of the server, in order, and nothing else.
snapshot '{"ikev2-in":{"remote-eap-id":"alice","remote-vips":["10.20.30.15"]}},{"site-link-in":{"remote-eap-id":"office","remote-vips":["10.253.44.2"]}},{"ikev2-in":{"remote-id":"no-eap","remote-vips":["10.20.30.16"]}},{"ikev2-in":{"remote-eap-id":"bob","remote-vips":["10.20.30.17","10.20.30.18"]}},{"ikev2-in":{"remote-eap-id":"carol"}},{"ikev2-in":{"remote-eap-id":"x\ty","remote-vips":["10.20.30.19"]}}'
printf 'alice\t10.20.30.15\nbob\t10.20.30.17\n' >"$tmp/expected"
answers sessions ikev2-in >"$tmp/sessions"
cmp -s "$tmp/expected" "$tmp/sessions" || {
	cat "$tmp/sessions" >&2
	fail 'inbound sessions were not read by key'
}
# The IKE SAs of one user, to end them when it is removed: every one of its,
# under the server only, and no other user's.
snapshot '{"ikev2-in":{"uniqueid":"20","remote-eap-id":"alice"}},{"ikev2-in":{"uniqueid":"21","remote-eap-id":"bob"}},{"site-link-in":{"uniqueid":"23","remote-eap-id":"alice"}},{"ikev2-in":{"uniqueid":"22","remote-eap-id":"alice"}},{"ikev2-in":{"uniqueid":"x; reboot","remote-eap-id":"alice"}}'
[ "$(answers session-ids ikev2-in alice | tr '\n' ' ')" = '20 22 ' ] ||
	fail "a user's sessions were not found by identity: $(answers session-ids ikev2-in alice)"
[ "$(status session-ids ikev2-in)" = 2 ] || fail 'a session lookup without an identity was accepted'
snapshot ''
[ "$(status sessions ikev2-in)" = 0 ] || fail 'no sessions was an error'
[ -z "$(answers sessions ikev2-in)" ] || fail 'sessions were invented from an empty listing'

# The boot-stalled outbound SA: CONNECTING from a loopback address only.
snapshot '{"proxy-out":{"state":"CONNECTING","local-host":"127.0.0.1"}}'
[ "$(status loopback-connecting proxy-out)" = 0 ] || fail 'a loopback-bound CONNECTING SA was missed'
snapshot '{"proxy-out":{"state":"CONNECTING","local-host":"::1"}}'
[ "$(status loopback-connecting proxy-out)" = 0 ] || fail 'an IPv6 loopback-bound SA was missed'
snapshot '{"proxy-out":{"state":"CONNECTING","local-host":"192.0.2.7"}}'
[ "$(status loopback-connecting proxy-out)" = 1 ] || fail 'a slow SA with a real address would be torn down'
snapshot '{"proxy-out":{"state":"ESTABLISHED","local-host":"127.0.0.1"}}'
[ "$(status loopback-connecting proxy-out)" = 1 ] || fail 'an established SA was treated as stalled'

# A snapshot that cannot be read is an error, never an empty SA list: the
# inbound policy would otherwise revoke every connected client.
printf '{"errors":["connecting to charon failed"],"data":[]}\n' >"$tmp/sa.json"
[ "$(status sessions ikev2-in)" = 2 ] || fail 'a swanmon error was read as no sessions'
printf '{"errors":[],"data":[{"ikev2-in":{' >"$tmp/sa.json"
[ "$(status sessions ikev2-in)" = 2 ] || fail 'a truncated snapshot was read as no sessions'
: >"$tmp/sa.json"
[ "$(status sessions ikev2-in)" = 2 ] || fail 'an empty snapshot was read as no sessions'
printf '{"errors":[]}\n' >"$tmp/sa.json"
[ "$(status sessions ikev2-in)" = 2 ] || fail 'a snapshot without data was read as no sessions'
[ "$(status frobnicate ikev2-in)" = 2 ] || fail 'an unknown command succeeded'

# swanmon itself: a failed or hanging query is bounded and reported.
unset IKEV2_SA_JSON
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/swanmon-fail"
printf '#!/bin/sh\nexec sleep 30\n' >"$tmp/bin/swanmon-hang"
chmod 755 "$tmp/bin/"*
[ "$(IKEV2_SWANMON="$tmp/bin/swanmon-fail" status present proxy-out)" = 2 ] ||
	fail 'a failed swanmon query was not reported'
started="$(date +%s)"
[ "$(IKEV2_SWANMON="$tmp/bin/swanmon-hang" IKEV2_SA_TIMEOUT=1 status present proxy-out)" = 2 ] ||
	fail 'a hanging swanmon query was not reported'
[ $(( $(date +%s) - started )) -lt 10 ] || fail 'a hanging swanmon query stalled the caller'

# Nothing in the runtime reads the text listing any more.
if grep -n -- '--list-sas' "$root"/ikev2-manager-runtime/*.sh "$root"/ikev2-manager-runtime/pbr.user.ikev2out \
	"$root"/luci-ikev2-manager/ikev2-manager.sh; then
	fail 'a runtime script still parses the swanctl SA listing'
fi

finished=1
printf '%s\n' 'SA reader tests OK'
