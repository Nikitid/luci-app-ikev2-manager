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

# Domains never to go through the tunnel resolve for real over WAN before any
# FakeIP rule, and a connection sniffed to one leaves directly even from a
# full-route device; without the list, nothing of it appears.
{
	base
	printf 'bypass_ruleset_path\t/etc/bypass.json\n'
} >"$tmp/in"
render "$tmp/in" "$tmp/out" || fail 'the bypass list was refused'
[ "$(query "$tmp/out" 'c["dns"]["rules"][0]')" = "{'rule_set': ['ikev2-bypass'], 'action': 'route', 'server': 'upstream'}" ] ||
	fail 'excluded domains are not resolved for real ahead of FakeIP'
[ "$(query "$tmp/out" '[r.get("outbound") for r in c["route"]["rules"] if r.get("rule_set") == ["ikev2-bypass"]]')" = "['direct-out']" ] ||
	fail 'a connection to an excluded domain is not sent direct'
[ "$(query "$tmp/out" '[i for i, r in enumerate(c["route"]["rules"]) if r.get("rule_set") == ["ikev2-bypass"]][0] < [i for i, r in enumerate(c["route"]["rules"]) if r.get("inbound") == ["tproxy-router-in"]][0]')" = True ] ||
	fail 'the full-route path is decided before the exclusions'
[ "$(query "$tmp/out" '[r["path"] for r in c["route"]["rule_set"] if r["tag"] == "ikev2-bypass"]')" = "['/etc/bypass.json']" ] ||
	fail 'the bypass rule-set is not loaded from its file'
base >"$tmp/in"
render "$tmp/in" "$tmp/out"
[ "$(query "$tmp/out" '"ikev2-bypass" in str(c)')" = False ] || fail 'an empty bypass list left rules behind'

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

# Several tunnels: each its own outbound and resolvers on its own link, so a
# name resolves through the tunnel that carries the connection; each exit a
# selector over its tunnels, starting on its first whatever the watcher chose;
# the first exit carries the selected domains and the router's own traffic.
{
	base | sed 's/^final_server\tupstream$/final_server\tikev2-upstream/'
	printf 'tunnel\t1\tipsec-out\ntunnel\t2\tipsec-out2\n'
	printf 'exit\t1\t1\t2\nexit\t2\t2\t1\n'
} >"$tmp/in"
render "$tmp/in" "$tmp/multi.json" || fail 'two tunnels were refused'
[ "$(query "$tmp/multi.json" '[(s["tag"], s.get("bind_interface"), s.get("detour")) for s in c["dns"]["servers"] if s["tag"] not in ("upstream", "fakeip")]')" = \
	"[('ikev2-bootstrap', 'ipsec-out', None), ('ikev2-upstream', 'ipsec-out', None), ('ikev2-bootstrap-2', 'ipsec-out2', None), ('ikev2-upstream-2', 'ipsec-out2', None), ('exit-1-bootstrap', None, 'exit-1'), ('exit-1-dns', None, 'exit-1')]" ] ||
	fail "the tunnel resolvers are not one pair per link: $(query "$tmp/multi.json" '[s["tag"] for s in c["dns"]["servers"]]')"
[ "$(query "$tmp/multi.json" '[(o["tag"], o.get("bind_interface"), o.get("domain_resolver", {}).get("server") if isinstance(o.get("domain_resolver"), dict) else None) for o in c["outbounds"] if o["type"] == "direct" and o["tag"] != "direct-out"]')" = \
	"[('ikev2-out', 'ipsec-out', 'ikev2-upstream'), ('ikev2-out-2', 'ipsec-out2', 'ikev2-upstream-2')]" ] ||
	fail 'a tunnel outbound does not resolve through its own tunnel'
[ "$(query "$tmp/multi.json" '[(o["tag"], o["outbounds"], o["default"], o["interrupt_exist_connections"]) for o in c["outbounds"] if o["type"] == "selector"]')" = \
	"[('exit-1', ['ikev2-out', 'ikev2-out-2'], 'ikev2-out', True), ('exit-2', ['ikev2-out-2', 'ikev2-out'], 'ikev2-out-2', True)]" ] ||
	fail 'the exits are not selectors over their tunnels'
[ "$(query "$tmp/multi.json" '[r["outbound"] for r in c["route"]["rules"] if r.get("outbound", "").startswith(("ikev2", "exit"))]')" = \
	"['exit-1', 'exit-1']" ] || fail 'the selected domains do not leave by the first exit'
[ "$(query "$tmp/multi.json" 'c["dns"]["final"]')" = exit-1-dns ] ||
	fail 'names resolved through the tunnel do not follow the first exit'
# One tunnel enabled, not the first: the old layout, on its link.
{ base; printf 'tunnel\t3\tipsec-out3\n'; } >"$tmp/in"
render "$tmp/in" "$tmp/one.json" || fail 'a lone third tunnel was refused'
[ "$(query "$tmp/one.json" '[(o["tag"], o.get("bind_interface")) for o in c["outbounds"]]')" = \
	"[('direct-out', None), ('ikev2-out', 'ipsec-out3')]" ] || fail 'a lone tunnel did not take the old layout on its link'
{ base; printf 'tunnel\t1\tipsec-out\ntunnel\t2\tipsec-out2\nexit\t1\t1\t3\n'; } >"$tmp/in"
render "$tmp/in" "$tmp/bad.json" 2>/dev/null && fail 'an exit over a tunnel that is not enabled was rendered'
{ base; printf 'tunnel\t1\tipsec-out\ntunnel\t2\teth0\nexit\t1\t1\t2\n'; } >"$tmp/in"
render "$tmp/in" "$tmp/bad.json" 2>/dev/null && fail 'a tunnel on a link that is not a tunnel link was rendered'
# A first exit no tunnel serves refuses what it would carry, and names go to
# the WAN resolver as with the client off; nothing of it goes direct.
{ base | sed 's/^final_server\tupstream$/final_server\tikev2-upstream/'; printf 'tunnel\t1\tipsec-out\ntunnel\t2\tipsec-out2\nexit\t2\t2\n'; } >"$tmp/in"
render "$tmp/in" "$tmp/noexit.json" || fail 'several tunnels without a first exit were refused'
[ "$(query "$tmp/noexit.json" '[r["action"] for r in c["route"]["rules"] if r.get("inbound") in (["tproxy-router-in"], ["tproxy-in"]) and r.get("rule_set", ["ikev2-domains"]) == ["ikev2-domains"] and "source_ip_cidr" in r or r.get("inbound") == ["tproxy-router-in"]]')" = "['reject', 'reject']" ] ||
	fail 'a first exit without a tunnel did not refuse its traffic'
[ "$(query "$tmp/noexit.json" 'c["dns"]["final"]')" = upstream ] ||
	fail 'names were sent through a first exit that has no tunnel'
# Exits with names of their own: each a rule set ahead of the first exit's,
# its names given FakeIP addresses, its devices an inbound of their own; with
# one tunnel an exit that tunnel does not serve refuses what it would carry.
{
	base
	printf 'tunnel\t1\tipsec-out\ntunnel\t2\tipsec-out2\n'
	printf 'exit\t1\t1\t2\nexit\t2\t2\t1\nexit_rules\t2\t/var/x2.json\nexit_port\t2\t1612\n'
} >"$tmp/in"
render "$tmp/in" "$tmp/exits.json" || fail 'exit rule sets were refused'
[ "$(query "$tmp/exits.json" '[(r.get("inbound"), r.get("rule_set"), r.get("outbound", r["action"])) for r in c["route"]["rules"] if r.get("action") in ("route", "reject") and r.get("outbound") != "direct-out"]')" = \
	"[(['tproxy-exit-2-in'], None, 'exit-2'), (['tproxy-router-in'], ['ikev2-domains-2'], 'exit-2'), (['tproxy-in'], ['ikev2-domains-2'], 'exit-2'), (['tproxy-router-in'], None, 'exit-1'), (['tproxy-in'], ['ikev2-domains'], 'exit-1')]" ] ||
	fail "the exits are not routed in order: $(query "$tmp/exits.json" '[r for r in c["route"]["rules"]]')"
[ "$(query "$tmp/exits.json" '[r["rule_set"] for r in c["dns"]["rules"] if r.get("server") == "fakeip"]')" = "[['ikev2-domains', 'ikev2-domains-2']]" ] ||
	fail 'the names of the second exit get no FakeIP addresses'
[ "$(query "$tmp/exits.json" '[(i["tag"], i["listen_port"]) for i in c["inbounds"] if i["tag"].startswith("tproxy-exit")]')" = "[('tproxy-exit-2-in', 1612)]" ] ||
	fail 'the devices of the second exit have no inbound'
{ base; printf 'tunnel\t1\tipsec-out\nexit\t1\t1\nexit_rules\t3\t/var/x3.json\n'; } >"$tmp/in"
render "$tmp/in" "$tmp/one-exit.json" || fail 'one tunnel with an exit list was refused'
[ "$(query "$tmp/one-exit.json" '[(r.get("rule_set"), r.get("outbound", r["action"])) for r in c["route"]["rules"] if r.get("inbound") == ["tproxy-in"] and "rule_set" in r]')" = \
	"[(['ikev2-domains-3'], 'reject'), (['ikev2-domains'], 'ikev2-out')]" ] ||
	fail 'with one tunnel an exit it does not serve was not refused'

# The probe follows the link it is given.
printf '%s\t%s\n' bootstrap_host 8.8.8.8 bootstrap_port 53 doh_host dns.example \
	doh_port 443 doh_path /dns-query dns_address 127.0.0.77 link ipsec-out2 >"$tmp/in"
ucode "$generator" probe <"$tmp/in" >"$tmp/probe.json" || fail 'a probe on another link was refused'
[ "$(query "$tmp/probe.json" '[s["bind_interface"] for s in c["dns"]["servers"]]')" = "['ipsec-out2', 'ipsec-out2']" ] ||
	fail 'the probe did not use the link it was given'

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
