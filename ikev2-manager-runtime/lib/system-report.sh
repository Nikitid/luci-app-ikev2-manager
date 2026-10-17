#!/bin/sh
# Problem reports sent from the router to the report service: the
# administrator's text, an optional address for a reply, pictures pasted into
# the form and, when asked, the redacted diagnostics report. A report is sent
# and forgotten; nothing about it is kept or followed afterwards.
#
# Each report has its own random claim token for the time it is being sent:
# the files of a report are added with it, and a send that was cut off and
# started again with the same token returns the same report.

# Where reports go: the developer's report service unless the router names
# another (ikev2-manager.reports.endpoint), or names "none" to send nothing.
# Read with "|| true": this file is sourced by a helper that runs under set -e,
# and a router without the option must not lose every other command for it.
report_endpoint="${IKEV2_REPORT_ENDPOINT:-$(uci -q get ikev2-manager.reports.endpoint 2>/dev/null || true)}"
[ -n "$report_endpoint" ] || report_endpoint=https://reports.nikitid.ru
report_project="${IKEV2_REPORT_PROJECT:-ikev2-manager}"
report_curl="${IKEV2_REPORT_CURL:-curl}"
report_ucode="${IKEV2_UCODE:-ucode}"
# Pictures pasted into the form: how many, and how large each may be.
report_max_pictures=5
report_max_picture_bytes=5242880

# Whether this router has a report service, as an https:// address.
report_configured() {
	case "$report_endpoint" in https://[A-Za-z0-9]*) ;; *) return 1 ;; esac
	case "$report_endpoint" in *[!A-Za-z0-9.:/_-]* | */) return 1 ;; esac
}

report_input_file() {
	case "$1" in '' | *[!A-Za-z0-9-]*) die 'Invalid report input token' ;; esac
	printf '/tmp/ikev2-manager-report-%s.in\n' "$1"
}

# A picture the page staged for the report under TOKEN, numbered from 1.
report_picture_file() {
	case "$1" in '' | *[!A-Za-z0-9-]*) die 'Invalid report input token' ;; esac
	case "$2" in [1-9]) ;; *) die 'Invalid picture number' ;; esac
	printf '/tmp/ikev2-manager-report-%s.picture%s\n' "$1" "$2"
}

# One request to the service, in this shell: the status code goes to
# $report_status and the body to $report_response. METHOD PATH CLAIM BODY-FILE
# [extra curl arguments...]
report_request() {
	local method="$1" path="$2" claim="$3" body="$4" out
	shift 4
	out="$(mktemp)" || return 1
	set -- -sS -m 120 -o "$out" -w '%{http_code}' -X "$method" \
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

# Add FILE to REPORT as NAME of TYPE: register it with its size and hash,
# create its upload once and send it. Fails with the service's answer.
report_attach() {
	local report="$1" claim="$2" file="$3" name="$4" type="$5" size sum attachment
	size="$(wc -c <"$file" | tr -d ' ')"
	sum="$(sha256sum "$file" | cut -d' ' -f1)"
	"$report_ucode" -e 'print(sprintf("%J", { filename: ARGV[0], content_type: ARGV[1], size: +ARGV[2], sha256: ARGV[3] }))' \
		"$name" "$type" "$size" "$sum" >"$report_work/attach.json"
	report_request POST "api/v1/reports/$report/attachments" "$claim" "$report_work/attach.json" -H 'Content-Type: application/json'
	case "$report_status" in 200 | 201) ;; *) return 1 ;; esac
	attachment="$(report_value "$report_response" id)"
	case "$attachment" in '' | *[!A-Za-z0-9_-]*) report_status=422; return 1 ;; esac
	# Created once; a creation that already happened answers 409.
	report_request POST api/v1/uploads/ "$claim" '' -H 'Tus-Resumable: 1.0.0' \
		-H "Upload-Length: $size" -H "Upload-Metadata: attachment_id $("$report_ucode" -e 'print(b64enc(ARGV[0]))' "$attachment")"
	case "$report_status" in 201 | 409) ;; *) return 1 ;; esac
	report_request PATCH "api/v1/uploads/$attachment" "$claim" "$file" -H 'Tus-Resumable: 1.0.0' -H 'Upload-Offset: 0' \
		-H 'Content-Type: application/offset+octet-stream'
	case "$report_status" in 204 | 409) ;; *) return 1 ;; esac
}

# Send the report the page staged under TOKEN. Runs as a background job and
# reports progress under action id ID.
report_send() {
	local id="$1" token="$2" input work description contact attach pictures client claim report n file kind part
	input="$(report_input_file "$token")"
	[ -f "$input" ] && [ ! -L "$input" ] || { action_status "$id" error 'The report text is missing.'; return 1; }
	report_configured || { rm -f "$input" "${input%.in}".picture*; action_status "$id" error 'No report service is set up on this router.'; return 1; }
	work="$(mktemp -d)" || return 1
	# Runs in a process of its own: what it fetched and wrote goes with it,
	# and so do the files the page staged.
	report_work="$work"
	report_staged="$input"
	trap 'rm -rf "${report_work:-}"; rm -f "${report_staged:-}" "${report_staged%.in}".picture*' EXIT
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
		    match(r.contact, /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$/))) || type(r.diagnostics) != "bool" ||
		    type(r.pictures) != "int" || r.pictures < 0 || r.pictures > +ARGV[1])
			exit(1);
		print(sprintf("%J", r));' "$input" "$report_max_pictures" >"$work/input.json" 2>/dev/null; then
		action_status "$id" error 'The report was refused: describe the problem, and give a valid e-mail address or none.'
		return 1
	fi
	description="$(jsonfilter -i "$work/input.json" -e '@.description')"
	contact="$(jsonfilter -i "$work/input.json" -e '@.contact')"
	attach="$(jsonfilter -i "$work/input.json" -e '@.diagnostics')"
	pictures="$(jsonfilter -i "$work/input.json" -e '@.pictures')"
	# Each picture arrives from the page as encoded text and is decoded here;
	# only PNG and JPEG of a reasonable size go further.
	n=1
	while [ "$n" -le "$pictures" ]; do
		# The page writes a picture in parts of 48000 characters: uhttpd refuses
		# a /ubus request larger than 64 KB. 150 parts hold 5 MB.
		file="$(report_picture_file "$token" "$n")"
		: >"$work/picture$n.b64"
		part=1
		while [ -f "$file.$part" ] && [ ! -L "$file.$part" ] && [ "$part" -le 150 ]; do
			cat "$file.$part" >>"$work/picture$n.b64"
			part=$((part + 1))
		done
		[ "$part" -gt 1 ] || { action_status "$id" error 'A pasted picture is missing.'; return 1; }
		"$report_ucode" -e 'import { readfile } from "fs"; let d = b64dec(trim(readfile(ARGV[0]))); if (d == null) exit(1); print(d);' \
			"$work/picture$n.b64" >"$work/picture$n" 2>/dev/null || { action_status "$id" error 'A pasted picture could not be read.'; return 1; }
		[ "$(wc -c <"$work/picture$n" | tr -d ' ')" -le "$report_max_picture_bytes" ] ||
			{ action_status "$id" error 'A pasted picture is larger than 5 MB.'; return 1; }
		case "$(head -c 4 "$work/picture$n" | "$report_ucode" -e 'import { stdin } from "fs"; let b = stdin.read(4); print(sprintf("%02x%02x%02x", ord(b, 0), ord(b, 1), ord(b, 2)));')" in
			89504e) printf 'png\n' >"$work/picture$n.kind" ;;
			ffd8ff) printf 'jpg\n' >"$work/picture$n.kind" ;;
			*) action_status "$id" error 'Only PNG and JPEG pictures can be attached.'; return 1 ;;
		esac
		n=$((n + 1))
	done

	# A UUID v4 and a claim for this report, from the random source.
	client="$("$report_ucode" -e 'import { open } from "fs"; let f = open("/dev/urandom"), b = f.read(16), h = ""; f.close();
		for (let i = 0; i < 16; i++) { let c = ord(b, i); if (i == 6) c = (c & 15) | 64; if (i == 8) c = (c & 63) | 128; h += sprintf("%02x", c); }
		print(substr(h, 0, 8), "-", substr(h, 8, 4), "-", substr(h, 12, 4), "-", substr(h, 16, 4), "-", substr(h, 20));')"
	claim="$("$report_ucode" -e 'import { open } from "fs"; let f = open("/dev/urandom"), b = f.read(32), h = ""; f.close();
		for (let i = 0; i < length(b); i++) h += sprintf("%02x", ord(b, i)); print(h);')"
	case "$client" in ????????-????-4???-[89ab]???-????????????) ;; *) action_status "$id" error 'Could not make an identity for the report.'; return 1 ;; esac
	[ "${#claim}" = 64 ] || { action_status "$id" error 'Could not make an identity for the report.'; return 1; }

	action_status "$id" running 'Sending the report...'
	# Without files the report is submitted in this one request.
	"$report_ucode" -e 'let r = { project: ARGV[0], client_id: ARGV[1], claim_token: ARGV[2],
		description: ARGV[3], context: json(ARGV[5]) };
		if (ARGV[4] != "") r.contact = ARGV[4];
		if (ARGV[6] != "true" && ARGV[7] == "0") r.submit = true;
		print(sprintf("%J", r));' \
		"$report_project" "$client" "$claim" "$description" "$contact" "$(report_context_json)" "$attach" "$pictures" \
		>"$work/create.json" || return 1
	report_request POST api/v1/reports "$claim" "$work/create.json" -H 'Content-Type: application/json'
	case "$report_status" in 200 | 201) ;; *) report_failed "$id" "$report_status" "$report_response"; return 1 ;; esac
	report="$(report_value "$report_response" id)"
	case "$report" in '' | *[!A-Za-z0-9_-]*) action_status "$id" error 'The service gave no report number.'; return 1 ;; esac
	[ "$attach" = true ] || [ "$pictures" -gt 0 ] || { action_status "$id" ok 'Report sent.'; return 0; }

	action_status "$id" running 'Attaching files...'
	n=1
	while [ "$n" -le "$pictures" ]; do
		kind="$(cat "$work/picture$n.kind")"
		if [ "$kind" = png ]; then
			report_attach "$report" "$claim" "$work/picture$n" "picture-$n.png" image/png ||
				{ report_failed "$id" "$report_status" "$report_response"; return 1; }
		else
			report_attach "$report" "$claim" "$work/picture$n" "picture-$n.jpg" image/jpeg ||
				{ report_failed "$id" "$report_status" "$report_response"; return 1; }
		fi
		n=$((n + 1))
	done
	if [ "$attach" = true ]; then
		diagnostics_report >"$work/ikev2-diagnostics.txt" 2>/dev/null ||
			{ action_status "$id" error 'Could not collect the diagnostics report.'; return 1; }
		report_attach "$report" "$claim" "$work/ikev2-diagnostics.txt" ikev2-diagnostics.txt text/plain ||
			{ report_failed "$id" "$report_status" "$report_response"; return 1; }
	fi
	printf '{}' >"$work/empty.json"
	report_request POST "api/v1/reports/$report/finalize" "$claim" "$work/empty.json" -H 'Content-Type: application/json'
	case "$report_status" in 200 | 201) ;; *) report_failed "$id" "$report_status" "$report_response"; return 1 ;; esac
	action_status "$id" ok 'Report sent.'
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
