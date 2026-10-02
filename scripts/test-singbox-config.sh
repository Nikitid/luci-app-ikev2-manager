#!/bin/sh

# The FakeIP configuration was one heredoc with every value spliced in as text,
# and whether the running copy was current was a byte comparison. The document
# is now built by singbox-config.uc; these are the properties it must keep.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
generator="$root/ikev2-manager-runtime/lib/singbox-config.uc"
tmp="$(mktemp -d)"
finished=0
trap 'rm -rf "$tmp"; [ "$finished" = 1 ] || exit 1' EXIT
trap 'exit 1' INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

base() {
	printf '%s\t%s\n' \
		log_level warn ttl 60 cache_capacity 8192 cache_path /etc/cache.db \
		upstream_host 192.0.2.53 upstream_port 53 \
		bootstrap_host 8.8.8.8 bootstrap_port 53 \
		doh_host dns.example doh_port 443 doh_path /dns-query \
		fakeip_range 198.18.0.0/15 final_server upstream \
		dns_address 127.0.0.42 dns_port 5353 tproxy_address 127.0.0.1 \
		tproxy_port 7893 direct_tproxy_port 7894 router_tproxy_port 7895 \
		controller_address 127.0.0.1:9090 controller_secret s3cret \
		ruleset_path /var/run/rules.json
	printf 'covered\t192.168.1.0/24\ncovered\t10.20.30.0/24\n'
}
render() { ucode "$generator" render <"$1" >"$2"; }
# query FILE PYTHON-EXPRESSION over the parsed document "c"
query() {
	python3 -c 'import json, sys; c = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

base >"$tmp/in"
render "$tmp/in" "$tmp/out" || fail 'a valid input was refused'
[ "$(query "$tmp/out" 'c["route"]["rules"][4]["source_ip_cidr"]')" = "['192.168.1.0/24', '10.20.30.0/24']" ] ||
	fail 'covered networks did not reach the tunnel route rule'
[ "$(query "$tmp/out" '[s["tag"] for s in c["dns"]["servers"]]')" = "['upstream', 'ikev2-bootstrap', 'ikev2-upstream', 'fakeip']" ] ||
	fail 'the resolver list changed'
[ "$(query "$tmp/out" 'c["dns"]["servers"][1]["type"]')" = tcp ] ||
	fail 'the tunnel bootstrap is not TCP'
[ "$(query "$tmp/out" 'c["dns"]["rules"][3]["rewrite_ttl"] + c["dns"]["cache_capacity"]')" = 8252 ] ||
	fail 'numbers were not written as numbers'
[ "$(query "$tmp/out" 'len(c["dns"]["rules"])')" = 4 ] ||
	fail 'an HTTPS rule was added without segment suffixes'

# DNS segments: a resolver before FakeIP and a rule after the domain rules,
# both in the given order; HTTPS-compatible suffixes get their own rule.
{
	base
	printf 'https_suffix\tcorp.example\n'
	printf 'segment\tsegment-a\t5551\tcorp.example\tlan.example\n'
	printf 'segment\tsegment-b\t5552\thome.arpa\n'
} >"$tmp/in"
render "$tmp/in" "$tmp/out" || fail 'segments were refused'
[ "$(query "$tmp/out" '[s["tag"] for s in c["dns"]["servers"]][3:]')" = "['segment-a', 'segment-b', 'fakeip']" ] ||
	fail 'segment resolvers are not ahead of FakeIP'
[ "$(query "$tmp/out" '[(r.get("server"), r.get("domain_suffix")) for r in c["dns"]["rules"]][-2:]')" = \
	"[('segment-a', ['corp.example', 'lan.example']), ('segment-b', ['home.arpa'])]" ] ||
	fail 'segment rules are not last, in order'
[ "$(query "$tmp/out" 'c["dns"]["rules"][1]["domain_suffix"]')" = "['corp.example']" ] ||
	fail 'the HTTPS-compatible suffixes lost their rule'

# Browser compatibility for every ordinary name answers their HTTPS queries
# after the segments, which keep their own setting, and before the final
# resolver; without it no such rule exists.
{
	base
	printf 'segment\tsegment-a\t5551\tcorp.example\n'
	printf 'https_all\t1\n'
} >"$tmp/in"
render "$tmp/in" "$tmp/out" || fail 'compatibility for ordinary names was refused'
[ "$(query "$tmp/out" '[(r.get("server"), r.get("query_type"), r.get("rcode")) for r in c["dns"]["rules"]][-2:]')" = \
	"[('segment-a', None, None), (None, ['HTTPS'], 'NOERROR')]" ] ||
	fail 'compatibility for ordinary names is not the last rule, after the segments'
[ "$(query "$tmp/out" '"domain_suffix" in c["dns"]["rules"][-1] or "rule_set" in c["dns"]["rules"][-1]')" = False ] ||
	fail 'compatibility for ordinary names is limited to some names'

# Values are data: quoting in one cannot change the document around it.
{
	base | sed 's#^doh_path	.*#doh_path	/q"],"x":["#'
} >"$tmp/in"
render "$tmp/in" "$tmp/out" || fail 'an unusual path was refused'
[ "$(query "$tmp/out" 'c["dns"]["servers"][2]["path"]')" = '/q"],"x":["' ] ||
	fail 'a value was not kept as one string'
[ "$(query "$tmp/out" '"x" in c')" = False ] || fail 'a value injected a key'

# Missing or malformed values refuse the render instead of writing a guess.
for broken in 's#^upstream_port	.*#upstream_port	5x3#' 's#^dns_port	.*#dns_port	70000#' \
	's#^ttl	.*#ttl	-1#' '/^covered	/d' '/^controller_secret	/d'; do
	base | sed "$broken" >"$tmp/in"
	if render "$tmp/in" "$tmp/out" 2>/dev/null; then
		fail "a broken input was rendered: $broken"
	fi
done
{ base; printf 'segment\tsegment-a\t5551\n'; } >"$tmp/in"
if render "$tmp/in" "$tmp/out" 2>/dev/null; then
	fail 'a DNS segment without suffixes was rendered'
fi

# A configuration is current when its content matches, whatever its layout.
base >"$tmp/in"
render "$tmp/in" "$tmp/a.json"
python3 -c 'import json, sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"), sort_keys=True)' \
	"$tmp/a.json" "$tmp/b.json"
ucode "$generator" equal "$tmp/a.json" "$tmp/b.json" || fail 'a reformatted configuration was not current'
sed 's#"s3cret"#"other"#' "$tmp/b.json" >"$tmp/c.json"
if ucode "$generator" equal "$tmp/a.json" "$tmp/c.json"; then
	fail 'a changed value was current'
fi
python3 -c 'import json, sys; c = json.load(open(sys.argv[1])); c["route"]["rules"].reverse(); json.dump(c, open(sys.argv[2], "w"))' \
	"$tmp/a.json" "$tmp/d.json"
if ucode "$generator" equal "$tmp/a.json" "$tmp/d.json"; then
	fail 'reordered rules were current'
fi
printf '{' >"$tmp/e.json"
if ucode "$generator" equal "$tmp/a.json" "$tmp/e.json"; then
	fail 'an unreadable configuration was current'
fi

# The tunnel DNS probe worker: one DoH endpoint through the tunnel, nothing else.
printf '%s\t%s\n' bootstrap_host 8.8.8.8 bootstrap_port 53 doh_host dns.example \
	doh_port 443 doh_path /dns-query dns_address 127.0.0.77 >"$tmp/in"
ucode "$generator" probe <"$tmp/in" >"$tmp/probe.json" || fail 'the probe configuration was refused'
[ "$(query "$tmp/probe.json" '(c["dns"]["final"], c["inbounds"][0]["listen"], [s["bind_interface"] for s in c["dns"]["servers"]])')" = \
	"('probe', '127.0.0.77', ['ipsec-out', 'ipsec-out'])" ] || fail 'the probe does not resolve only through the tunnel'
sed '/^doh_port/d' "$tmp/in" >"$tmp/in2"
if ucode "$generator" probe <"$tmp/in2" >/dev/null 2>&1; then
	fail 'a probe without a port was rendered'
fi

# The router script feeds the generator; nothing writes the document by hand.
router="$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'singbox-config.uc" render' "$router" || fail 'the router does not use the generator'
grep -Fq 'singbox-config.uc" equal' "$router" || fail 'the current-configuration check compares bytes'
grep -Fq 'singbox-config.uc" probe' "$router" || fail 'the DNS probe writes its own configuration'
if grep -n '"clash_api"\|"hijack-dns"' "$router"; then
	fail 'the router still writes configuration JSON itself'
fi

finished=1
printf '%s\n' 'sing-box configuration tests OK'
