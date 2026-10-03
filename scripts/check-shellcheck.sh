#!/bin/sh

# The CI security job runs shellcheck at error level over every shell script.
# A directive placed inside a command passed every local check and failed
# only there; this runs the same check before a push, and says it was skipped
# where the tool is not installed. CI pins version 0.10.0, which reads any
# comment line that begins with the tool's name as a directive; a newer
# version can accept what that one refuses.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$root"

command -v shellcheck >/dev/null 2>&1 || {
	printf '%s\n' 'check-shellcheck: shellcheck is not installed, skipped'
	exit 0
}

list="$(mktemp)"
trap 'rm -f "$list"' EXIT
git ls-files | while IFS= read -r file; do
	case "$file" in
		*.sh) printf '%s\n' "$file" ;;
		*)
			[ -f "$file" ] && head -n 1 "$file" | grep -Eq '^#!.*(/sh|ash|bash)' &&
				printf '%s\n' "$file" || :
			;;
	esac
done >"$list"
tr '\n' '\0' <"$list" | xargs -0 shellcheck -S error
printf 'check-shellcheck OK: %s files\n' "$(wc -l <"$list" | tr -d ' ')"
