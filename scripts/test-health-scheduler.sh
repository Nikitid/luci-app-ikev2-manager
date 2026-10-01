#!/bin/sh

# The watcher ran every check in line. A slow resolver probe or FakeIP canary
# held back the next tunnel reconnect by as long as it took, and a
# configuration transaction stopped the whole pass. Slow checks now run
# detached, one copy of each at a time, on their own intervals.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
health="$root/ikev2-manager-runtime/ikev2-health.sh"
tmp="$(mktemp -d)"
# A shell error inside a sourced function must still fail the test; some
# shells report status 0 to the EXIT trap after an unset variable.
finished=0
trap 'rm -rf "$tmp"; [ "$finished" = 1 ] || exit 1' EXIT
trap 'exit 1' INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

for name in periodic_due mark_periodic spawn_task periodic_task; do
	awk -v name="$name" '
		index($0, name "() {") == 1 { body = 1 }
		body { print }
		body && $0 == "}" { exit }
	' "$health" >>"$tmp/functions.sh"
	grep -q "^$name() {" "$tmp/functions.sh" || fail "$name is missing from the watcher"
done
. "$tmp/functions.sh"
task_dir="$tmp/tasks"

slow() {
	printf 'start\n' >>"$tmp/calls"
	sleep 2
}
calls() { grep -c start "$tmp/calls" 2>/dev/null || echo 0; }

# A slow task does not hold back its caller.
started="$(date +%s)"
spawn_task slow slow
[ $(( $(date +%s) - started )) -lt 2 ] || fail 'a detached task held back the watcher'
sleep 1

# One copy at a time.
spawn_task slow slow
[ "$(calls)" = 1 ] || fail 'a second copy started while the first still ran'

# Once it finishes it can run again.
i=0
while [ -e "$task_dir/slow.pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ ! -e "$task_dir/slow.pid" ] || fail 'a finished task left its pid file behind'
spawn_task slow slow
sleep 0.5
[ "$(calls)" = 2 ] || fail 'a finished task could not run again'

# A stale pid file from a watcher that died does not block the task forever.
wait
printf '999999\n' >"$task_dir/quick.pid"
spawn_task quick sh -c ": >'$tmp/quick'"
sleep 0.5
[ -e "$tmp/quick" ] || fail 'a stale pid file blocked its task'

# A periodic task keeps its interval.
quick() { printf 'start\n' >>"$tmp/calls"; }
rm -f "$tmp/calls"
periodic_task paced "$tmp/paced.state" 60 quick
wait
periodic_task paced "$tmp/paced.state" 60 quick
wait
[ "$(calls)" = 1 ] || fail 'a periodic task ran before its interval'
printf '%s\n' $(( $(date +%s) - 61 )) >"$tmp/paced.state"
periodic_task paced "$tmp/paced.state" 60 quick
wait
[ "$(calls)" = 2 ] || fail 'a periodic task did not run after its interval'

# That the watcher starts the slow helpers through this scheduler, and that a
# transaction holds back its passes but not the quality sample, is checked on
# the running watcher by scripts/test-health-loop.sh.

finished=1
printf '%s\n' 'health scheduler tests OK'
