#!/bin/sh
# The services board: a page on the local network that shows which services go
# through the tunnel, with their domains, and takes requests about a service
# that does not open. Requests are kept on this router; the owner hears of each
# one in Telegram, and an agent works on them over a restricted SSH key.
#
#   ikev2-board serve          the page (run by the init script)
#   ikev2-board snapshot       services and their domains, for the page
#   ikev2-board icons          each service's icon from its own site
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
exits_file="${IKEV2_EXITS_FILE:-/etc/pbr-ikev2-exits.txt}"
tunnel_state="${IKEV2_TUNNEL_STATE:-/var/run/ikev2-tunnels.state}"
manager="${IKEV2_MANAGER:-/usr/libexec/ikev2-manager}"
tunnels=''
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

# Whether the tunnel a service leaves through is up: its exit from the exits
# list (the first exit when it has none), the tunnel carrying that exit from
# the watcher's state, and that tunnel's state now.
service_up() {
	local exit tunnel
	exit="$(awk -v id="$1" '$1 == id { print $2; exit }' "$exits_file" 2>/dev/null)"
	tunnel="$(awk -v want="${exit:-1}" '$1 == "exit" && $2 == want { print $3; exit }' "$tunnel_state" 2>/dev/null)"
	printf '%s\n' "$tunnels" | grep -q "^tunnel=${tunnel:-1} up=1 "
}

# The selected services, each with its domains and whether its tunnel is up,
# and the operator's own domains. Read from the lists the routing already
# uses; nothing is fetched that the router does not fetch anyway.
snapshot() {
	local work service label first=1 records up any=false
	mkdir -p "$run_dir" || return 1
	work="$(mktemp -d)" || return 1
	records="$("$community" services 2>/dev/null)"
	tunnels="$("$manager" tunnels-status 2>/dev/null)"
	printf '%s\n' "$tunnels" | grep -q ' up=1 ' && any=true
	{
		printf '{"updated":%s,"tunnel":%s,"services":[' "$(date +%s)" "$any"
		for service in $(sed -n 's/^[ \t]*\([a-z0-9_.-]\{1,64\}\)[ \t]*$/\1/p' "$selected_file" 2>/dev/null); do
			label="$(printf '%s\n' "$records" | awk -F'|' -v id="$service" '$1 == id { print $2; exit }')"
			"$community" service-read "$service" >"$work/read" 2>/dev/null || :
			[ "$first" = 1 ] || printf ','
			first=0
			up=false
			service_up "$service" && up=true
			printf '{"id":%s,"label":%s,"up":%s,"domains":[' "$(json_string "$service")" "$(json_string "${label:-$service}")" "$up"
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
	# Icons come later, in the background: the page shows initials meanwhile.
	[ "${IKEV2_BOARD_ICONS:-1}" = 0 ] || ( icons >/dev/null 2>&1 & )
}

# The domain that stands for a service on the page: the one named like the
# service (openai.com for OpenAI), else the shortest.
icon_domain() {
	local id="$1" label="$2" word
	word="$(printf '%s' "$label" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
	awk -v word="$word" -v id="$(printf '%s' "$id" | tr -cd 'a-z0-9')" '
		/^[a-z0-9.-]+\.[a-z]+$/ {
			split($1, parts, "."); name = parts[length(parts) - 1]
			score = (name == word || name == id) ? 0 : (index(word, name) || index(id, name)) ? 1 : 2
			if (best == "" || score < bestscore || (score == bestscore && length($1) < length(best))) { best = $1; bestscore = score }
		}
		END { print best }'
}

# Each service's own icon, fetched from its site the way any traffic goes and
# kept for a week: no list of anyone's services leaves for an icon service.
# Only PNG, ICO, JPEG and GIF are kept, at most 64 KB; SVG never, since it can
# carry script. A service without one shows its initials.
icons() {
	local dir="$run_dir/icons" service label domain url file kind now
	mkdir -p "$dir" || return 1
	now="$(date +%s)"
	jsonfilter -i "$run_dir/services.json" -e '@.services[*].id' 2>/dev/null | while IFS= read -r service; do
		valid_service "$service" || continue
		for file in "$dir/$service".*; do
			[ -e "$file" ] || continue
			[ $((now - $(date -r "$file" +%s 2>/dev/null || echo 0))) -lt 604800 ] && continue 2
		done
		label="$(jsonfilter -i "$run_dir/services.json" -e "@.services[@.id='$service'].label" 2>/dev/null)"
		domain="$(jsonfilter -i "$run_dir/services.json" -e "@.services[@.id='$service'].domains[*]" 2>/dev/null | icon_domain "$service" "$label")"
		[ -n "$domain" ] || continue
		rm -f "$dir/$service".*
		for url in $(icon_urls "$domain") "https://$domain/favicon.ico" "https://www.$domain/favicon.ico"; do
			curl -fsL --max-time 8 --max-filesize 65536 -o "$dir/$service.tmp" "$url" 2>/dev/null || continue
			kind="$(head -c 4 "$dir/$service.tmp" | od -An -tx1 | tr -d ' \n')"
			case "$kind" in
				89504e47) mv "$dir/$service.tmp" "$dir/$service.png"; break ;;
				00000100) mv "$dir/$service.tmp" "$dir/$service.ico"; break ;;
				ffd8ff*) mv "$dir/$service.tmp" "$dir/$service.jpg"; break ;;
				47494638) mv "$dir/$service.tmp" "$dir/$service.gif"; break ;;
			esac
		done
		rm -f "$dir/$service.tmp"
		# A site without an icon is not asked again for a week.
		ls "$dir/$service".* >/dev/null 2>&1 || : >"$dir/$service.none"
	done
}

# The icons a site's own page names, the touch icon first: most sites keep
# theirs at a path of their choosing rather than at /favicon.ico.
icon_urls() {
	local domain="$1" base
	for base in "https://$domain" "https://www.$domain"; do
		curl -fsL --max-time 8 --max-filesize 524288 -A 'Mozilla/5.0' "$base/" 2>/dev/null |
			tr '\n' ' ' | grep -oiE '<link[^>]+>' |
			awk -v base="$base" '
				{ tag = tolower($0) }
				tag !~ /rel="?(apple-touch-icon|shortcut icon|icon)/ || tag ~ /svg/ { next }
				match($0, /[Hh][Rr][Ee][Ff]="[^"]+"/) {
					href = substr($0, RSTART + 6, RLENGTH - 7)
					if (href ~ /^\/\//) href = "https:" href
					else if (href ~ /^\//) href = base href
					else if (href !~ /^https?:\/\//) href = base "/" href
					print (tag ~ /apple-touch-icon/ ? 0 : 1), href
				}' | sort -n | cut -d' ' -f2- | head -n 3
	done | awk '!seen[$0]++' | head -n 4
}

valid_service() {
	case "$1" in '' | *[!a-z0-9_.-]*) return 1 ;; esac
	[ "${#1}" -le 64 ]
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

# One message in the group chat lists the open requests; the bot edits it in
# place, and posts and pins a new one the first time.
pin() {
	local chat text message reply
	chat="$(setting group_chat)"
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
	icons) icons ;;
	notify) notify "${2:-}" ;;
	pin) pin ;;
	agent) agent ;;
	*) die 'Usage: ikev2-board {serve|snapshot|icons|notify ID|pin|agent}' ;;
esac
