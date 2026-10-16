#!/bin/sh
# Problem reports sent from the router to the report service, with the
# redacted diagnostics report attached when the administrator asks for it.
#
# Each report keeps its own random claim token: it is not an account and opens
# nothing but that report's status and the replies to it. The token, the
# client id and the service's report id are written before each request, so a
# send that was cut off is taken up again with the same values and returns the
# same report instead of a second one. Nothing is sent but what the page showed.

# Where reports go: the developer's report service unless the router names
# another (ikev2-manager.reports.endpoint), or names "none" to send nothing.
# Read with "|| true": this file is sourced by a helper that runs under set -e,
# and a router without the option must not lose every other command for it.
report_endpoint="${IKEV2_REPORT_ENDPOINT:-$(uci -q get ikev2-manager.reports.endpoint 2>/dev/null || true)}"
[ -n "$report_endpoint" ] || report_endpoint=https://reports.nikitid.ru
report_project="${IKEV2_REPORT_PROJECT:-ikev2-manager}"
report_dir="${IKEV2_REPORT_DIR:-/etc/ikev2-manager/reports}"
report_curl="${IKEV2_REPORT_CURL:-curl}"
report_ucode="${IKEV2_UCODE:-ucode}"

# Whether this router has a report service, as an https:// address.
report_configured() {
	case "$report_endpoint" in https://[A-Za-z0-9]*) ;; *) return 1 ;; esac
	case "$report_endpoint" in *[!A-Za-z0-9.:/_-]* | */) return 1 ;; esac
}

report_input_file() {
	case "$1" in '' | *[!A-Za-z0-9-]*) die 'Invalid report input token' ;; esac
	printf '/tmp/ikev2-manager-report-%s.in\n' "$1"
}

# One request to the service, in this shell: the status code goes to
# $report_status and the body to $report_response. METHOD PATH [CLAIM] [BODY-FILE] [extra curl arguments...]
report_request() {
	local method="$1" path="$2" claim="$3" body="$4" out
	shift 4
	out="$(mktemp)" || return 1
	set -- -sS -m 60 -o "$out" -w '%{http_code}' -X "$method" \
		-H 'Cache-Control: no-store' "$@"
	[ -z "$claim" ] || set -- "$@" -H "Authorization: Bearer $claim"
	[ -z "$body" ] || set -- "$@" --data-binary "@$body"
	report_status="$("$report_curl" "$@" "$report_endpoint/$path" 2>/dev/null)" || report_status=000
	report_response="$(cat "$out" 2>/dev/null)"
	rm -f "$out"
}

report_value() {
	jsonfilter -s "$1" -e "@.$2" 2>/dev/null
}

# What the service is told about the router besides the text: versions and
# architecture, nothing that names it.
report_context_json() {
	local version release arch
	version="$(apk list -I luci-app-ikev2-manager 2>/dev/null | sed -n 's/^luci-app-ikev2-manager-\([^ ]*\) .*/\1/p' | head -n 1)"
	[ -n "$version" ] || version="$(opkg list-installed luci-app-ikev2-manager 2>/dev/null | sed -n 's/^luci-app-ikev2-manager - //p' | head -n 1)"
	release="$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'$/\1/p" /etc/openwrt_release 2>/dev/null)"
	arch="$(sed -n "s/^DISTRIB_ARCH='\(.*\)'$/\1/p" /etc/openwrt_release 2>/dev/null)"
	"$report_ucode" -e 'print(sprintf("%J", { app_version: ARGV[0], os_version: "OpenWrt " + ARGV[1], architecture: ARGV[2] }))' \
		"${version:-unknown}" "${release:-unknown}" "${arch:-unknown}"
}

# Send the report the page staged under TOKEN. Runs as a background job and
# reports progress under action id ID.
report_send() {
	local id="$1" token="$2" input record work description contact attach client claim report response
	local file size sum attachment upload
	input="$(report_input_file "$token")"
	[ -f "$input" ] && [ ! -L "$input" ] || { action_status "$id" error 'The report text is missing.'; return 1; }
	report_configured || { rm -f "$input"; action_status "$id" error 'No report service is set up on this router.'; return 1; }
	work="$(mktemp -d)" || return 1
	# Runs in a process of its own: what it fetched and wrote goes with it.
	report_work="$work"
	trap 'rm -rf "${report_work:-}"' EXIT
	# The page's input is checked here, not trusted: the service refuses the
	# rest, but nothing it would refuse is sent.
	if ! "$report_ucode" -e '
		import { readfile } from "fs";
		let r = json(readfile(ARGV[0]));
		let line = function(v) {
			if (type(v) != "string") return false;
			for (let i = 0; i < length(v); i++) {
				let c = ord(v, i);
				if ((c < 32 && c != 9 && c != 10 && c != 13) || c == 127) return false;
			}
			return true;
		};
		if (type(r) != "object" || r.version !== 1 || !line(r.description) || length(trim(r.description)) < 1 ||
		    length(r.description) > 20000 || !(r.contact === "" || (line(r.contact) && length(r.contact) <= 254 &&
		    match(r.contact, /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$/))) || type(r.diagnostics) != "bool")
			exit(1);
		print(sprintf("%J", r));' "$input" >"$work/input.json" 2>/dev/null; then
		rm -f "$input"
		action_status "$id" error 'The report was refused: describe the problem, and give a valid e-mail address or none.'
		return 1
	fi
	rm -f "$input"
	description="$(jsonfilter -i "$work/input.json" -e '@.description')"
	contact="$(jsonfilter -i "$work/input.json" -e '@.contact')"
	attach="$(jsonfilter -i "$work/input.json" -e '@.diagnostics')"

	mkdir -p "$report_dir" && chmod 700 "$report_dir" || return 1
	# A UUID v4 for the report, from the same random source as its claim.
	client="$("$report_ucode" -e 'import { open } from "fs"; let f = open("/dev/urandom"), b = f.read(16), h = ""; f.close();
		for (let i = 0; i < 16; i++) { let c = ord(b, i); if (i == 6) c = (c & 15) | 64; if (i == 8) c = (c & 63) | 128; h += sprintf("%02x", c); }
		print(substr(h, 0, 8), "-", substr(h, 8, 4), "-", substr(h, 12, 4), "-", substr(h, 16, 4), "-", substr(h, 20));')"
	claim="$("$report_ucode" -e 'import { open } from "fs"; let f = open("/dev/urandom"), b = f.read(32), h = ""; f.close();
		for (let i = 0; i < length(b); i++) h += sprintf("%02x", ord(b, i)); print(h);')"
	case "$client" in ????????-????-4???-[89ab]???-????????????) ;; *) action_status "$id" error 'Could not make an identity for the report.'; return 1 ;; esac
	[ "${#claim}" = 64 ] || { action_status "$id" error 'Could not make an identity for the report.'; return 1; }
	record="$report_dir/$client.json"
	report_record "$record" "$client" "$claim" '' "$(date +%s)" "$description"

	action_status "$id" running 'Sending the report...'
	# Without an attachment the report is submitted in this one request.
	"$report_ucode" -e 'let r = { project: ARGV[0], client_id: ARGV[1], claim_token: ARGV[2],
		description: ARGV[3], context: json(ARGV[5]) };
		if (ARGV[4] != "") r.contact = ARGV[4];
		if (ARGV[6] != "true") r.submit = true;
		print(sprintf("%J", r));' \
		"$report_project" "$client" "$claim" "$description" "$contact" "$(report_context_json)" "$attach" \
		>"$work/create.json" || return 1
	report_request POST api/v1/reports "$claim" "$work/create.json" -H 'Content-Type: application/json'; response="$report_response"
	case "$report_status" in 200 | 201) ;; *) report_failed "$id" "$report_status" "$response"; return 1 ;; esac
	report="$(report_value "$response" id)"
	case "$report" in '' | *[!A-Za-z0-9_-]*) action_status "$id" error 'The service gave no report number.'; return 1 ;; esac
	report_record "$record" "$client" "$claim" "$report" "$(date +%s)" "$description"

	if [ "$attach" = true ]; then
		action_status "$id" running 'Attaching the diagnostics report...'
		file="$work/ikev2-diagnostics.txt"
		diagnostics_report >"$file" 2>/dev/null || { action_status "$id" error 'Could not collect the diagnostics report.'; return 1; }
		size="$(wc -c <"$file" | tr -d ' ')"
		sum="$(sha256sum "$file" | cut -d' ' -f1)"
		"$report_ucode" -e 'print(sprintf("%J", { filename: "ikev2-diagnostics.txt", content_type: "text/plain", size: +ARGV[0], sha256: ARGV[1] }))' \
			"$size" "$sum" >"$work/attach.json"
		report_request POST "api/v1/reports/$report/attachments" "$claim" "$work/attach.json" -H 'Content-Type: application/json'; response="$report_response"
		case "$report_status" in 200 | 201) ;; *) report_failed "$id" "$report_status" "$response"; return 1 ;; esac
		attachment="$(report_value "$response" id)"
		case "$attachment" in '' | *[!A-Za-z0-9_-]*) action_status "$id" error 'The service gave no attachment number.'; return 1 ;; esac
		upload="api/v1/uploads/$attachment"
		# Created once; a creation that already happened answers 409, and the
		# upload then goes on from the offset the service holds.
		report_request POST api/v1/uploads/ "$claim" '' -H 'Tus-Resumable: 1.0.0' \
			-H "Upload-Length: $size" -H "Upload-Metadata: attachment_id $("$report_ucode" -e 'print(b64enc(ARGV[0]))' "$attachment")" >/dev/null
		case "$report_status" in 201 | 409) ;; *) report_failed "$id" "$report_status" ''; return 1 ;; esac
		report_request PATCH "$upload" "$claim" "$file" -H 'Tus-Resumable: 1.0.0' -H 'Upload-Offset: 0' \
			-H 'Content-Type: application/offset+octet-stream' >/dev/null
		case "$report_status" in 204 | 409) ;; *) report_failed "$id" "$report_status" ''; return 1 ;; esac
		printf '{}' >"$work/empty.json"
		report_request POST "api/v1/reports/$report/finalize" "$claim" "$work/empty.json" -H 'Content-Type: application/json'; response="$report_response"
		case "$report_status" in 200 | 201) ;; *) report_failed "$id" "$report_status" "$response"; return 1 ;; esac
	fi
	action_status "$id" ok "Report $report sent."
}

report_failed() {
	local id="$1" status="$2" body="$3" code
	code="$(report_value "$body" error)"
	case "$status:$code" in
		404:*) action_status "$id" error 'The report service does not take reports for this project now.' ;;
		429:*) action_status "$id" error 'The report service is busy; send it again in a few minutes.' ;;
		000:*) action_status "$id" error 'The report service could not be reached.' ;;
		*) action_status "$id" error "The report service refused the report (${status}${code:+, $code})." ;;
	esac
}

# What is kept of a sent report: enough to ask for its status and replies,
# and the first line of its text to recognise it by.
report_record() {
	local file="$1" client="$2" claim="$3" report="$4" stamp="$5" text="$6"
	"$report_ucode" -e 'print(sprintf("%J\n", { version: 1, client_id: ARGV[0], claim_token: ARGV[1], report_id: ARGV[2],
		sent: +ARGV[3], title: substr(split(ARGV[4], "\n")[0], 0, 120) }))' \
		"$client" "$claim" "$report" "$stamp" "$text" >"$file.new" &&
		chmod 600 "$file.new" && mv "$file.new" "$file"
}

# The reports this router sent, newest first, each with what the service says
# of it now and the replies written for it. One JSON object per line.
reports_list() {
	local file report claim response
	report_configured || { printf '{"configured":false}\n'; return 0; }
	for file in $(ls -t "$report_dir"/*.json 2>/dev/null | head -n 20); do
		report="$(jsonfilter -i "$file" -e '@.report_id' 2>/dev/null)"
		claim="$(jsonfilter -i "$file" -e '@.claim_token' 2>/dev/null)"
		response='{}'
		case "$report" in
			'' | *[!A-Za-z0-9_-]*) ;;
			*) report_request GET "api/v1/reports/$report" "$claim" ''; response="$report_response"
			   case "$report_status" in 200) ;; *) response='{}' ;; esac ;;
		esac
		"$report_ucode" -e '
			import { readfile } from "fs";
			let r = json(readfile(ARGV[0])), s = {};
			try { s = json(ARGV[1]); } catch (e) { s = {}; }
			print(sprintf("%J\n", { report_id: r.report_id, sent: r.sent, title: r.title,
				state: s?.state ?? null, replies: map(type(s?.replies) == "array" ? s.replies : [],
				x => ({ body: "" + x.body, created_at: "" + x.created_at })) }));' "$file" "$response" 2>/dev/null || :
	done
}
