#!/bin/sh
# Bounded, read-only network history in RAM. Run by network-recorder.init.
set -u
umask 077
base="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$base/kuma-probes.sh"
dir="${NETWORK_HISTORY_DIR:-/tmp/ikev2-network}"
mkdir -p "$dir"
chmod 700 "$dir"

# One writer for each ring; rename keeps readers on a complete snapshot.
record() {
	local file="$1" keep="$2"
	shift 2
	printf '%s %s\n' "$(date +%s)" "$*" >>"$dir/$file"
	if [ "$(wc -l <"$dir/$file")" -gt "$keep" ]; then
		tail -n "$keep" "$dir/$file" >"$dir/$file.new" && mv "$dir/$file.new" "$dir/$file"
	fi
}

path_probe() {
	local link="$1" target
	for target in 1.1.1.1 8.8.8.8; do
		if ping -4 -c 1 -W 1 -w 2 -I "$link" "$target" >/dev/null 2>&1; then
			printf '%s=up\n' "$link"
			return
		fi
	done
	printf '%s=no-icmp\n' "$link"
}

paths() {
	local wan link result
	wan=$(ip -4 route show table main default | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
	[ -z "$wan" ] || path_probe "$wan" >"$dir/path-wan.$$" &
	for link in /sys/class/net/ipsec-out*; do
		[ -e "$link" ] || continue
		path_probe "${link##*/}" >"$dir/path-${link##*/}.$$" &
	done
	wait
	result=$(cat "$dir"/path-*.$$ 2>/dev/null | tr '\n' ' ')
	rm -f "$dir"/path-*.$$
	record paths.log 17280 "paths ${result:-no-default-or-tunnel}"
}

applications() {
	local dns fakeip wan endpoint sa
	dns=$(resolve example.com 127.0.0.1)
	fakeip=$(trace chatgpt.com) || fakeip=failed
	wan=$(ip -4 route show table main default | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')
	if [ -n "$wan" ]; then wan=$(trace www.cloudflare.com "$wan") || wan=failed; else wan=no-default; fi
	endpoint=$(sed -n 's/^selected=//p' /var/run/ikev2-tunnel-dns.state 2>/dev/null | tail -n 1)
	sa=$(/usr/libexec/ikev2-sa tunnels 2>/dev/null | tr '\n' ';')
	record applications.log 2880 "applications dns=${dns:-failed} selected_https=$fakeip wan_https=$wan tunnel_dns=$endpoint sas=$sa"
}

case "${1:-}" in
	paths) exec 9>"$dir/paths.lock"; flock 9 || exit 1; while :; do paths; sleep 5 9>&-; done ;;
	applications) exec 9>"$dir/applications.lock"; flock 9 || exit 1; while :; do applications; sleep 30 9>&-; done ;;
	paths-once) paths ;;
	once) paths; applications ;;
	*) printf 'Usage: network-recorder.sh {paths|applications|paths-once|once}\n' >&2; exit 1 ;;
esac
