#!/bin/sh

# A boot-time start_action may run before WAN source-address selection is
# possible. Verify that recovery recognises only the resulting loopback-bound
# outbound IKE_SA and leaves legitimate handshakes untouched.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
# The LuCI backend's source is the script plus the libraries it sources.
manager_source="$tmp/manager-source.sh"
cat "$root/luci-ikev2-manager/ikev2-manager.sh" \
	"$root"/ikev2-manager-runtime/lib/manager-*.sh >"$manager_source"

# The detector itself is the SA reader's loopback-connecting answer, covered
# with its fixtures in test-sa-reader.sh; here it is read from a snapshot.
sed -n '/^has_loopback_connecting_outbound() {/,/^}/p' \
	"$manager_source" >"$tmp/detect.sh"
[ -s "$tmp/detect.sh" ] || {
	printf 'boot-stall detector is missing\n' >&2
	exit 1
}
sh -n "$tmp/detect.sh"
sa_helper="$root/ikev2-manager-runtime/ikev2-sa.sh"
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib"
IKEV2_SA_JSON="$tmp/sa.json"
export IKEV2_RUNTIME_LIB_DIR IKEV2_SA_JSON
. "$tmp/detect.sh"

must_match() {
	printf '{"errors":[],"data":[%s]}\n' "$1" >"$IKEV2_SA_JSON"
	has_loopback_connecting_outbound || {
		printf 'boot-stall fixture was not recognised: %s\n' "$1" >&2
		exit 1
	}
}

must_not_match() {
	printf '{"errors":[],"data":[%s]}\n' "$1" >"$IKEV2_SA_JSON"
	if has_loopback_connecting_outbound; then
		printf 'healthy/unrelated fixture was misclassified: %s\n' "$1" >&2
		exit 1
	fi
}

must_match '{"proxy-out":{"uniqueid":"2","state":"CONNECTING","local-host":"127.0.0.1","local-port":"500"}}'
must_match '{"proxy-out":{"uniqueid":"8","state":"CONNECTING","local-host":"::1","local-port":"500"}}'

must_not_match '{"proxy-out":{"uniqueid":"5","state":"CONNECTING","local-host":"198.51.100.48","local-port":"500"}}'
must_not_match '{"proxy-out":{"uniqueid":"5","state":"ESTABLISHED","local-host":"127.0.0.1","child-sas":{"proxy4-2":{"name":"proxy4","state":"INSTALLED"}}}}'
must_not_match '{"ikev2-in":{"uniqueid":"4","state":"CONNECTING","local-host":"127.0.0.1","local-port":"500"}}'
must_not_match '{"proxy-out":{"uniqueid":"9","state":"CONNECTING","local-host":"0.0.0.0","local-port":"500"}}'

# What recovery does, run against stubs: it waits for the peer to resolve,
# discards only a loopback-bound IKE_SA, and syncs the address of whatever
# comes up.
sed -n '/^ensure_first_tunnel() {/,/^}/p' "$manager_source" |
	sed "s#/usr/libexec/#$tmp/bin/#g" >"$tmp/ensure.sh"
[ -s "$tmp/ensure.sh" ] || {
	printf 'outbound recovery is missing\n' >&2
	exit 1
}
mkdir -p "$tmp/bin"
for helper in ikev2-sync-vips ikev2-routing; do
	printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"%s/calls"\n[ ! -e "%s/fail-%s" ]\n' \
		"$helper" "$tmp" "$tmp" "$helper" >"$tmp/bin/$helper"
	chmod 755 "$tmp/bin/$helper"
done
(
	root=''
	action_lock_dir="$tmp/action.lock"
	auto_connect_lock="$tmp/auto.lock"
	auto_connect_attempt="$tmp/auto.attempt"
	system_helper=true
	getv() { echo 1; }
	getv_default() { echo "$3"; }
	in_range() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
	logger() { :; }
	call() { printf '%s\n' "$*" >>"$tmp/calls"; }
	has_outbound_sa() { [ -e "$tmp/sa-up" ]; }
	has_loopback_connecting_outbound() { [ -e "$tmp/loopback" ]; }
	discard_stalled_attempt() { call discard-stalled "$@"; return 1; }
	outbound_peer_resolves() { [ -e "$tmp/resolves" ]; }
	swanctl_quiet() { call swanctl "$@"; }
	initiate_outbound() { call initiate; : >"$tmp/sa-up"; }
	. "$tmp/ensure.sh"
	run() {
		: >"$tmp/calls"
		rm -f "$auto_connect_attempt"
		( ensure_first_tunnel )
	}
	expect_calls() {
		grep -Fqx -- "$1" "$tmp/calls" || {
			printf '%s: missing call "%s" in:\n' "$2" "$1" >&2
			cat "$tmp/calls" >&2
			exit 1
		}
	}
	# Boot-time DNS not ready: nothing is initiated, the watcher retries.
	if run; then
		printf 'recovery reported success before the peer resolved\n' >&2
		exit 1
	fi
	! grep -q 'initiate\|swanctl' "$tmp/calls" || {
		printf 'recovery initiated before the peer resolved\n' >&2
		exit 1
	}
	: >"$tmp/resolves"
	# A loopback-bound IKE_SA is discarded; the replacement charon started meanwhile
	# is kept and its address synchronised.
	: >"$tmp/loopback"
	sh -c ': >"$1"' x "$tmp/sa-up.later"
	has_outbound_sa() { [ -e "$tmp/sa-up" ] || { [ -e "$tmp/sa-up.later" ] && grep -q terminate "$tmp/calls"; }; }
	run || {
		printf 'recovery from a loopback-bound IKE_SA failed\n' >&2
		exit 1
	}
	expect_calls 'swanctl --terminate --ike proxy-out --timeout 5' 'loopback recovery'
	expect_calls 'ikev2-sync-vips ' 'loopback recovery'
	! grep -q '^initiate' "$tmp/calls" || {
		printf 'recovery initiated a second IKE_SA beside its replacement\n' >&2
		exit 1
	}
	rm -f "$tmp/loopback" "$tmp/sa-up.later" "$tmp/sa-up"
	has_outbound_sa() { [ -e "$tmp/sa-up" ]; }
	# A plain outage: initiated, then its address and routes follow.
	run || {
		printf 'recovery from an outage failed\n' >&2
		exit 1
	}
	expect_calls initiate 'outage recovery'
	expect_calls 'discard-stalled proxy-out 1' 'outage recovery'
	expect_calls 'ikev2-sync-vips ' 'outage recovery'
	expect_calls 'ikev2-routing sync-all' 'outage recovery'
	# A tunnel that came up without its address is not reported recovered.
	rm -f "$tmp/sa-up"
	: >"$tmp/fail-ikev2-sync-vips"
	if run; then
		printf 'recovery without the tunnel address was reported done\n' >&2
		exit 1
	fi
	rm -f "$tmp/fail-ikev2-sync-vips"
	# A healthy tunnel is left alone.
	run && [ ! -s "$tmp/calls" ] || {
		printf 'recovery touched a healthy tunnel\n' >&2
		exit 1
	}
)

# An attempt that does not finish: noted when first seen, left alone while it
# may still be a slow handshake, discarded by its own id once it has had its
# time, and forgotten when another attempt took its place.
(
	sed -n '/^stalled_attempt_seconds=/p; /^discard_stalled_attempt() {/,/^}/p' "$manager_source" >"$tmp/stalled.sh"
	[ "$(grep -c . "$tmp/stalled.sh")" -gt 5 ] || { printf 'stalled-attempt recovery is missing\n' >&2; exit 1; }
	tunnel_attempt_dir="$tmp/attempts"
	sa_helper="$tmp/bin/sa"
	printf '#!/bin/sh\n[ "$1 $2" = "connecting proxy-out-2" ] && cat "%s/connecting" 2>/dev/null\n' "$tmp" >"$sa_helper"
	chmod 755 "$sa_helper"
	clock=1000
	date() { echo "$clock"; }
	logger() { :; }
	swanctl() { printf 'swanctl %s\n' "$*" >>"$tmp/stalled.calls"; }
	. "$tmp/stalled.sh"
	: >"$tmp/stalled.calls"
	never() { if discard_stalled_attempt proxy-out-2 2; then printf '%s\n' "$1" >&2; exit 1; fi; }
	never 'nothing connecting was treated as stalled'
	echo 7 >"$tmp/connecting"
	never 'an attempt was discarded the moment it was seen'
	clock=1029
	never 'an attempt was discarded before it had its time'
	echo 9 >"$tmp/connecting"
	clock=1035
	never 'a new attempt inherited the age of the one before it'
	clock=1064
	never 'the new attempt was discarded early'
	clock=1065
	discard_stalled_attempt proxy-out-2 2 || { printf 'an attempt without an answer was left to retransmit\n' >&2; exit 1; }
	[ "$(cat "$tmp/stalled.calls")" = 'swanctl --terminate --ike-id 9 --timeout 5' ] || {
		printf 'the stalled attempt was not ended by its own id: %s\n' "$(cat "$tmp/stalled.calls")" >&2; exit 1; }
	[ ! -e "$tmp/attempts/2.connecting" ] || { printf 'a discarded attempt is still remembered\n' >&2; exit 1; }
	echo 'x; reboot' >"$tmp/connecting"
	never 'an id that is not a number was acted on'
	: >"$tmp/connecting"
	never 'an established tunnel was treated as stalled'
) || exit 1

grep -Fq 'STOP=02' "$root/ikev2-manager-runtime/ikev2-health.init" || {
	printf 'health watcher does not stop before dependent services\n' >&2
	exit 1
}
grep -Fq 'procd_set_param term_timeout 5' \
	"$root/ikev2-manager-runtime/ikev2-health.init" || {
	printf 'health watcher shutdown is not explicitly bounded\n' >&2
	exit 1
}

printf 'boot recovery and shutdown-bound tests OK\n'
