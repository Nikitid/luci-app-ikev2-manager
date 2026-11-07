#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
found=0

for workflow in "$root"/.github/workflows/*.yml; do
	while IFS= read -r action; do
		found=1
		ref="${action##*@}"
		case "$ref" in
			????????????????????????????????????????) ;;
			*)
				printf 'GitHub Action is not pinned to a commit: %s\n' "$action" >&2
				exit 1
				;;
		esac
	done <<EOF
$(sed -n 's/^[[:space:]]*\(-[[:space:]]*\)\{0,1\}uses:[[:space:]]*\([^ #]*\).*/\2/p' "$workflow")
EOF
done

[ "$found" = 1 ] || {
	printf 'No GitHub Actions found\n' >&2
	exit 1
}

printf 'check-actions-pinned OK\n'
