#!/bin/sh
# Shared detached-action primitives for IKEv2 Manager backends.
#
# Callers provide:
#   action_status_file, action_status_dir, action_lock_dir, action_lock_status
#   run_action(), die()

action_status() {
	mkdir -p "$action_status_dir"
	{
		printf 'action_id=%s\n' "$1"
		printf 'state=%s\n' "$2"
		printf 'updated=%s\n' "$(date +%s)"
		[ -z "${3:-}" ] || printf 'message=%s\n' "$3"
	} >"$action_status_dir/$1.status.new"
	mv "$action_status_dir/$1.status.new" "$action_status_dir/$1.status"
	cp "$action_status_dir/$1.status" "${action_status_file}.new"
	mv "${action_status_file}.new" "$action_status_file"
	case "$2" in
		ok | error)
			logger -t ikev2-action "end action_id=$1 state=$2 message=${3:-}" 2>/dev/null || true
			;;
	esac
}

# PID-backed lock directories for small workers that do not use the global
# action lock. A dead worker must not disable updates until the next reboot.
pid_lock_live() {
	local dir="$1" pid expected current created
	pid="$(cat "$dir/pid" 2>/dev/null || true)"
	case "$pid" in
		'' | *[!0-9]*)
			# Preserve an older worker paused between mkdir and publishing its PID.
			created="$(date -r "$dir" +%s 2>/dev/null ||
				stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || true)"
			case "$created" in '' | *[!0-9]*) return 0 ;; esac
			[ $(( $(date +%s) - created )) -le 5 ]
			return ;;
	esac
	kill -0 "$pid" 2>/dev/null || return 1
	expected="$(cat "$dir/start" 2>/dev/null || true)"
	[ -n "$expected" ] || return 0
	current="$(process_start_identity "$pid" 2>/dev/null || true)"
	[ "$current" = "$expected" ]
}

# The permanent gate inode serializes publication, stale-owner reclamation and
# release. Never unlink it: a new inode would permit two independent flock locks.
# Only these short metadata operations hold the kernel lock, not the worker job.
pid_lock_acquire() (
	local dir="$1" pid
	flock -n 9 || return 1
	if ! mkdir "$dir" 2>/dev/null; then
		pid_lock_live "$dir" && return 1
		rm -f "$dir/pid" "$dir/start"
		rmdir "$dir" 2>/dev/null || return 1
		mkdir "$dir" 2>/dev/null || return 1
	fi
	process_start_identity "$$" >"$dir/start" 2>/dev/null || :
	printf '%s\n' "$$" >"$dir/pid"
) 9>"${1}.guard"

pid_lock_busy() (
	local dir="$1" pid
	flock -n 9 || return 0
	[ -d "$dir" ] || return 1
	pid_lock_live "$dir" && return 0
	rm -f "$dir/pid" "$dir/start"
	rmdir "$dir" 2>/dev/null || return 0
	return 1
) 9>"${1}.guard"

pid_lock_release() (
	local dir="$1"
	flock -x 9 || return 1
	[ "$(cat "$dir/pid" 2>/dev/null || true)" = "$$" ] || return 0
	pid_lock_live "$dir" || return 0
	rm -f "$dir/pid" "$dir/start"
	rmdir "$dir" 2>/dev/null || true
) 9>"${1}.guard"

# Non-blocking inspection for the global action lock.  Health reconciliation
# must not race a real configuration transaction, but a worker killed between
# actions must not suppress self-healing until the next reboot either.
process_start_identity() {
	local target_pid="$1"
	[ -r "/proc/$target_pid/stat" ] || return 1
	# Field 2 (comm) is parenthesized and may contain spaces. Strip through its
	# closing parenthesis first; starttime is then field 20 of the remainder.
	sed 's/^.*) //' "/proc/$target_pid/stat" 2>/dev/null |
		awk 'NF >= 20 { print $20; exit }'
}

action_lock_owner_alive() {
	local pid="$1" expected_start current_start
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
	expected_start="$(sed -n 's/^pid_start=//p' "$action_lock_status" 2>/dev/null | tail -1)"
	# A lock written by an older package has no process identity. Preserve it
	# while the PID is live; an upgrade must never steal an in-flight action.
	[ -n "$expected_start" ] || return 0
	current_start="$(process_start_identity "$pid" 2>/dev/null || true)"
	[ -n "$current_start" ] && [ "$current_start" = "$expected_start" ]
}

# Whether the router action lock belongs to this process or one of its
# ancestors, which makes this process part of that action. A child cannot be
# told so through its environment: rpcd passes a page's environment through
# unchanged, so a claim made there could come from any session.
action_lock_held_by_ancestor() {
	local holder pid="$$" depth=0 line
	holder="$(sed -n 's/^pid=//p' "$action_lock_status" 2>/dev/null | tail -1)"
	case "$holder" in '' | *[!0-9]*) return 1 ;; esac
	action_lock_owner_alive "$holder" || return 1
	# Every process descends from init, so the walk stops before it.
	while [ "$depth" -lt 32 ] && [ "$pid" -gt 1 ]; do
		[ "$pid" != "$holder" ] || return 0
		read -r line 2>/dev/null <"${IKEV2_PROC_ROOT:-/proc}/$pid/stat" || return 1
		# Field 2 (comm) may contain spaces; the parent PID is the second field
		# after its closing parenthesis.
		set -- ${line##*) }
		pid="$2"
		depth=$((depth + 1))
	done
	return 1
}

action_lock_busy_unlocked() {
	local pid now created
	[ -d "$action_lock_dir" ] || return 1
	pid="$(sed -n 's/^pid=//p' "$action_lock_status" 2>/dev/null | tail -1)"
	now="$(date +%s)"
	if action_lock_owner_alive "$pid"; then
		return 0
	elif [ -z "$pid" ]; then
		# mkdir() precedes publishing the status file.  Preserve a fresh empty
		# lock so the health loop cannot delete it in that short hand-off window.
		created="$(date -r "$action_lock_dir" +%s 2>/dev/null ||
			stat -c %Y "$action_lock_dir" 2>/dev/null || true)"
		case "$created" in
			'' | *[!0-9]*) return 0 ;;
		esac
		[ $((now - created)) -gt 5 ] || return 0
	fi
	rm -f "$action_lock_status"
	rmdir "$action_lock_dir" 2>/dev/null || return 0
	return 1
}

# A lock that is not there is free without taking the gate: the watcher asks
# every few seconds, and the subshell and flock each time cost two processes.
action_lock_busy() {
	[ -d "$action_lock_dir" ] || return 1
	action_lock_busy_gated
}

action_lock_busy_gated() (
	flock -n 9 || return 0
	action_lock_busy_unlocked
) 9>"${action_lock_dir}.guard"

action_lock_try_acquire() (
	local owner="$1" id="$2" pid_start lock_status_tmp
	flock -n 9 || return 1
	action_lock_busy_unlocked && return 1
	mkdir "$action_lock_dir" 2>/dev/null || return 1
	lock_status_tmp="${action_lock_status}.new.$$"
	pid_start="$(process_start_identity "$$" 2>/dev/null || true)"
	if ! printf 'owner=%s\naction_id=%s\npid=%s\npid_start=%s\nupdated=%s\n' \
		"$owner" "$id" "$$" "$pid_start" "$(date +%s)" >"$lock_status_tmp" ||
	   ! mv "$lock_status_tmp" "$action_lock_status"; then
		rm -f "$lock_status_tmp"
		rmdir "$action_lock_dir" 2>/dev/null || true
		return 1
	fi
	logger -t ikev2-action "begin owner=$owner action_id=$id pid=$$" 2>/dev/null || true
) 9>"${action_lock_dir}.guard"

acquire_action_lock() {
	local tries=0 max_tries="${IKEV2_ACTION_LOCK_WAIT_SECONDS:-5}"
	case "$max_tries" in '' | *[!0-9]*) max_tries=5 ;; esac
	while ! action_lock_try_acquire "$1" "$2"; do
		tries=$((tries + 1))
		[ "$tries" -lt "$max_tries" ] || return 1
		sleep 1
	done
}

# Takes a free lock at once and says it is waiting only when it is. Written
# unconditionally, the waiting line showed before every action.
acquire_action_lock_announced() {
	local owner="$1" id="$2"
	shift 2
	action_lock_try_acquire "$owner" "$id" && return 0
	"$@" running 'Waiting for other router actions...'
	acquire_action_lock "$owner" "$id"
}

release_action_lock() (
	local owner_pid
	flock -x 9 || return 1
	owner_pid="$(sed -n 's/^pid=//p' "$action_lock_status" 2>/dev/null | tail -1)"
	[ "$owner_pid" = "$$" ] || return 0
	action_lock_owner_alive "$owner_pid" || return 0
	rm -f "$action_lock_status"
	rmdir "$action_lock_dir" 2>/dev/null || true
	logger -t ikev2-action "end pid=$$" 2>/dev/null || true
) 9>"${action_lock_dir}.guard"

start_action() {
	kind="$1"
	shift
	id="$(date +%s)-$$"
	find "$action_status_dir" -type f -mtime +7 -exec rm -f {} \; 2>/dev/null || :
	action_status "$id" running 'Queued...'
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _action-run "$id" "$kind" "$@"; then
			action_status "$id" error 'Unable to start background action.'
			die 'Unable to start background action'
		fi
	else
		setsid "$0" _action-run "$id" "$kind" "$@" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$id"
}

# Tunnel quality marks. An action says itself when it ran, so the quality
# sampler can tell a planned interruption from a fault instead of inferring it
# from other state files afterwards. Lines are
#   <time> begin|end|event <kind> <manual|auto> <pid> <detail>
# and every writer holds the lock, because the sampler trims the file.
quality_marks_file="${IKEV2_QUALITY_DIR:-/var/run/ikev2-quality}/marks"

quality_mark() {
	local detail
	mkdir -p "${quality_marks_file%/*}" 2>/dev/null || return 0
	detail="$(printf '%s' "${4:--}" | tr -c 'A-Za-z0-9._:/@=+-' '_')"
	(
		flock -x 9 || exit 0
		printf '%s %s %s %s %s %s\n' "$(date +%s)" "$1" "$2" "$3" "$$" "$detail" \
			>>"$quality_marks_file"
	) 9>>"${quality_marks_file}.lock" 2>/dev/null || :
	return 0
}

# Called by an action runner once it holds the router action lock. An action
# that can interrupt the tunnel or forwarding opens a maintenance window, and
# quality_action_end closes it from the runner's EXIT trap, so a failed action
# closes it too. An action that cannot interrupt them is only an event.
quality_action_begin() {
	quality_action_kind="$1"
	case "$1" in
		set | coverage-add | coverage-remove | device | pbr-restart | apply | \
		connect | client-connect | advanced-set | advanced-reset | server-apply)
			quality_action_window=1
			quality_mark begin "$1" manual
			;;
		recover-reliable | routing-pause | routing-resume)
			quality_action_window=0
			;;
		*)
			quality_action_kind=''
			;;
	esac
}

quality_action_end() {
	[ -n "${quality_action_kind:-}" ] || return 0
	if [ "${quality_action_window:-0}" = 1 ]; then
		quality_mark end "$quality_action_kind" manual
	else
		quality_mark event "$quality_action_kind" manual
	fi
	quality_action_kind=''
}
