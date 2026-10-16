#!/bin/sh

set -eu

fail() {
	printf 'check-public-tree: %s\n' "$*" >&2
	exit 1
}

tracked="$(git ls-files --cached --others --exclude-standard)"

for prefix in backups/ build/ dist/ firmware/ .local-artifacts/ docs/worklogs/ docs/private/; do
	printf '%s\n' "$tracked" | grep -q "^$prefix" &&
		fail "generated or private path is tracked: $prefix"
done

for prefix in luci-domain-editor/ router-ikev2/; do
	[ -e "$prefix" ] &&
		fail "legacy source path is tracked: $prefix"
done

for suffix in '.key' '.p12' '.pfx' '.mobileconfig' '.har'; do
	printf '%s\n' "$tracked" | grep -q "${suffix}\$" &&
		fail "secret-bearing file type is tracked: $suffix"
done

printf '%s\n' "$tracked" |
	grep -Eq '(^|/)(auth-state[^/]*\.json|cookies[^/]*\.txt|\.envrc|\.secrets([^/]*)?)$' &&
	fail 'secret-bearing filename is tracked'

git ls-files -s | grep -q '^120000 ' &&
	fail 'symbolic links are not allowed in the public tree'

rm -f /tmp/ikev2-public-tree-findings
printf '%s\n' "$tracked" | while IFS= read -r file; do
	[ -f "$file" ] || continue
	[ "$file" = scripts/check-public-tree.sh ] && continue
	# The report service is the one public address of the developer's that the
	# package names on purpose: applications send their problem reports there.
	# Every other name of the owner's hosts stays out.
	grep -IHnE \
		'nikitid\.com|nikitid\.ru|nikitid-phone|nikitid-proxy|flint2|ikev2-pbr-glinet|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}' \
		"$file" 2>/dev/null | sed 's#https://reports\.nikitid\.ru##g' |
		grep -E 'nikitid\.com|nikitid\.ru|nikitid-phone|nikitid-proxy|flint2|ikev2-pbr-glinet|PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}' \
		>>/tmp/ikev2-public-tree-findings || true
done
if [ -s /tmp/ikev2-public-tree-findings ]; then
	cat /tmp/ikev2-public-tree-findings >&2
	rm -f /tmp/ikev2-public-tree-findings
	fail 'private environment identifiers or key material found'
fi
rm -f /tmp/ikev2-public-tree-findings

[ "$(sed -n 's/^PKG_LICENSE:=//p' Makefile)" = MIT ] ||
	fail 'Makefile package license must match the repository MIT license'
grep -q '^MIT License$' LICENSE ||
	fail 'LICENSE is not the canonical MIT license text'

printf 'check-public-tree OK\n'
