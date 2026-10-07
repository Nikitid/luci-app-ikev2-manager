#!/bin/sh
# ucode compiles a regular expression every time it is evaluated, and on a
# router a counted repetition is expanded state by state: /x{0,127}/ costs
# twenty milliseconds per match, /x{0,47}/ two. A page request or a registration
# runs hundreds of such checks. Bound the length with length() and write the
# repetition as * or +; small counts (an octet, a port) are fine.
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
found="$(grep -nE '\{[0-9]*,?(1[6-9]|[2-9][0-9]|[0-9]{3,})\}' "$root"/ikev2-manager-runtime/lib/*.uc || :)"
[ -z "$found" ] || {
	printf '%s\n' "$found" >&2
	printf '%s\n' 'check-ucode-regex: a counted repetition of 16 or more; use length() and * or +' >&2
	exit 1
}
printf '%s\n' 'check-ucode-regex OK'
