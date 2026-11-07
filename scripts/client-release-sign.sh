#!/bin/sh
#
# Signed release list for the desktop clients (Waypoint for macOS and Windows).
#
#   client-release-sign.sh keygen <private.pem> <public.pem>
#   client-release-sign.sh list   <file>...            > Waypoint-SHA256SUMS
#   client-release-sign.sh sign   <list> <private.pem> <list.sig>
#   client-release-sign.sh verify <list> <list.sig> <public.pem> [<dir>]
#
# Format (the contract both clients verify, see docs/DEVELOPMENT.md):
#   key        ECDSA P-256 (prime256v1); public key as SPKI PEM
#   signature  DER-encoded ECDSA-Sig-Value over SHA-256 of the exact bytes of
#              the list, stored as a binary file
#   list       "<sha256 hex>  <file name>" per line, names sorted bytewise
#
# Needs only openssl and a SHA-256 tool (sha256sum or shasum). Works on macOS
# and Linux CI.

set -eu

fail() {
	printf 'client-release-sign: %s\n' "$*" >&2
	exit 1
}

usage() {
	sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

need_file() {
	[ -f "$1" ] || fail "no such file: $1"
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift

case "$cmd" in
keygen)
	[ "$#" = 2 ] || usage
	private="$1"
	public="$2"
	[ ! -e "$private" ] || fail "refusing to overwrite $private"
	[ ! -e "$public" ] || fail "refusing to overwrite $public"
	(
		umask 077
		openssl ecparam -name prime256v1 -genkey -noout -out "$private"
	)
	openssl ec -in "$private" -pubout -out "$public" 2>/dev/null
	printf 'private key: %s (keep it secret; store it as the CLIENT_RELEASE_SIGNING_KEY secret)\n' "$private"
	printf 'public key:  %s (commit as keys/waypoint-client-release.pem)\n' "$public"
	;;
list)
	[ "$#" -ge 1 ] || usage
	for file in "$@"; do
		need_file "$file"
		name="$(basename "$file")"
		case "$name" in
		*[[:space:]]*) fail "file name has whitespace: $name" ;;
		esac
		printf '%s  %s\n' "$(sha256_of "$file")" "$name"
	done | LC_ALL=C sort -k2
	;;
sign)
	[ "$#" = 3 ] || usage
	need_file "$1"
	need_file "$2"
	[ -s "$1" ] || fail "the list is empty: $1"
	openssl dgst -sha256 -sign "$2" -out "$3" "$1" ||
		fail 'signing failed (is the key an EC P-256 private key?)'
	[ -s "$3" ] || fail 'signing produced no signature'
	;;
verify)
	[ "$#" -ge 3 ] || usage
	list="$1"
	sig="$2"
	public="$3"
	dir="${4:-}"
	need_file "$list"
	need_file "$sig"
	need_file "$public"
	[ -s "$list" ] || fail "the list is empty: $list"
	curve="$(openssl ec -pubin -in "$public" -text -noout 2>/dev/null | sed -n 's/^ASN1 OID: //p')"
	[ "$curve" = prime256v1 ] || fail "$public is not a P-256 public key"
	openssl dgst -sha256 -verify "$public" -signature "$sig" "$list" >/dev/null 2>&1 ||
		fail "signature does not match $list"
	if [ -n "$dir" ]; then
		while IFS= read -r line; do
			want="${line%%  *}"
			name="${line#*  }"
			case "$name" in
			*/* | '' | . | ..) fail "bad file name in the list: $name" ;;
			esac
			need_file "$dir/$name"
			[ "$(sha256_of "$dir/$name")" = "$want" ] || fail "checksum mismatch: $name"
		done <"$list"
	fi
	printf 'client-release-sign: %s verified\n' "$list"
	;;
*)
	usage
	;;
esac
