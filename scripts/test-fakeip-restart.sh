#!/bin/sh

# A FakeIP refresh that failed put the previous configuration back and restarted
# the service, and the init script rendered the failed one again on that very
# restart: "previous rules restored" while the new, failing rules ran. A start
# must run what was last validated. Because a start no longer re-renders, a rule
# refresh must notice when the configuration itself has to change.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
router="$root/ikev2-manager-runtime/ikev2-domain-router.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

extract() {
	awk -v name="$1" '
		index($0, name "() {") == 1 { body = 1; close_with = "}" }
		index($0, name "() (") == 1 { body = 1; close_with = ")" }
		body { print }
		body && $0 == close_with { exit }
	' "$router"
}
for name in prepare config_matches_rendered refresh_rules; do
	extract "$name" >>"$tmp/functions.sh"
	grep -q "^$name() " "$tmp/functions.sh" || fail "function is missing: $name"
done

mkdir -p "$tmp/bin"
cat >"$tmp/bin/sing-box" <<'EOF'
#!/bin/sh
[ -e "$STUB_DIR/config-valid" ]
EOF
chmod +x "$tmp/bin/sing-box"
STUB_DIR="$tmp"
PATH="$tmp/bin:$PATH"
export STUB_DIR PATH

config_file="$tmp/domain-router.json"
ucode_bin=ucode
runtime_lib_dir="$root/ikev2-manager-runtime/lib"
ruleset_file="$tmp/rules.json"
bypass_ruleset_file="$tmp/bypass.json"
bypass_domain_file="$tmp/bypass.txt"
init_config() { :; }
foreign_servers_file() { return 1; }
defaultv() { printf "%s\n" fakeip; }
check_config() { printf 'render\n' >>"$tmp/calls"; printf 'rendered\n' >"$config_file"; }
nft_start() { printf 'nft\n' >>"$tmp/calls"; }
refresh() { printf 'refresh\n' >>"$tmp/calls"; }
runtime_healthy() { :; }
write_status() { printf '%s:%s\n' "$1" "${2:-}" >"$tmp/status"; }
render_ruleset() { cp "$tmp/next-rules" "$ruleset_file"; }
render_config() { render_ruleset; cp "$tmp/next-config" "$config_file"; }
. "$tmp/functions.sh"

# A validated configuration is started as it is.
printf 'restored\n' >"$config_file"
printf 'rules\n' >"$ruleset_file"
touch "$tmp/config-valid"
: >"$tmp/calls"
prepare || fail 'prepare failed'
[ "$(cat "$tmp/calls")" = nft ] || fail "a validated configuration was rendered again: $(cat "$tmp/calls")"
[ "$(cat "$config_file")" = restored ] || fail 'the restored configuration was replaced on start'

# A missing or invalid one is rendered.
rm -f "$tmp/config-valid"
: >"$tmp/calls"
prepare || fail 'prepare failed on an invalid configuration'
[ "$(tr '\n' ' ' <"$tmp/calls")" = 'render nft ' ] || fail 'an invalid configuration was not rendered'
rm -f "$config_file"
: >"$tmp/calls"
prepare || fail 'prepare failed without a configuration'
grep -qx render "$tmp/calls" || fail 'a missing configuration was not rendered'

# A rule edit that leaves the configuration alone stays a rule reload.
# Compared by content: the live copy's layout differs from a fresh render.
printf '{"a": "same", "b": [1, 2]}\n' >"$config_file"
printf '{"b":[1,2],"a":"same"}\n' >"$tmp/next-config"
printf 'rules\n' >"$ruleset_file"
printf 'rules\n' >"$tmp/next-rules"
: >"$tmp/calls"
refresh_rules || fail 'an unchanged rule refresh failed'
grep -qx refresh "$tmp/calls" && fail 'an unchanged configuration was fully refreshed'
[ "$(cat "$ruleset_file")" = rules ] || fail 'the live rule-set was replaced while only asking'

# One that changes the configuration - a device routed by domain is a covered
# source written into it - is a full refresh.
printf '{"a": "with device", "b": [1, 2]}\n' >"$tmp/next-config"
: >"$tmp/calls"
refresh_rules || fail 'a changed rule refresh failed'
grep -qx refresh "$tmp/calls" || fail 'a configuration change was treated as a rule reload'
[ "$(cat "$config_file")" = '{"a": "same", "b": [1, 2]}' ] || fail 'asking whether the configuration changed modified it'

grep -q '^	if ! /usr/libexec/ikev2-domain-router prepare; then$' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.init" ||
	fail 'the service start no longer goes through prepare'
grep -q 'ruleset_path "${ruleset_ref:-$ruleset_file}"' "$router" ||
	fail 'the rendered rule-set path cannot be pointed at the live file'

printf '%s\n' 'FakeIP restart tests OK'
