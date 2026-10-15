#!/bin/sh
# A problem report from the router: what reaches the report service, in which
# order, and what the router keeps. The service is a recorder that answers as
# the API contract says; the router side runs as installed.
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { printf 'report send: %s\n' "$*" >&2; exit 1; }
command -v ucode >/dev/null 2>&1 || fail 'ucode is required'
command -v jsonfilter >/dev/null 2>&1 || {
	# jsonfilter is OpenWrt's; this reads the two forms the helper uses.
	cat >"$tmp/jsonfilter" <<'EOF'
#!/bin/sh
if [ "$1" = -i ]; then src="$(cat "$2")"; else src="$2"; fi
path="${4#@.}"
printf '%s' "$src" | ucode -e 'import { stdin } from "fs"; let v = json(stdin.read("all")); for (let k in split(ARGV[0], ".")) v = v?.[k]; if (v == null) exit(1); print(type(v) == "string" ? v : sprintf("%J", v), "\n");' "$path"
EOF
	chmod 755 "$tmp/jsonfilter"
}
PATH="$tmp:$PATH"

# The recorder: one line per request, "METHOD PATH bearer=<yes|no>", the body
# of each request kept by its order, and the answers of the contract.
cat >"$tmp/curl" <<'EOF'
#!/bin/sh
method=GET out='' body='' bearer=no url='' headers=''
while [ $# -gt 0 ]; do
	case "$1" in
		-X) method="$2"; shift ;;
		-o) out="$2"; shift ;;
		-H) case "$2" in "Authorization: Bearer "*) bearer=yes ;; esac; headers="$headers|$2"; shift ;;
		--data-binary) body="${2#@}"; shift ;;
		-w|-m) shift ;;
		-*) ;;
		*) url="$1" ;;
	esac
	shift
done
path="${url#https://reports.example}"
n=$(($(wc -l <"$REC/log" 2>/dev/null || echo 0) + 1))
printf '%s %s bearer=%s\n' "$method" "$path" "$bearer" >>"$REC/log"
[ -z "$body" ] || cp "$body" "$REC/body.$n"
printf '%s\n' "$headers" >"$REC/headers.$n"
[ ! -e "$REC/down" ] || { printf '000'; exit 7; }
case "$method $path" in
	"POST /api/v1/reports") code=201; printf '{"id":"rep_1","state":"draft"}' >"$out" ;;
	"POST /api/v1/reports/rep_1/attachments") code=201; printf '{"id":"att_1","upload_url":"/api/v1/uploads/att_1"}' >"$out" ;;
	"POST /api/v1/uploads/") code=201; : >"$out" ;;
	"PATCH /api/v1/uploads/att_1") code=204; : >"$out" ;;
	"POST /api/v1/reports/rep_1/finalize") code=200; printf '{"id":"rep_1","state":"received"}' >"$out" ;;
	"GET /api/v1/reports/rep_1") code=200; printf '{"id":"rep_1","state":"in_progress","replies":[{"body":"Thanks, looking.","created_at":"2026-10-16T10:00:00Z"}]}' >"$out" ;;
	*) code=404; printf '{"error":"not_found"}' >"$out" ;;
esac
printf '%s' "$code"
EOF
chmod 755 "$tmp/curl"
REC="$tmp/rec"; mkdir -p "$REC"; export REC

sed -n '/^report_endpoint=/,$p' "$root/ikev2-manager-runtime/lib/system-report.sh" >"$tmp/report.sh"
statuses="$tmp/statuses"
action_status() { printf '%s %s %s\n' "$1" "$2" "$3" >>"$statuses"; }
diagnostics_report() { printf 'redacted state of <router>\n'; }
die() { printf '%s\n' "$*" >&2; exit 1; }
IKEV2_REPORT_ENDPOINT=https://reports.example; uci() { return 1; }
IKEV2_REPORT_DIR="$tmp/reports"
IKEV2_REPORT_CURL="$tmp/curl"
# shellcheck disable=SC1090
. "$tmp/report.sh"
report_input_file() { printf '%s/report-%s.in\n' "$tmp" "$1"; }
report_context_json() { printf '{"app_version":"2.3.0","os_version":"OpenWrt 25.12.5","architecture":"aarch64_cortex-a53"}'; }

stage() { printf '%s' "$2" >"$tmp/report-$1.in"; }
last() { tail -n 1 "$statuses"; }

# Text alone: one request that submits it, with no claim in a header, and the
# router keeps the claim, the client id and the report number.
stage t1 '{"version":1,"description":"Tunnel 2 drops every evening","contact":"","diagnostics":false}'
( report_send 1-1 t1 )
last | grep -q '^1-1 ok Report rep_1 sent\.$' || fail "text report not sent: $(last)"
[ "$(cat "$REC/log")" = 'POST /api/v1/reports bearer=yes' ] || fail "unexpected requests: $(cat "$REC/log")"
ucode -e 'import { readfile } from "fs"; let b = json(readfile(ARGV[0]));
	if (b.project != "ikev2-manager" || b.submit !== true || "contact" in b || b.description != "Tunnel 2 drops every evening" ||
	    !match(b.claim_token, /^[0-9a-f]{64}$/) || !match(b.client_id, /^[0-9a-f-]{36}$/) || b.context.app_version != "2.3.0") exit(1);' \
	"$REC/body.1" || fail "the report request is not what the contract asks: $(cat "$REC/body.1")"
record="$(ls "$tmp/reports"/*.json)"
[ "$(ls -l "$record" | cut -c1-10)" = '-rw-------' ] || fail 'the claim is readable by others'
[ "$(jsonfilter -i "$record" -e '@.report_id')" = rep_1 ] || fail 'the report number was not kept'
[ "$(jsonfilter -i "$record" -e '@.claim_token')" = "$(jsonfilter -i "$REC/body.1" -e '@.claim_token')" ] ||
	fail 'the kept claim is not the one sent'
[ ! -e "$tmp/report-t1.in" ] || fail 'the staged text was left behind'

# With the diagnostics report: create without submitting, register the file
# with its size and hash, upload it, finalize - every step with the claim.
rm -f "$REC"/*
stage t2 '{"version":1,"description":"Steam stalls","contact":"me@example.com","diagnostics":true}'
( report_send 2-1 t2 )
last | grep -q '^2-1 ok Report rep_1 sent\.$' || fail "report with diagnostics not sent: $(last)"
[ "$(cut -d' ' -f1,2 "$REC/log" | tr '\n' '|')" = 'POST /api/v1/reports|POST /api/v1/reports/rep_1/attachments|POST /api/v1/uploads/|PATCH /api/v1/uploads/att_1|POST /api/v1/reports/rep_1/finalize|' ] ||
	fail "the attachment did not follow the contract: $(cat "$REC/log")"
! grep -q 'bearer=no' "$REC/log" || fail 'a request went without the claim'
ucode -e 'import { readfile } from "fs"; let b = json(readfile(ARGV[0])); if ("submit" in b || b.contact != "me@example.com") exit(1);' "$REC/body.1" ||
	fail 'a report with an attachment was submitted before its file'
size="$(wc -c <"$REC/body.4" | tr -d ' ')"
ucode -e 'import { readfile } from "fs"; let b = json(readfile(ARGV[0]));
	if (b.filename != "ikev2-diagnostics.txt" || b.size != +ARGV[1] || !match(b.sha256, /^[0-9a-f]{64}$/)) exit(1);' "$REC/body.2" "$size" ||
	fail "the attachment was registered wrongly: $(cat "$REC/body.2")"
grep -q 'redacted state' "$REC/body.4" || fail 'the uploaded file is not the diagnostics report'
grep -q "Upload-Length: $size" "$REC/headers.3" && grep -q 'Upload-Metadata: attachment_id YXR0XzE=' "$REC/headers.3" ||
	fail 'the upload was not created for the registered attachment'

# The page's text is checked on the router; a refused one sends nothing.
rm -f "$REC"/*
for bad in '{"version":1,"description":"","contact":"","diagnostics":false}' \
	'{"version":1,"description":"x","contact":"not an address","diagnostics":false}' \
	'{"version":1,"description":"x","contact":"","diagnostics":"yes"}'; do
	stage t3 "$bad"
	if ( report_send 3-1 t3 ); then fail "accepted $bad"; fi
done
[ ! -s "$REC/log" ] || fail 'a refused report reached the service'

# A service that cannot be reached is said so.
touch "$REC/down"
stage t4 '{"version":1,"description":"x","contact":"","diagnostics":false}'
if ( report_send 4-1 t4 ); then fail 'an unreachable service was reported as sent'; fi
last | grep -q 'could not be reached' || fail "unreachable service not explained: $(last)"
rm -f "$REC/down"

# The reports sent are listed with their state and the replies, asked with the
# claim; the claim itself is not shown.
out="$(reports_list)"
printf '%s\n' "$out" | grep -q '"state": *"in_progress"' && printf '%s\n' "$out" | grep -q 'Thanks, looking.' ||
	fail "sent reports were not listed with their state and replies: $out"
! printf '%s\n' "$out" | grep -q claim || fail 'the list shows a claim'
# A router without a report service sends nothing and says so.
rm -f "$REC"/*
saved_endpoint="$report_endpoint"
report_endpoint=''
stage t5 '{"version":1,"description":"x","contact":"","diagnostics":false}'
if ( report_send 5-1 t5 ); then fail 'a report was sent without a service'; fi
last | grep -q 'No report service' || fail "a missing service was not explained: $(last)"
[ ! -s "$REC/log" ] || fail 'a request was made without a service'
[ "$(reports_list)" = '{"configured":false}' ] || fail 'the list did not say no service is set up'
report_endpoint="$saved_endpoint"
printf '%s\n' 'report send tests OK'
