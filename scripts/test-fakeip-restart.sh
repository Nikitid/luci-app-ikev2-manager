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
for name in prepare config_matches_rendered refresh_rules added_rule_domain exit_rules_file exit_ruleset; do
	extract "$name" >>"$tmp/functions.sh"
	grep -q "^$name() " "$tmp/functions.sh" || fail "function is missing: $name"
done

mkdir -p "$tmp/bin"
cat >"$tmp/bin/sing-box" <<'EOF'
#!/bin/sh
[ -e "$STUB_DIR/config-valid" ]
EOF
# The domains of a rule set, one a line, as jsonfilter prints them.
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
[ "$1" = -i ] && [ -r "$2" ] || exit 1
sed -n 's/.*"domain_suffix":\[\([^]]*\)\].*/\1/p' "$2" | tr ',' '\n' | tr -d '"' | grep .
EOF
chmod +x "$tmp/bin/sing-box" "$tmp/bin/jsonfilter"
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
render_ruleset() {
	cp "$tmp/next-rules" "$ruleset_file"
	if [ -e "$tmp/next-rules-2" ]; then
		cp "$tmp/next-rules-2" "${ruleset_file%.json}.exit-2.json"
	else
		rm -f "${ruleset_file%.json}.exit-2.json"
	fi
}
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

# Only the second exit's names changed: sing-box rereads that rule set by
# itself, and dnsmasq is told only once a name it added gets a FakeIP address,
# or it would cache the real one and send it past the tunnel.
printf '{"b":[1,2],"a":"same"}\n' >"$tmp/next-config"
printf '{"version":3,"rules":[{"domain_suffix":["one.example"]}]}\n' >"$tmp/next-rules"
cp "$tmp/next-rules" "$ruleset_file"
printf '{"version":3,"rules":[{"domain_suffix":["two.example"]}]}\n' >"${ruleset_file%.json}.exit-2.json"
printf '{"version":3,"rules":[{"domain_suffix":["two.example","new.example"]}]}\n' >"$tmp/next-rules-2"
dns_address=127.0.0.42
servers_changed=0
sleep() { :; }
validate_dns_server() { :; }
lookup_address() {
	printf '%s %s\n' "$1" "$2" >>"$tmp/lookups"
	if [ "$(grep -c "^new.example 127.0.0.42" "$tmp/lookups")" -ge 3 ]; then echo 198.18.0.9; else echo 203.0.113.9; fi
}
is_fakeip() { case "$1" in 198.18.*) return 0 ;; *) return 1 ;; esac; }
write_dnsmasq_servers() { printf 'servers after %s lookups\n' "$(wc -l <"$tmp/lookups" | tr -d ' ')" >>"$tmp/calls"; }
: >"$tmp/calls"
: >"$tmp/lookups"
refresh_rules || fail 'a change of the second exit names failed'
grep -qx 'servers after 3 lookups' "$tmp/calls" ||
	fail "dnsmasq was told before the new name of the second exit had FakeIP: $(cat "$tmp/calls")"
! grep -qx refresh "$tmp/calls" || fail 'a change of the second exit names restarted the resolver'
grep -q 'without restarting DNS' "$tmp/status" || fail 'the reload was not reported'
# When the name never gets FakeIP the rule sets go back and the resolver is
# restarted the transactional way.
printf '{"version":3,"rules":[{"domain_suffix":["two.example","new.example","late.example"]}]}\n' >"$tmp/next-rules-2"
cp "${ruleset_file%.json}.exit-2.json" "$tmp/before-2"
lookup_address() { echo 203.0.113.9; }
: >"$tmp/calls"
refresh_rules || :
cmp -s "$tmp/before-2" "${ruleset_file%.json}.exit-2.json" ||
	fail 'a failed reload of the second exit names was not rolled back'
grep -qx refresh "$tmp/calls" || fail 'a failed reload did not fall back to the full refresh'
! grep -q '^servers' "$tmp/calls" || fail 'dnsmasq was told of names sing-box never took'
rm -f "$tmp/next-rules-2" "${ruleset_file%.json}.exit-2.json"

grep -q '^	if ! /usr/libexec/ikev2-domain-router prepare; then$' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.init" ||
	fail 'the service start no longer goes through prepare'
grep -q 'ruleset_path "${ruleset_ref:-$ruleset_file}"' "$router" ||
	fail 'the rendered rule-set path cannot be pointed at the live file'

printf '%s\n' 'FakeIP restart tests OK'
