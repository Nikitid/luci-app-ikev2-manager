#!/bin/sh
# The office board's page and request form on the real uhttpd: a request with
# a screenshot is kept, listed without who sent it, and an incomplete one is
# refused.
set -eu
fail() { printf 'board: %s\n' "$*" >&2; exit 1; }
uhttpd -f -h /tmp -p 127.0.0.1:18090 -o /board -O /usr/libexec/ikev2-manager.d/board-http.uc >/tmp/board-uhttpd.log 2>&1 &
board_pid=$!
trap 'kill "$board_pid" 2>/dev/null; rm -rf /etc/ikev2-manager/board /tmp/board-sent /tmp/board-uhttpd.log' EXIT
tries=0
until curl -fsS -o /dev/null http://127.0.0.1:18090/board 2>/dev/null; do
	tries=$((tries + 1))
	[ "$tries" -lt 20 ] || fail "uhttpd did not start: $(cat /tmp/board-uhttpd.log)"
	sleep 1
done
curl -fsS http://127.0.0.1:18090/board | grep -q '<form id="form">' || fail 'the page was not served'
# The first bytes of a PNG and a word, as base64.
png=iVBORw0KGgpmYWtl
curl -fsS -o /tmp/board-sent -H 'Content-Type: application/json' \
	--data "{\"name\":\"N\",\"resource\":\"example.com\",\"problem\":\"p\",\"pictures\":[\"$png\"]}" \
	http://127.0.0.1:18090/board/requests || fail 'a request was refused'
board_id="$(jsonfilter -i /tmp/board-sent -e '@.id')"
[ -f "/etc/ikev2-manager/board/requests/$board_id.json" ] && [ -f "/etc/ikev2-manager/board/requests/$board_id.1.png" ] ||
	fail 'the request or its screenshot was not kept'
curl -fsS http://127.0.0.1:18090/board/requests | grep -q "\"$board_id\"" || fail 'the request is not listed'
! curl -fsS http://127.0.0.1:18090/board/requests | grep -q '"name"' || fail 'the public list shows who asked'
if curl -fsS -o /dev/null --data '{"name":"N"}' http://127.0.0.1:18090/board/requests; then fail 'an incomplete request was kept'; fi
printf '%s\n' 'board page tests OK'
