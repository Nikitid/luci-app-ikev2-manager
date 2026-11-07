#!/bin/sh

# A person's own sites and networks: the router accepts and refuses exactly the
# examples both clients check, and a refusal names the entry and the reason, so
# the window can say "203.0.113.7: a documentation range" instead of "refused".

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
command -v ucode >/dev/null 2>&1 || { printf '%s\n' 'own addresses: ucode is required' >&2; exit 1; }

ucode -L "$root/ikev2-manager-runtime/lib/*.uc" -e '
import { readfile } from "fs";
import { own_domain, own_network, check_own_entries, own_refusal } from "client-access-own";
let fixture = json(readfile(ARGV[0])), server = { address: fixture.server }, failures = [];
function outcome(check, value) {
	try { return { ok: check(value) }; }
	catch (error) { return { reason: own_refusal(error)?.reason, entry: own_refusal(error)?.entry, message: error.message }; }
}
function compare(kind, sample, got) {
	if (sample.ok != null && got.ok != sample.ok)
		push(failures, `${kind} ${sample.input}: expected ${sample.ok}, got ${got.ok ?? got.message}`);
	if (sample.reason != null && got.reason != sample.reason)
		push(failures, `${kind} ${sample.input}: expected ${sample.reason}, got ${got.reason ?? got.ok ?? got.message}`);
	if (sample.reason != null && got.entry != sample.input)
		push(failures, `${kind} ${sample.input}: the refusal names ${got.entry}`);
}
let rule = { limit: 32, ports: [ 443 ] };
for (let sample in fixture.domains)
	compare("site", sample, outcome(value => check_own_entries({ domains: [ value ], networks: [] }, rule, server).domains[0], sample.input));
for (let sample in fixture.networks)
	compare("network", sample, outcome(value => check_own_entries({ domains: [], networks: [ value ] }, rule, server).networks[0], sample.input));
let over = outcome(value => check_own_entries(value, { limit: 1, ports: [ 443 ] }, server), { domains: [ "a.example.org", "b.example.org" ], networks: [] });
if (over.reason != "over_limit") push(failures, `over the limit: got ${over.reason ?? over.message}`);
if (length(failures)) { warn(join("\n", failures), "\n"); exit(1); }
print("own address examples OK: ", length(fixture.domains) + length(fixture.networks), "\n");
' "$root/desktop-clients/fixtures/own-addresses.json"
