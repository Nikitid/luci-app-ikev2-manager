#!/bin/sh
# Read-only probes shared by the cron monitor and the short-outage recorder.

field() { sed -n "s/^$1=//p" | head -n 1; }

bounded() {
	local secs="$1" pid watchdog rc=0
	shift
	"$@" &
	pid=$!
	( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
	watchdog=$!
	wait "$pid" 2>/dev/null || rc=$?
	kill "$watchdog" 2>/dev/null || :
	wait "$watchdog" 2>/dev/null || :
	return "$rc"
}

resolve() {
	bounded 3 nslookup "$1" "$2" 2>/dev/null |
		awk '/^Name:/ { n = 1 } n && /^Address/ && $NF !~ /:/ { print $NF; exit }'
}

# Require a complete, successful trace response. Retry one failed request;
# an HTTP error page or a truncated body must not become an exit address.
trace() {
	local host="$1" link="${2:-}" attempt body result rc
	for attempt in 1 2; do
		rc=0
		body=$(curl -4fsS --noproxy '*' --connect-timeout 3 --max-time 8 \
			${link:+--interface "$link"} "https://$host/cdn-cgi/trace" 2>/dev/null) || rc=$?
		result=$(printf '%s\n' "$body" | awk -F= '
			$1=="ip" { n=split($2,a,"."); valid=(n==4); for(i=1;i<=n;i++) if(a[i] !~ /^[0-9]+$/ || a[i]+0>255) valid=0; if(valid) ip=$2 }
			$1=="loc" && $2 ~ /^[A-Z][A-Z]$/ { loc=$2 }
			END { if (ip != "" && loc != "") print ip " " loc }')
		if [ "$rc" = 0 ] && [ -n "$result" ]; then
			printf '%s\n' "$result"
			return 0
		fi
		[ "$attempt" = 2 ] || sleep 1
	done
	return 1
}

# A failed FakeIP request alone says nothing about route leakage. Exercise
# the configured DoH resolver and HTTPS through the tunnel independently.
trace_failure() {
	local host="$1" endpoint="$2" link="${3:-ipsec-out}" rc=0
	case "$endpoint" in https://*) ;; *) printf 'HTTPS через FakeIP не ответил; причина DNS/HTTPS ещё не установлена'; return ;; esac
	curl -4fsS --noproxy '*' --interface "$link" --doh-url "$endpoint" \
		--connect-timeout 3 --max-time 8 -o /dev/null \
		"https://$host/cdn-cgi/trace" 2>/dev/null || rc=$?
	case "$rc" in
		0) printf 'HTTPS через FakeIP не ответил, независимый DNS+HTTPS через туннель работает' ;;
		6) printf 'DNS через туннель не разрешил имя; маршрут этим сбоем не проверен' ;;
		*) printf 'DNS+HTTPS через туннель не ответил (curl=%s); утечка маршрута не доказана' "$rc" ;;
	esac
}
