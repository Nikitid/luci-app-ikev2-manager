#!/bin/sh

# Router-side scripts run against BusyBox applets, not GNU coreutils. Developer
# machines and CI runners provide the GNU versions, so a GNU-only option is
# accepted locally and every test passes while the router silently does
# something else. The confirmed example is `sort -o`: BusyBox is built without
# CONFIG_FEATURE_SORT_BIG, ignores the option, leaves the target file untouched
# and writes the sorted result to stdout instead. That corrupted the inbound
# user-policy sets and leaked list contents into command output.
#
# The staged package is scanned rather than the source tree, so the list can
# never drift from what actually reaches a router, and the package lifecycle
# scripts generated into CONTROL are covered too. Only patterns verified
# against the supported OpenWrt BusyBox build belong here.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$root"

status=0

report() {
	printf 'busybox-compat: %s\n' "$1" >&2
	status=1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

stage="$work/stage"
"$root/scripts/stage-package.sh" "$stage" >/dev/null

# Everything the package installs that a shell will interpret: the CONTROL
# lifecycle scripts plus any payload file carrying a shell shebang.
find "$stage" -type f -print >"$work/all"
: >"$work/scripts"
while IFS= read -r file; do
	case "${file#"$stage"}" in
		/CONTROL/preinst | /CONTROL/postinst | /CONTROL/prerm | /CONTROL/postrm)
			printf '%s\n' "$file" >>"$work/scripts"
			continue
			;;
	esac
	head -n1 "$file" 2>/dev/null | grep -qE '^#!.*/(ba)?sh' &&
		printf '%s\n' "$file" >>"$work/scripts"
done <"$work/all"

[ -s "$work/scripts" ] || {
	report 'no shell scripts found in the staged package'
	exit "$status"
}

# The APK path generates its lifecycle scripts from the OpenWrt Makefile rather
# than from scripts/stage-package.sh, so those blocks are scanned as well.
printf '%s\n' "$root/Makefile" >>"$work/scripts"
# Scripts outside the package that run on a router: the Uptime Kuma checker
# from cron, the installer and the read-only sweep's probe.
printf '%s\n' "$root/scripts/kuma-push.sh" "$root/scripts/install.sh" \
	"$root/scripts/health-check.sh" >>"$work/scripts"

check_pattern() {
	pattern="$1"
	message="$2"
	exclude="${3:-}"
	while IFS= read -r file; do
		grep -nE "$pattern" "$file" | while IFS= read -r hit; do
			[ -n "$exclude" ] &&
				printf '%s' "$hit" | grep -qE "$exclude" && continue
			printf '%s:%s\n' "${file#"$stage"}" "$hit"
		done
	done <"$work/scripts" >"$work/hits"
	[ -s "$work/hits" ] || return 0
	while IFS= read -r hit; do
		report "$message: $hit"
	done <"$work/hits"
}

# BusyBox sort: Usage: sort [-nru] [FILE]...
check_pattern '(^|[;&|[:space:]])sort([[:space:]]+-[A-Za-z]+)*[^|;&]*[[:space:]]-o([[:space:]]|$)' \
	'BusyBox sort does not support -o; write to a temporary file and mv it'

# The same build has no key fields either: -k and -t are accepted by GNU sort
# on every developer machine and rejected on the router. -s is supported.
check_pattern '(^|[;&|[:space:]])sort([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*[kt]' \
	'BusyBox sort supports only -n, -r, -u, -s and -z; sort on the whole line'

# The supported BusyBox flock provides -s/-x/-u/-n and a file descriptor,
# but not util-linux timeouts or automatic descriptor-closing options.
check_pattern '(^|[;&|[:space:]])flock[[:space:]]+(-[A-Za-z]*[Eow]|--(timeout|close|conflict-exit-code))' \
	'BusyBox flock supports only the short shared/exclusive/unlock/nonblocking flags'

# BusyBox grep has no PCRE support.
check_pattern '(^|[;&|[:space:]])grep([[:space:]]+-[A-Za-z]*P)' \
	'BusyBox grep does not support -P'

# A pattern file: with an empty one BusyBox grep matches every line, where GNU
# grep matches none, verified on the router. "grep -v -f" of a list that had
# nothing in it yet printed nothing, which emptied the service networks and
# took Telegram's addresses out of the tunnel.
check_pattern '(^|[;&|[:space:]])grep([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*f([[:space:]]|$)' \
	'BusyBox grep matches every line against an empty pattern file; filter with awk'

# BusyBox find has no -printf.
check_pattern '(^|[;&|[:space:]])find[^|;&]*[[:space:]]-printf([[:space:]]|$)' \
	'BusyBox find does not support -printf'

# Nor -links: "find: unrecognized: -links", verified on the router.
check_pattern '(^|[;&|[:space:]])find[^|;&]*[[:space:]]-links([[:space:]]|$)' \
	'BusyBox find does not support -links'

# The supported OpenWrt BusyBox tr applet treats these POSIX class expressions
# as literal character sets and, for example, converts "ru" to "rl". Runtime
# values here are ASCII, so explicit A-Z/a-z ranges are required.
check_pattern "tr[[:space:]]+['\"]?\\[:upper:\\]['\"]?[[:space:]]+['\"]?\\[:lower:\\]" \
	'BusyBox tr does not safely expand POSIX upper/lower classes; use A-Z and a-z'

# The base64 applet is not present in the supported build; openssl provides it.
check_pattern '(^|[;&|[:space:]])base64([[:space:]]|$)' \
	'the base64 applet is unavailable on OpenWrt; use openssl base64' \
	'openssl[[:space:]]+base64'

# The supported nslookup applet accepts a host and optional server only. Its
# output resembles the fuller BIND utility closely enough that unsupported
# options can slip through local tests unnoticed.
check_pattern '(^|[;&|[:space:]])nslookup[^|;&]*[[:space:]]-port(=|[[:space:]])' \
	'BusyBox nslookup does not support -port; probe the standard DNS port directly'

# OpenWrt's BusyBox sleep takes whole seconds; "sleep 0.2" fails with
# "invalid number" and the loop around it spins or stops.
check_pattern '(^|[;&|[:space:]])sleep[[:space:]]+[0-9]*\.[0-9]' \
	'BusyBox sleep takes whole seconds only'

# The timeout applet is optional in OpenWrt BusyBox builds. Runtime scripts
# must use their own watchdog or a tool's native timeout option.
check_pattern '^[[:space:]]*timeout[[:space:]]|[;&|][[:space:]]*timeout[[:space:]]' \
	'the BusyBox timeout applet is optional; use a watchdog-based bounded runner' \
	'^[0-9]+:[[:space:]]+timeout[[:space:]]'

# ash is not bash: these are accepted by the developer shell and fail on the
# router.
# `[[` is only the bash keyword when it stands as a command word; the POSIX
# class [[:space:]] inside a regex must not match.
check_pattern '(^|[;&|[:space:]])(\[\[[[:space:]]|declare[[:space:]]|local[[:space:]]+-[Aa][[:space:]])' \
	'bash-only syntax is not available in BusyBox ash'
check_pattern 'set[[:space:]]+-[a-z]*o[[:space:]]+pipefail' \
	'BusyBox ash does not support pipefail'
check_pattern '\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,|/[^}]*/)' \
	'bash-only parameter expansion is not available in BusyBox ash'

if [ "$status" = 0 ]; then
	printf 'busybox-compat OK\n'
fi

exit "$status"
