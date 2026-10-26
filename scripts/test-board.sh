#!/bin/sh
# The services board's executor: the agent's key may only name the actions it
# allows, a request id cannot reach outside the request store, a status change
# is kept, and added domains are staged the way the Policy Routing page stages
# them.
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { printf 'board: %s\n' "$*" >&2; exit 1; }
helper="$tmp/ikev2-board"
sed '/^if \[ -e \/usr\/share\/ikev2-manager\/version \]; then$/,/^fi$/d' \
	"$root/ikev2-manager-runtime/ikev2-board.sh" >"$helper"
! grep -q '/usr/share/ikev2-manager/version' "$helper" || fail 'the installed-package guard was not taken out of the copy'

mkdir -p "$tmp/bin" "$tmp/board/requests"
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$tmp/bin/community" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$tmp/community'
case "\$1" in
	name-trace) printf 'name=%s\nexit=1\n' "\$2" ;;
	schedule) [ -f "$tmp/input-\$2.domains" ] && [ -f "$tmp/input-\$2.cidrs" ] && [ -f "$tmp/input-\$2.services" ] ;;
esac
EOF
chmod 755 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" IKEV2_BOARD_DIR="$tmp/board" IKEV2_BOARD_RUN="$tmp/run" IKEV2_COMMUNITY="$tmp/bin/community" \
	IKEV2_MANUAL_FILE="$tmp/manual" IKEV2_MANUAL_CIDR_FILE="$tmp/cidrs" IKEV2_SELECTED_FILE="$tmp/selected" \
	IKEV2_INPUT_PREFIX="$tmp/input" IKEV2_BOARD_ICONS=0
agent() { SSH_ORIGINAL_COMMAND="$*" sh "$helper" agent; }

id=1792664445-68c9b1b2ad23
printf '{ "id": "%s", "created": 1, "status": "new", "note": "", "resource": "example.com" }\n' "$id" >"$tmp/board/requests/$id.json"
printf 'secret\n' >"$tmp/board/telegram.token"
printf '{"secret": 1}\n' >"$tmp/board/secret.json"

# Only the actions the key allows.
for refused in 'cat /etc/shadow' 'sh -c id' "show ../telegram.token" "show ../secret" 'show' "picture $id 9" 'trace a;b' "status $id deleted" 'add-domains not_a_domain'; do
	if agent "$refused" >"$tmp/out" 2>&1; then fail "allowed: $refused"; fi
	! grep -q secret "$tmp/out" || fail "leaked the token: $refused"
done

agent list | grep -q "\"id\": \"$id\"" || fail 'the list misses the request'
agent "status $id working checking it now"
agent "show $id" | grep -q '"status": "working"' || fail 'the status was not kept'
agent "show $id" | grep -q '"note": "checking it now"' || fail 'the note was not kept'
agent 'trace claude.ai' | grep -qx 'name=claude.ai' || fail 'the trace was not run'

# Domains are added to the operator's list as a whole staged input.
printf 'one.example\n' >"$tmp/manual"
printf 'svc\n' >"$tmp/selected"
: >"$tmp/cidrs"
agent 'add-domains two.example three.example' || fail 'adding domains failed'
staged="$(sed -n 's/^schedule //p' "$tmp/community")"
[ -n "$staged" ] || fail 'nothing was scheduled'
[ "$(tr '\n' ' ' <"$tmp/input-$staged.domains")" = 'one.example two.example three.example ' ] || fail 'the staged list is not the old one plus the new names'
[ "$(cat "$tmp/input-$staged.services")" = svc ] || fail 'the selected services were not carried over'

# The page says which services work now: a service is up when the tunnel
# carrying its exit is, and one without an exit of its own uses the first.
cat >"$tmp/bin/manager" <<'EOF'
#!/bin/sh
printf 'tunnel=1 up=1 address=10.0.0.2 carries=1\ntunnel=2 up=0 address= carries=2\n'
EOF
cat >>"$tmp/bin/community" <<'EOF'
case "$1" in
	services) printf 'chat|Chat\nmail|Mail\n' ;;
	service-read) printf -- '---domains---\n%s.example\n---end---\n' "$2" ;;
esac
EOF
chmod 755 "$tmp/bin/manager"
printf 'chat\nmail\n' >"$tmp/selected"
printf 'mail 2\n' >"$tmp/exits"
printf 'exit 1 1\nexit 2 2\n' >"$tmp/state"
IKEV2_MANAGER="$tmp/bin/manager" IKEV2_EXITS_FILE="$tmp/exits" IKEV2_TUNNEL_STATE="$tmp/state" sh "$helper" snapshot ||
	fail 'the snapshot failed'
ucode -e 'import { readfile } from "fs";
	let value = json(readfile(ARGV[0])), up = {};
	for (let service in value.services) up[service.id] = service.up;
	if (value.tunnel !== true || up.chat !== true || up.mail !== false || value.services[0].domains[0] != "chat.example") exit(1);' \
	-- "$tmp/run/services.json" || fail "the snapshot does not say which services work: $(cat "$tmp/run/services.json")"
printf '%s\n' 'board tests OK'
