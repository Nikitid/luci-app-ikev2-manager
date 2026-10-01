#!/bin/sh
#
# Read-only sweep across routers: version, service health, WAN, DNS, tunnel,
# and whether the page's own rpcd writes are permitted.
#
# Changes nothing. Nothing here restarts a service, edits UCI or touches the
# tunnel - a diagnostic that applies a setting is how a config gets changed by
# accident.
#
# Usage: scripts/health-check.sh host [host...]

set -eu

port="${IKEV2_SSH_PORT:-1111}"
[ $# -gt 0 ] || { printf 'Usage: %s host [host...]\n' "$0" >&2; exit 1; }

probe='
printf "version=%s " "$(cat /usr/share/ikev2-manager/version 2>/dev/null || echo unknown)"
/usr/libexec/ikev2-manager-system doctor-ui 2>/dev/null |
	grep -E "^(doctor_ok|dependencies_ok|dns_segments)=" | tr "\n" " "
/usr/libexec/ikev2-manager-system get 2>/dev/null | grep -E "^routing_paused=" | tr "\n" " "
/usr/libexec/ikev2-domain-router status 2>/dev/null |
	grep -E "^(service|healthy)=" | tr "\n" " "
printf "sas=%s " "$(swanctl --list-sas 2>/dev/null | grep -c ESTABLISHED)"
printf "loss=%s " "$(ping -c 3 -W 2 -q 1.1.1.1 2>/dev/null |
	sed -n "s/.* \([0-9]*\)% packet loss.*/\1%/p")"
printf "dns=%s " "$(nslookup example.com 127.0.0.1 2>/dev/null |
	awk "/^Name:/{n=1} n && /^Address/{a=\$NF} END{print (a==\"\"?\"FAIL\":\"ok\")}")"
printf "mem_free=%sM " "$(( $(free | awk "/Mem/{print \$4}") / 1024 ))"
printf "errors=%s " "$(logread -l 2000 2>/dev/null |
	grep -icE "error|fail|panic|crash|oom|segfault")"
printf "respawn=%s " "$(logread -l 2000 2>/dev/null |
	grep -icE "respawn|oom-killer|segfault|kernel panic")"
echo
'

for host in "$@"; do
	printf '%-16s ' "$host"
	ssh -o ConnectTimeout=10 -p "$port" "root@$host" "$probe" 2>&1 || printf 'UNREACHABLE\n'
done
