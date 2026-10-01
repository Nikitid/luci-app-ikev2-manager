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

ensure_body="$(sed -n '/^ensure_client_action() {/,/^}/p' \
	"$manager_source")"
printf '%s\n' "$ensure_body" | grep -Fq 'outbound_peer_resolves || return 1' || {
	printf 'recovery no longer waits for boot-time DNS\n' >&2
	exit 1
}
printf '%s\n' "$ensure_body" | grep -Fq 'if has_loopback_connecting_outbound; then' || {
	printf 'ensure-client does not use the boot-stall detector\n' >&2
	exit 1
}
printf '%s\n' "$ensure_body" | grep -Fq 'swanctl_quiet --terminate --ike proxy-out --timeout 5' || {
	printf 'ensure-client does not discard the stalled outbound IKE_SA\n' >&2
	exit 1
}
printf '%s\n' "$ensure_body" | grep -Fq '/usr/libexec/ikev2-sync-vips || return 1' || {
	printf 'an automatic replacement would not synchronise its virtual IP\n' >&2
	exit 1
}

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
