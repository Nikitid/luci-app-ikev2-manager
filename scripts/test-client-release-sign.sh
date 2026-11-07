#!/bin/sh

# The signed release list is the only thing that lets a desktop client trust a
# downloaded installer, so what must hold is refusal: a changed list, a changed
# signature, another key, a changed file and a missing signature all fail.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tool="$root/scripts/client-release-sign.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

refuses() {
	label="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		fail "accepted: $label"
	fi
}

mkdir "$tmp/dist"
printf 'package one\n' >"$tmp/dist/Waypoint-9.9.9.pkg"
printf 'installer\n' >"$tmp/dist/Waypoint-9.9.9-x64.msi"
printf 'setup\n' >"$tmp/dist/WaypointSetup.exe"

"$tool" keygen "$tmp/k.pem" "$tmp/k.pub" >/dev/null
"$tool" keygen "$tmp/other.pem" "$tmp/other.pub" >/dev/null
refuses 'keygen over an existing key' "$tool" keygen "$tmp/k.pem" "$tmp/k.pub"

"$tool" list "$tmp"/dist/* >"$tmp/list"
[ "$(wc -l <"$tmp/list" | tr -d ' ')" = 3 ] || fail 'list does not name three files'
grep -q '  Waypoint-9.9.9.pkg$' "$tmp/list" || fail 'list lacks a bare file name'
sorted="$(LC_ALL=C sort -k2 "$tmp/list")"
[ "$sorted" = "$(cat "$tmp/list")" ] || fail 'list is not sorted by name'

"$tool" sign "$tmp/list" "$tmp/k.pem" "$tmp/list.sig"
"$tool" verify "$tmp/list" "$tmp/list.sig" "$tmp/k.pub" "$tmp/dist" >/dev/null ||
	fail 'a good signature was refused'

# The signature is DER: a SEQUENCE of two INTEGERs, which is what CryptoKit's
# derRepresentation and .NET's Rfc3279DerSequence read.
[ "$(od -An -tx1 -N1 "$tmp/list.sig" | tr -d ' \n')" = 30 ] || fail 'signature is not a DER sequence'

# Changed list.
cp "$tmp/list" "$tmp/list.bad"
printf '%s  Waypoint-9.9.9.pkg\n' "$(printf 'x' | openssl dgst -sha256 | awk '{print $NF}')" >>"$tmp/list.bad"
refuses 'a changed list' "$tool" verify "$tmp/list.bad" "$tmp/list.sig" "$tmp/k.pub"

# Changed signature: flip the last byte, then truncate.
sig_size="$(wc -c <"$tmp/list.sig" | tr -d ' ')"
head -c "$((sig_size - 1))" "$tmp/list.sig" >"$tmp/sig.bad"
printf '\001' >>"$tmp/sig.bad"
cmp -s "$tmp/list.sig" "$tmp/sig.bad" && printf '\002' >>"$tmp/sig.bad"
refuses 'a changed signature' "$tool" verify "$tmp/list" "$tmp/sig.bad" "$tmp/k.pub"
head -c "$((sig_size - 4))" "$tmp/list.sig" >"$tmp/sig.short"
refuses 'a truncated signature' "$tool" verify "$tmp/list" "$tmp/sig.short" "$tmp/k.pub"
: >"$tmp/sig.empty"
refuses 'an empty signature' "$tool" verify "$tmp/list" "$tmp/sig.empty" "$tmp/k.pub"

# Another key, and a missing signature file.
refuses 'another key' "$tool" verify "$tmp/list" "$tmp/list.sig" "$tmp/other.pub"
refuses 'a missing signature' "$tool" verify "$tmp/list" "$tmp/none.sig" "$tmp/k.pub"

# A signed list does not vouch for a file that changed after listing.
printf 'tampered\n' >"$tmp/dist/Waypoint-9.9.9.pkg"
refuses 'a changed artifact' "$tool" verify "$tmp/list" "$tmp/list.sig" "$tmp/k.pub" "$tmp/dist"
"$tool" verify "$tmp/list" "$tmp/list.sig" "$tmp/k.pub" >/dev/null ||
	fail 'the list alone should still verify'

# A key that is not P-256 is refused as a verifier.
openssl ecparam -name secp384r1 -genkey -noout -out "$tmp/p384.pem"
openssl ec -in "$tmp/p384.pem" -pubout -out "$tmp/p384.pub" 2>/dev/null
refuses 'a P-384 key' "$tool" verify "$tmp/list" "$tmp/list.sig" "$tmp/p384.pub"

printf 'test-client-release-sign OK\n'
