#!/bin/sh
# File-backed UCI emulator for the shell test suites.
#
# Copy or link this as `uci` into a test's PATH and point UCI_STUB_DIR at a
# writable directory. Each config becomes one file whose lines are either
# `<section>=<type>` or `<section>.<option>=<value>`, which is the shape
# `uci show` prints, so fixtures stay readable. `show` quotes option values,
# as uci does: code that parses its output sees what it sees on a router.
#
# Supported: show, get, set, delete, add_list, export, import, commit, reorder.
# Anything else exits 1 so an unmodelled call fails the test loudly instead of
# silently succeeding.

set -u

stub_dir="${UCI_STUB_DIR:?UCI_STUB_DIR must be set}"
mkdir -p "$stub_dir"

while [ "${1:-}" = -q ] || [ "${1:-}" = -m ] || [ "${1:-}" = -f ] ||
	[ "${1:-}" = -c ]; do
	case "${1:-}" in -f | -c) shift ;; esac
	shift
done

command="${1:-}"
[ "$#" -eq 0 ] || shift

config_of() { printf '%s' "${1%%.*}"; }
path_of() {
	case "$1" in
		*.*) printf '%s' "${1#*.}" ;;
		*) printf '' ;;
	esac
}
file_of() { printf '%s/%s' "$stub_dir" "$1"; }

stub_get() {
	local file="$1" key="$2"
	[ -f "$file" ] || return 1
	awk -v key="$key" -F= '
		{
			name = $1
			sub(/^[^=]*=/, "")
			if (name == key) { print; found = 1; exit }
		}
		END { exit found ? 0 : 1 }
	' "$file"
}

stub_set() {
	local file="$1" key="$2" value="$3" tmp
	mkdir -p "${file%/*}"
	: >>"$file"
	tmp="$(mktemp)" || return 1
	awk -v key="$key" -F= '{ name = $1; if (name != key) print }' "$file" >"$tmp"
	printf '%s=%s\n' "$key" "$value" >>"$tmp"
	mv "$tmp" "$file"
}

stub_delete() {
	local file="$1" key="$2" tmp
	[ -f "$file" ] || return 0
	tmp="$(mktemp)" || return 1
	# Deleting a section removes the options that hang off it as well.
	awk -v key="$key" -F= '
		{
			name = $1
			if (name == key) next
			if (index(name, key ".") == 1) next
			print
		}
	' "$file" >"$tmp"
	mv "$tmp" "$file"
}

case "$command" in
	show)
		file="$(file_of "${1:-}")"
		[ -f "$file" ] || exit 0
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			case "${line%%=*}" in
				*.*) printf "%s.%s='%s'\n" "${1:-}" "${line%%=*}" "${line#*=}" ;;
				*) printf '%s.%s\n' "${1:-}" "$line" ;;
			esac
		done <"$file"
		;;
	get)
		spec="${1:-}"
		stub_get "$(file_of "$(config_of "$spec")")" "$(path_of "$spec")"
		;;
	set)
		spec="${1:-}"
		value="${spec#*=}"
		spec="${spec%%=*}"
		stub_set "$(file_of "$(config_of "$spec")")" "$(path_of "$spec")" "$value"
		;;
	delete)
		spec="${1:-}"
		stub_delete "$(file_of "$(config_of "$spec")")" "$(path_of "$spec")"
		;;
	add_list)
		spec="${1:-}"
		value="${spec#*=}"
		spec="${spec%%=*}"
		file="$(file_of "$(config_of "$spec")")"
		key="$(path_of "$spec")"
		current="$(stub_get "$file" "$key" 2>/dev/null || true)"
		stub_set "$file" "$key" "${current:+$current }$value"
		;;
	export)
		file="$(file_of "${1:-}")"
		[ -f "$file" ] && cat "$file"
		exit 0
		;;
	import)
		file="$(file_of "${1:-}")"
		mkdir -p "${file%/*}"
		cat >"$file"
		;;
	commit | reorder) ;;
	*) exit 1 ;;
esac
