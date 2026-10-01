#!/bin/sh
#
# Router transactions: a snapshot, the steps in a subshell, and on failure the
# snapshot put back and every runtime reconciled with it. Save took two
# snapshots and restored both, and a protected-network change died inside its
# apply before its own rollback could run, leaving the change committed while
# the page said the previous state was restored.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
system="$root/ikev2-manager-runtime/ikev2-manager-system.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

extract() {
	awk -v name="$1" '
		index($0, name "() {") == 1 { body = 1 }
		body { print }
		body && $0 == "}" { exit }
	' "$system"
}

for name in with_transaction reconcile_runtimes; do
	extract "$name" >>"$tmp/functions.sh"
	grep -q "^$name() {" "$tmp/functions.sh" || fail "function is missing: $name"
done

log="$tmp/log"
# shellcheck disable=SC2034 # read by the extracted functions
run() (
	. "$tmp/functions.sh"
	die() { printf 'die:%s\n' "$*" >>"$log"; exit 1; }
	backup_uci_state() { printf 'backup %s\n' "$1" >>"$log"; mkdir -p "$tmp/backup-$1"; printf '%s\n' "$tmp/backup-$1"; }
	restore_uci_state() { printf 'restore\n' >>"$log"; [ ! -e "$tmp/restore-fails" ]; }
	step_ok() { printf 'step\n' >>"$log"; }
	step_dies() { printf 'step\n' >>"$log"; die 'the step failed'; }
	nested_dies() { with_transaction inner 'Inner failed' step_dies; }
	"$@"
)

: >"$log"
run with_transaction apply 'Managed apply failed' step_ok || fail 'a successful transaction failed'
printf '%s\n' 'backup apply' step | cmp -s - "$log" || fail "a successful transaction did more: $(cat "$log")"
[ ! -e "$tmp/backup-apply" ] || fail 'a successful transaction kept its snapshot'

: >"$log"
if run with_transaction apply 'Managed apply failed' step_dies; then fail 'a failed step was reported as success'; fi
grep -qx 'restore' "$log" || fail 'a step that died skipped the rollback'
grep -qx 'die:Managed apply failed; previous router state was restored' "$log" ||
	fail "a restored rollback was not reported: $(cat "$log")"
[ ! -e "$tmp/backup-apply" ] || fail 'a rolled back transaction kept its snapshot'

: >"$log"
: >"$tmp/restore-fails"
if run with_transaction apply 'Managed apply failed' step_dies; then fail 'a failed step was reported as success'; fi
grep -qx 'die:Managed apply failed and automatic rollback was incomplete' "$log" ||
	fail "an incomplete rollback was reported as restored: $(cat "$log")"
rm -f "$tmp/restore-fails"

# A transaction inside another takes no snapshot of its own, and its failure
# reaches the outer rollback.
: >"$log"
if run with_transaction coverage-add 'Unable to add protected network' nested_dies; then
	fail 'a failed nested transaction was reported as success'
fi
[ "$(grep -c '^backup ' "$log")" = 1 ] || fail "a nested transaction took a second snapshot: $(cat "$log")"
[ "$(grep -c '^restore$' "$log")" = 1 ] || fail "the snapshot was restored more than once: $(cat "$log")"
grep -qx 'die:Unable to add protected network; previous router state was restored' "$log" ||
	fail "the outer transaction did not report its rollback: $(cat "$log")"

# Reconciling brings up the XFRM links first, then routing and the rest, and
# goes on past a failing step.
for helper in xfrm routing; do
	printf '#!/bin/sh\nprintf "%s %%s\\n" "$1" >>"%s"\n[ ! -e "%s/fail-%s" ]\n' \
		"$helper" "$log" "$tmp" "$helper" >"$tmp/$helper"
	chmod 755 "$tmp/$helper"
done
reconcile() (
	. "$tmp/functions.sh"
	getv() { case "$1.$2" in globals.configured) echo 1 ;; domains.engine) echo fakeip ;; esac; }
	xfrm_init="$tmp/xfrm"
	routing_runtime_helper="$tmp/routing"
	domain_router_helper="$tmp/routing"
	sync_inbound_user_policy() { printf 'user-policy\n' >>"$log"; }
	pause_block_sync() { printf 'pause\n' >>"$log"; }
	reconcile_runtimes
)
: >"$log"
reconcile || fail 'a clean reconcile failed'
printf '%s\n' 'xfrm start' 'routing sync-all' user-policy pause 'routing refresh' | cmp -s - "$log" ||
	fail "the runtimes were not reconciled in order: $(tr '\n' ',' <"$log")"
: >"$tmp/fail-xfrm"
: >"$log"
if reconcile; then fail 'a failed XFRM start was reported as reconciled'; fi
grep -qx 'routing sync-all' "$log" || fail 'a failed XFRM start stopped the rest of the reconcile'

printf '%s\n' 'transaction tests OK'
