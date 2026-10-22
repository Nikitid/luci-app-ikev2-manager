#!/bin/sh
# The office board: a page on the local network that shows which services go
# through the tunnel, with their domains, and takes requests about a service
# that does not open. Requests are kept on this router; the owner hears of each
# one in Telegram, and an agent works on them over a restricted SSH key.
#
#   ikev2-board serve          the page (run by the init script)
#   ikev2-board snapshot       services and their domains, for the page
#   ikev2-board notify ID      tell the owner about a new request
#   ikev2-board pin            refresh the pinned status message in the chat
#   ikev2-board agent          the forced command of the agent's SSH key
set -u
umask 077
if [ -e /usr/share/ikev2-manager/version ]; then
	PATH=/usr/sbin:/usr/bin:/sbin:/bin
	for ikev2_override in $(env | sed -n 's/^\(IKEV2_[A-Za-z0-9_]*\)=.*/\1/p'); do
		unset "$ikev2_override"
	done
fi
board_dir="${IKEV2_BOARD_DIR:-/etc/ikev2-manager/board}"
run_dir="${IKEV2_BOARD_RUN:-/var/run/ikev2-board}"
community="${IKEV2_COMMUNITY:-/usr/libexec/ikev2-domains-community}"
handler="${IKEV2_BOARD_HANDLER:-/usr/libexec/ikev2-manager.d/board-http.uc}"
requests="$board_dir/requests"
token_file="$board_dir/telegram.token"
manual_file="${IKEV2_MANUAL_FILE:-/etc/pbr-ikev2-domains.manual.txt}"
manual_cidr_file="${IKEV2_MANUAL_CIDR_FILE:-/etc/pbr-ikev2-addresses.manual.txt}"
selected_file="${IKEV2_SELECTED_FILE:-/etc/pbr-ikev2-community-selected.txt}"
input_prefix="${IKEV2_INPUT_PREFIX:-/tmp/ikev2-domains-input}"
telegram="${IKEV2_TELEGRAM_API:-https://api.telegram.org}"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

setting() {
	uci -q get "ikev2-manager.board.$1" 2>/dev/null
}

valid_id() {
	case "$1" in '' | *[!0-9a-f-]*) return 1 ;; esac
	[ "${#1}" -le 40 ]
}

json_string() {
	ucode -e 'print(sprintf("%J", ARGV[0]))' -- "$1" 2>/dev/null ||
		printf '"%s"' "$(printf '%s' "$1" | sed 's/["\\]/\\&/g')"
}

# The selected services, each with its domains, and the operator's own
# domains. Read from the lists the routing already uses; nothing is fetched
# that the router does not fetch anyway.
snapshot() {
	local work service label first=1 records
	mkdir -p "$run_dir" || return 1
	work="$(mktemp -d)" || return 1
	records="$("$community" services 2>/dev/null)"
	{
		printf '{"updated":%s,"services":[' "$(date +%s)"
		for service in $(sed -n 's/^[ \t]*\([a-z0-9_.-]\{1,64\}\)[ \t]*$/\1/p' "$selected_file" 2>/dev/null); do
			label="$(printf '%s\n' "$records" | awk -F'|' -v id="$service" '$1 == id { print $2; exit }')"
			"$community" service-read "$service" >"$work/read" 2>/dev/null || :
			[ "$first" = 1 ] || printf ','
			first=0
			printf '{"id":%s,"label":%s,"domains":[' "$(json_string "$service")" "$(json_string "${label:-$service}")"
			sed -n '/^---domains---$/,/^---/p' "$work/read" | sed '1d;/^---/d' | head -n 500 |
				awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $1 }'
			printf ']}'
		done
		printf '],"own":['
		head -n 500 "$manual_file" 2>/dev/null |
			awk '/^[a-z0-9._-]+$/ { printf "%s\"%s\"", (n++ ? "," : ""), $1 }'
		printf ']}\n'
	} >"$work/services.json" && mv "$work/services.json" "$run_dir/services.json"
	rm -rf "$work"
}

serve() {
	local port addresses address args www
	port="$(setting port)"
	case "$port" in '' | *[!0-9]*) port=8090 ;; esac
	# The local network only: the LAN address, never the WAN.
	addresses="$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][*].address' 2>/dev/null)"
	[ -n "$addresses" ] || die 'The board has no LAN address to listen on'
	www="$run_dir/www"
	mkdir -p "$www" "$requests" || die 'Unable to prepare the board'
	printf '<!doctype html><meta http-equiv="refresh" content="0; url=/board">\n' >"$www/index.html"
	args=''
	for address in $addresses; do args="$args -p $address:$port"; done
	snapshot || :
	# shellcheck disable=SC2086
	exec uhttpd -f -h "$www" $args -n 8 -N 32 -t 10 -T 10 -k 0 -o /board -O "$handler"
}

telegram_send() {
	local method="$1" body="$2" token
	[ -s "$token_file" ] || return 1
	token="$(cat "$token_file")"
	curl -fsS --max-time 15 -H 'Content-Type: application/json' -d "$body" "$telegram/bot$token/$method"
}

notify() {
	local id="$1" chat file resource problem name
	valid_id "$id" || die 'Expected a request id'
	file="$requests/$id.json"
	[ -f "$file" ] || die 'No such request'
	chat="$(setting owner_chat)"
	[ -n "$chat" ] || return 0
	resource="$(jsonfilter -i "$file" -e '@.resource' 2>/dev/null)"
	problem="$(jsonfilter -i "$file" -e '@.problem' 2>/dev/null | cut -c1-500)"
	name="$(jsonfilter -i "$file" -e '@.name' 2>/dev/null)"
	telegram_send sendMessage "{\"chat_id\":$(json_string "$chat"),\"text\":$(json_string "New request $id
From: $name
Resource: $resource
$problem")}" >/dev/null
	pin || :
}

# One message in the office chat lists the open requests; the bot edits it in
# place, and posts and pins a new one the first time.
pin() {
	local chat text message reply
	chat="$(setting office_chat)"
	[ -n "$chat" ] || return 0
	text="$(open_summary)"
	message="$(cat "$board_dir/pinned" 2>/dev/null)"
	if [ -n "$message" ] && telegram_send editMessageText "{\"chat_id\":$(json_string "$chat"),\"message_id\":$message,\"text\":$(json_string "$text")}" >/dev/null 2>&1; then
		return 0
	fi
	reply="$(telegram_send sendMessage "{\"chat_id\":$(json_string "$chat"),\"text\":$(json_string "$text")}")" || return 1
	message="$(printf '%s' "$reply" | jsonfilter -e '@.result.message_id' 2>/dev/null)"
	case "$message" in '' | *[!0-9]*) return 1 ;; esac
	printf '%s\n' "$message" >"$board_dir/pinned"
	telegram_send pinChatMessage "{\"chat_id\":$(json_string "$chat"),\"message_id\":$message,\"disable_notification\":true}" >/dev/null
}

open_summary() {
	local file count=0
	printf 'Requests\n'
	for file in $(ls -1t "$requests"/*.json 2>/dev/null | head -n 30); do
		case "$(jsonfilter -i "$file" -e '@.status' 2>/dev/null)" in
			done | rejected) continue ;;
		esac
		count=$((count + 1))
		printf '%s - %s\n' "$(jsonfilter -i "$file" -e '@.resource' 2>/dev/null | cut -c1-80)" \
			"$(jsonfilter -i "$file" -e '@.status' 2>/dev/null)"
	done
	[ "$count" -gt 0 ] || printf 'No open requests.\n'
}

set_status() {
	local id="$1" status="$2" note="$3" file
	valid_id "$id" || die 'Expected a request id'
	case "$status" in new | working | done | rejected) ;; *) die 'Expected new, working, done or rejected' ;; esac
	file="$requests/$id.json"
	[ -f "$file" ] || die 'No such request'
	ucode -e '
		import { readfile, writefile, rename } from "fs";
		let path = ARGV[0], request = json(readfile(path));
		request.status = ARGV[1];
		request.note = substr(ARGV[2], 0, 500);
		request.changed = time();
		writefile(path + ".new", sprintf("%J\n", request)) && rename(path + ".new", path) || exit(1);
	' -- "$file" "$status" "$note" || die 'Unable to change the request'
	pin || :
}

# Adds names to the operator's own list and applies it the way the Policy
# Routing page does.
add_domains() {
	local token kind name
	[ "$#" -gt 0 ] || die 'Expected domains'
	for name; do
		printf '%s\n' "$name" | grep -Eqx '[a-z0-9]([a-z0-9-]{0,62}\.)+[a-z]{2,63}' || die "Not a domain: $name"
	done
	token="board-$(date +%s)-$$"
	cat "$manual_file" 2>/dev/null >"$input_prefix-$token.domains"
	printf '%s\n' "$@" >>"$input_prefix-$token.domains"
	cat "$manual_cidr_file" 2>/dev/null >"$input_prefix-$token.cidrs"
	cat "$selected_file" 2>/dev/null >"$input_prefix-$token.services"
	"$community" schedule "$token"
}

# The agent's SSH key runs this and nothing else: SSH_ORIGINAL_COMMAND names
# one of the actions below.
agent() {
	local command="${SSH_ORIGINAL_COMMAND:-}" action id
	# shellcheck disable=SC2086
	set -f; set -- $command; set +f
	action="${1:-}"
	[ "$#" -eq 0 ] || shift
	case "$action" in
		list)
			printf '['
			ls -1t "$requests"/*.json 2>/dev/null | head -n 50 | while IFS= read -r file; do
				[ -n "${comma:-}" ] && printf ','
				comma=1
				cat "$file"
			done
			printf ']\n'
			;;
		show)
			valid_id "${1:-}" || die 'Expected a request id'
			cat "$requests/$1.json" || exit 1
			;;
		picture)
			valid_id "${1:-}" || die 'Expected a request id'
			case "${2:-}" in [1-5]) ;; *) die 'Expected a picture number' ;; esac
			for id in "$requests/$1.$2.png" "$requests/$1.$2.jpg"; do
				[ -f "$id" ] && { ucode -e 'import { readfile } from "fs"; print(b64enc(readfile(ARGV[0])))' -- "$id"; exit 0; }
			done
			die 'No such picture'
			;;
		services)
			snapshot && cat "$run_dir/services.json"
			;;
		trace)
			printf '%s\n' "${1:-}" | grep -Eqx '[a-z0-9.-]{1,253}' || die 'Expected a domain'
			"$community" name-trace "$1"
			;;
		status)
			[ "$#" -ge 2 ] || die 'Expected: status ID new|working|done|rejected [note]'
			id="$1" action="$2"
			shift 2
			set_status "$id" "$action" "$*"
			;;
		add-domains)
			add_domains "$@"
			;;
		*)
			die 'Allowed: list, show ID, picture ID N, services, trace DOMAIN, status ID STATE [NOTE], add-domains DOMAIN...'
			;;
	esac
}

case "${1:-}" in
	serve) serve ;;
	snapshot) snapshot ;;
	notify) notify "${2:-}" ;;
	pin) pin ;;
	agent) agent ;;
	*) die 'Usage: ikev2-board {serve|snapshot|notify ID|pin|agent}' ;;
esac
