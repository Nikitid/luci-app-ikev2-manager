#!/bin/sh

set -u

# rpcd hands a page's environment to the helper unchanged, so the IKEV2_*
# overrides below would let any LuCI session redirect what this root helper
# runs. They are for the test suites; where the package is installed they are
# dropped and the standard search path is used.
if [ -e /usr/share/ikev2-manager/version ]; then
	PATH=/usr/sbin:/usr/bin:/sbin:/bin
	unset TMPDIR
	for ikev2_override in $(env | sed -n 's/^\(IKEV2_[A-Za-z0-9_]*\)=.*/\1/p'); do
		unset "$ikev2_override"
	done
fi

manual_file="${IKEV2_MANUAL_FILE:-/etc/pbr-ikev2-domains.manual.txt}"
manual_cidr_file="${IKEV2_MANUAL_CIDR_FILE:-/etc/pbr-ikev2-addresses.manual.txt}"
selected_file="${IKEV2_SELECTED_FILE:-/etc/pbr-ikev2-community-selected.txt}"
final_file="${IKEV2_FINAL_FILE:-/etc/pbr-ikev2-domains.txt}"
cidr_file="${IKEV2_CIDR_FILE:-/etc/pbr-ikev2-service-cidrs.txt}"
# Never through the tunnel: the operator's two lists, and what they and the
# exclusion services add up to. An excluded domain also takes its subdomains
# out of the routed list; the routing keeps excluded addresses out of the
# tunnel whatever else selects them.
manual_exclude_file="${IKEV2_MANUAL_EXCLUDE_FILE:-/etc/pbr-ikev2-domains.exclude.txt}"
manual_exclude_cidr_file="${IKEV2_MANUAL_EXCLUDE_CIDR_FILE:-/etc/pbr-ikev2-addresses.exclude.txt}"
bypass_file="${IKEV2_BYPASS_FILE:-/etc/pbr-ikev2-domains.bypass.txt}"
bypass_cidr_file="${IKEV2_BYPASS_CIDR_FILE:-/etc/pbr-ikev2-addresses.bypass.txt}"
catalog_file="${IKEV2_CATALOG_FILE:-/usr/share/ikev2-domains/community-services}"
public_suffix_file="${IKEV2_PUBLIC_SUFFIXES:-/usr/share/ikev2-domains/public-suffixes}"
subnet_catalog_file="${IKEV2_SUBNET_CATALOG_FILE:-/etc/pbr-ikev2-community-subnet-services}"
cache_dir="${IKEV2_CACHE_DIR:-/etc/pbr-ikev2-community-cache}"
status_file="${IKEV2_STATUS_FILE:-/tmp/ikev2-domains-community.status}"
status_dir="${IKEV2_STATUS_DIR:-/var/run/ikev2-domains-community-actions}"
log_file="${IKEV2_LOG_FILE:-/tmp/ikev2-domains-community.log}"
lock_dir="${IKEV2_LOCK_DIR:-/var/run/ikev2-domains-community.lock}"
pending_dir="${IKEV2_PENDING_DIR:-/var/run/ikev2-domains-community.pending.d}"
input_prefix="${IKEV2_INPUT_PREFIX:-/tmp/ikev2-domains-input}"
restart_helper="${IKEV2_RESTART_HELPER:-/usr/libexec/ikev2-domains-restart}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
subnet_catalog_url="${IKEV2_SUBNET_CATALOG_URL:-https://api.github.com/repos/itdoginfo/allow-domains/contents/Subnets/IPv4}"
raw_base="${IKEV2_RAW_BASE:-https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Services}"
# Same publisher as the domain lists, separate tree. Telegram and a few other
# services are reached by address rather than by name, so their networks must be
# refreshable instead of frozen into the package.
subnet_raw_base="${IKEV2_SUBNET_RAW_BASE:-https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4}"
local_services_dir="${IKEV2_LOCAL_SERVICES_DIR:-/usr/share/ikev2-domains/local-services}"
user_services_dir="${IKEV2_USER_SERVICES_DIR:-/etc/ikev2-manager/services.d}"
service_input_prefix="${IKEV2_SERVICE_INPUT_PREFIX:-/tmp/ikev2-service-input}"
max_catalog_bytes="${IKEV2_MAX_CATALOG_BYTES:-1048576}"
max_service_bytes="${IKEV2_MAX_SERVICE_BYTES:-1048576}"
max_selected_services="${IKEV2_MAX_SELECTED_SERVICES:-64}"
max_total_bytes="${IKEV2_MAX_TOTAL_BYTES:-8388608}"
max_total_domains="${IKEV2_MAX_TOTAL_DOMAINS:-200000}"
max_parallel_downloads="${IKEV2_MAX_PARALLEL_DOWNLOADS:-4}"
service_cache_ttl="${IKEV2_SERVICE_CACHE_TTL:-3600}"
# Scheduled refresh of the selected services' lists. The state file sits beside
# the caches on flash, so a reboot neither loses the last success nor forgets
# that today's refresh already ran.
refresh_state_file="${IKEV2_REFRESH_STATE_FILE:-$cache_dir/refresh.state}"
refresh_interval="${IKEV2_REFRESH_INTERVAL:-86400}"
refresh_retry="${IKEV2_REFRESH_RETRY:-3600}"
source_stale_after="${IKEV2_SOURCE_STALE_AFTER:-604800}"
uptime_file="${IKEV2_UPTIME_FILE:-/proc/uptime}"

. "$runtime_lib_dir/actions.sh"

positive_uint() {
	case "$1" in
		'' | 0 | *[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

validate_resource_limits() {
	for limit in "$max_catalog_bytes" "$max_service_bytes" \
		"$max_selected_services" "$max_total_bytes" \
		"$max_total_domains" "$max_parallel_downloads" \
		"$service_cache_ttl"; do
		positive_uint "$limit" || {
			echo 'invalid community resource limits' >&2
			return 1
		}
	done
}

meta_value() {
	sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1
}

numeric_or_zero() {
	case "$1" in
		'' | *[!0-9]*) printf '0\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}

# Each revision a source delivers is recorded beside its cache: where it came
# from, when it was fetched, how many entries it held, its SHA-256, and what the
# last real change added and removed. The policy page reads this ledger instead
# of downloading anything to find out.
record_fetch_success() {
	local cached="$1" url="$2" previous="$3" now entries sum added removed changed
	now="$(date +%s)"
	entries="$(awk 'NF' "$cached" | wc -l | tr -d ' ')"
	sum="$(sha256sum "$cached" 2>/dev/null | cut -d' ' -f1)"
	added="$entries"
	removed=0
	changed="$now"
	if [ -s "$previous" ]; then
		added="$(awk 'NR == FNR { seen[$0] = 1; next } NF && !($0 in seen)' "$previous" "$cached" | wc -l | tr -d ' ')"
		removed="$(awk 'NR == FNR { seen[$0] = 1; next } NF && !($0 in seen)' "$cached" "$previous" | wc -l | tr -d ' ')"
		if [ "$added" = 0 ] && [ "$removed" = 0 ] && [ -f "$cached.meta" ]; then
			# Unchanged content keeps the date and size of the last real change.
			changed="$(meta_value "$cached.meta" changed)"
			added="$(meta_value "$cached.meta" added)"
			removed="$(meta_value "$cached.meta" removed)"
		fi
	fi
	{
		printf 'url=%s\n' "$url"
		printf 'fetched=%s\n' "$now"
		printf 'entries=%s\n' "$entries"
		printf 'sha256=%s\n' "$sum"
		printf 'changed=%s\n' "${changed:-$now}"
		printf 'added=%s\n' "${added:-0}"
		printf 'removed=%s\n' "${removed:-0}"
	} >"$cached.meta.tmp" && mv "$cached.meta.tmp" "$cached.meta"
	rm -f "$cached.error"
}

record_fetch_error() {
	local cached="$1" url="$2" reason="$3"
	mkdir -p "${cached%/*}" 2>/dev/null || return 0
	{
		printf 'url=%s\n' "$url"
		printf 'failed=%s\n' "$(date +%s)"
		printf 'reason=%s\n' "$reason"
	} >"$cached.error.tmp" && mv "$cached.error.tmp" "$cached.error"
}

fetch_failure_reason() {
	if [ "$1" -eq 0 ]; then
		printf 'download failed\n'
	elif [ "$1" -gt "$max_service_bytes" ]; then
		printf 'response exceeds the size limit\n'
	else
		printf 'content rejected by validation\n'
	fi
}

cache_is_fresh() {
	local file="$1" stamp now fetched
	[ "${force_refresh:-0}" != 1 ] || return 1
	stamp="${file}.fetched"
	[ -s "$file" ] && [ -r "$stamp" ] || return 1
	fetched="$(cat "$stamp" 2>/dev/null || true)"
	case "$fetched" in '' | *[!0-9]*) return 1 ;; esac
	now="$(date +%s)"
	[ "$now" -ge "$fetched" ] &&
		[ $((now - fetched)) -lt "$service_cache_ttl" ]
}

mark_cache_fetched() {
	local file="$1"
	date +%s >"${file}.fetched.tmp"
	mv "${file}.fetched.tmp" "${file}.fetched"
}

valid_input_token() {
	case "$1" in
		'' | *[!A-Za-z0-9-]*) return 1 ;;
	esac
	[ "${#1}" -ge 8 ] && [ "${#1}" -le 64 ]
}

input_file() {
	printf '%s-%s.%s\n' "$input_prefix" "$1" "$2"
}

normalize_domains() {
	local normalized rc
	normalized="$(mktemp)" || return 1
	if ! awk '
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			line = tolower($0)
			if (line == "" || substr(line, 1, 1) == "#")
				next
			if (length(line) > 253 || line !~ /^[a-z0-9._-]+$/ ||
			    line ~ /^\./ || line ~ /\.$/ || line ~ /\.\./) {
				printf "invalid domain: %s\n", line > "/dev/stderr"
				exit 1
			}
			count = split(line, labels, ".")
			for (i = 1; i <= count; i++) {
				if (length(labels[i]) < 1 || length(labels[i]) > 63 ||
				    labels[i] ~ /^-/ || labels[i] ~ /-$/) {
					printf "invalid domain: %s\n", line > "/dev/stderr"
					exit 1
				}
			}
			print line
		}
	' "$1" >"$normalized"; then
		rm -f "$normalized"
		return 1
	fi
	sort -u "$normalized"
	rc=$?
	rm -f "$normalized"
	return "$rc"
}

# Remote routing lists need a stricter trust boundary than administrator-owned
# files. A syntactically valid public suffix such as "com", "co.uk" or
# "kawasaki.jp" would pull an unrelated part of the Internet into one
# selected service. Single labels are refused outright; longer suffixes come
# from the Public Suffix List's ICANN section, with its wildcard ("*.ck") and
# exception ("!www.ck") rules.
normalize_remote_domains() {
	local normalized rc
	[ -r "$public_suffix_file" ] || {
		printf 'public suffix list is missing: %s\n' "$public_suffix_file" >&2
		return 1
	}
	normalized="$(mktemp)" || return 1
	if ! normalize_domains "$1" >"$normalized"; then
		rm -f "$normalized"
		return 1
	fi
	# Files are told apart by name: NR == FNR misreads an empty first file.
	awk -v suffixes="$public_suffix_file" '
		FILENAME == suffixes {
			if ($0 ~ /^#/ || $0 == "") next
			if (substr($0, 1, 1) == "!") allowed[substr($0, 2)] = 1
			else if (substr($0, 1, 2) == "*.") wildcard[substr($0, 3)] = 1
			else exact[$0] = 1
			next
		}
		{
			parent = $0
			sub(/^[^.]*\./, "", parent)
			if (index($0, ".") == 0 || ($0 in exact) ||
			    ((parent in wildcard) && !($0 in allowed))) {
				printf "unsafe remote domain: %s\n", $0 > "/dev/stderr"
				exit 1
			}
			print
		}
	' "$public_suffix_file" "$normalized"
	rc=$?
	rm -f "$normalized"
	return "$rc"
}

valid_service_id() {
	case "$1" in
		'' | *[!a-z0-9_]*) return 1 ;;
	esac
	[ "${#1}" -ge 2 ] && [ "${#1}" -le 48 ]
}

valid_service_label() {
	# BusyBox ash counts bytes in the C locale. Allow up to four UTF-8 bytes
	# for each of the 80 characters accepted by the browser editor.
	[ -n "$1" ] && [ "${#1}" -le 320 ] || return 1
	case "$1" in *'|'*) return 1 ;; esac
	printf '%s' "$1" | grep -q '[[:cntrl:]]' && return 1
	return 0
}

service_input_file() {
	printf '%s-%s.%s\n' "$service_input_prefix" "$1" "$2"
}

base_service_exists() {
	local service="$1"
	[ -s "$local_services_dir/$service.lst" ] ||
		grep -Fxq "$service" "$catalog_file" 2>/dev/null
}

service_label() {
	local service="$1" label
	label="$(sed -n '1p' "$user_services_dir/$service.name" 2>/dev/null || true)"
	[ -n "$label" ] && printf '%s\n' "$label" || printf '%s\n' "$service"
}

service_origin() {
	local service="$1" origin
	origin="$(sed -n '1p' "$user_services_dir/$service.origin" 2>/dev/null || true)"
	case "$origin" in
		custom) printf 'custom\n' ;;
		override)
			# A package upgrade may retire a prepared service. Its complete local
			# definition must remain manageable instead of becoming an override
			# that can neither be reset nor deleted.
			base_service_exists "$service" && printf 'override\n' || printf 'custom\n'
			;;
		*)
			if [ -f "$user_services_dir/$service.lst" ]; then
				base_service_exists "$service" && printf 'override\n' || printf 'custom\n'
			else
				printf 'builtin\n'
			fi
			;;
	esac
}

catalog_services() {
	{
		cat "$catalog_file" 2>/dev/null
		for source in "$local_services_dir"/*.lst; do
			[ -e "$source" ] || continue
			printf '%s\n' "${source##*/}" | sed 's/\.lst$//'
		done
		# Scan definitions as well as metadata so an interrupted write before
		# the final metadata rename remains visible and recoverable in LuCI.
		for source in "$user_services_dir"/*.lst; do
			[ -e "$source" ] || continue
			printf '%s\n' "${source##*/}" | sed 's/\.lst$//'
		done
	} | normalize_services
}

# A user-created service either routes through the tunnel or keeps its
# destinations out of it.
service_mode() {
	[ "$(sed -n '1p' "$user_services_dir/$1.mode" 2>/dev/null)" = exclude ] &&
		printf 'exclude\n' || printf 'route\n'
}

service_has_cidrs() {
	local service="$1"
	if [ -f "$user_services_dir/$service.lst" ]; then
		[ -s "$user_services_dir/$service.cidrs" ]
		return $?
	fi
	[ -s "$local_services_dir/$service.cidrs" ] ||
		grep -Fxq "$service" "$subnet_catalog_file" 2>/dev/null
}

list_service_records() {
	local service origin label customized ip
	catalog_services | while IFS= read -r service; do
		[ -n "$service" ] || continue
		origin="$(service_origin "$service")"
		label="$(service_label "$service")"
		customized=0
		[ "$origin" = builtin ] || customized=1
		ip=0
		service_has_cidrs "$service" && ip=1
		printf '%s|%s|%s|%s|%s|%s\n' \
			"$service" "$label" "$origin" "$customized" "$ip" "$(service_mode "$service")"
	done
}

read_service() {
	local service="$1" work origin label domains_pid cidrs_pid failed
	valid_service_id "$service" || return 2
	catalog_services | grep -Fxq "$service" || return 1
	work="$(mktemp -d)" || return 1
	failed=0
	download_service "$service" "$work/domains" &
	domains_pid=$!
	download_service_cidrs "$service" "$work/cidrs" &
	cidrs_pid=$!
	wait "$domains_pid" || failed=1
	wait "$cidrs_pid" || failed=1
	if [ "$failed" -ne 0 ]; then
		rm -rf "$work"
		return 1
	fi
	origin="$(service_origin "$service")"
	label="$(service_label "$service")"
	printf 'id=%s\norigin=%s\ncustomized=%s\nlabel=%s\nmode=%s\n' \
		"$service" "$origin" "$([ "$origin" = builtin ] && echo 0 || echo 1)" "$label" \
		"$(service_mode "$service")"
	printf '%s\n' '---domains---'
	cat "$work/domains"
	printf '%s\n' '---cidrs---'
	cat "$work/cidrs"
	rm -rf "$work"
}

normalize_services() {
	local normalized rc source="${1:--}"
	normalized="$(mktemp)" || return 1
	if ! awk '
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			line = tolower($0)
			if (line == "")
				next
			if (line !~ /^[a-z0-9_]+$/) {
				printf "invalid service: %s\n", line > "/dev/stderr"
				exit 1
			}
			print line
		}
	' "$source" >"$normalized"; then
		rm -f "$normalized"
		return 1
	fi
	sort -u "$normalized"
	rc=$?
	rm -f "$normalized"
	return "$rc"
}

normalize_cidrs() {
	awk '
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			if ($0 == "" || substr($0, 1, 1) == "#")
				next
			if ($0 !~ /^[0-9.]+(\/[0-9]+)?$/) {
				printf "invalid IPv4 CIDR: %s\n", $0 > "/dev/stderr"
				exit 1
			}
			split($0, cidr, "/")
			prefix = (cidr[2] == "" ? 32 : cidr[2])
			if (prefix < 0 || prefix > 32 ||
			    split(cidr[1], octets, ".") != 4) {
				printf "invalid IPv4 CIDR: %s\n", $0 > "/dev/stderr"
				exit 1
			}
			for (i = 1; i <= 4; i++) {
				if (octets[i] !~ /^[0-9]+$/ ||
				    octets[i] < 0 || octets[i] > 255) {
					printf "invalid IPv4 CIDR: %s\n", $0 > "/dev/stderr"
					exit 1
				}
			}
			printf "%s/%d\n", cidr[1], prefix
		}
	' "$1"
}

# Runtime community lists are not a trust boundary: a compromised or mistaken
# upstream file must not turn one service into a route for a cloud provider or
# the entire Internet.  Locally curated and manually entered CIDRs keep their
# existing behavior; only downloaded service networks receive these limits.
normalize_service_cidrs() {
	local normalized rc
	normalized="$(mktemp)" || return 1
	if ! normalize_cidrs "$1" >"$normalized"; then
		rm -f "$normalized"
		return 1
	fi
	awk '
		BEGIN { total = 0; max_total = 8388608 }
		{
			split($0, cidr, "/")
			prefix = cidr[2] + 0
			split(cidr[1], o, ".")
			global = 1
			if (o[1] == 0 || o[1] == 10 || o[1] == 127 || o[1] >= 224 ||
			    (o[1] == 100 && o[2] >= 64 && o[2] <= 127) ||
			    (o[1] == 169 && o[2] == 254) ||
			    (o[1] == 172 && o[2] >= 16 && o[2] <= 31) ||
			    (o[1] == 192 && o[2] == 0 && o[3] == 2) ||
			    (o[1] == 192 && o[2] == 168) ||
			    (o[1] == 198 && (o[2] == 18 || o[2] == 19)) ||
			    (o[1] == 198 && o[2] == 51 && o[3] == 100) ||
			    (o[1] == 203 && o[2] == 0 && o[3] == 113))
				global = 0
			size = 2 ^ (32 - prefix)
			if (!global || prefix < 12 || total + size > max_total) {
				printf "ignored unsafe community service CIDR: %s\n", $0 > "/dev/stderr"
				next
			}
			total += size
			print
		}
	' "$normalized"
	rc=$?
	rm -f "$normalized"
	return "$rc"
}

# Which services publish networks. Only drives the "also brings networks" mark
# in the editor, so a failed refresh degrades to the bundled files rather than
# failing anything.
refresh_subnet_catalog() {
	local tmp_json tmp_catalog downloaded_size

	tmp_json="$(mktemp)"
	tmp_catalog="$(mktemp)"

	if uclient-fetch -q -T 15 -O "$tmp_json" "$subnet_catalog_url"; then
		downloaded_size="$(wc -c < "$tmp_json" | tr -d ' ')"
	else
		downloaded_size=0
	fi

	if [ "$downloaded_size" -gt 0 ] &&
		[ "$downloaded_size" -le "$max_catalog_bytes" ] &&
		jsonfilter -i "$tmp_json" -e '@[*].name' |
			sed -n 's/\.lst$//p' |
			awk '/^[a-z0-9_]+$/' |
			sort -u > "$tmp_catalog" &&
		[ -s "$tmp_catalog" ]; then
		cp "$tmp_catalog" "$subnet_catalog_file.tmp" &&
			chmod 600 "$subnet_catalog_file.tmp" &&
			mv "$subnet_catalog_file.tmp" "$subnet_catalog_file"
	fi

	rm -f "$tmp_json" "$tmp_catalog" "$subnet_catalog_file.tmp"
}

download_service() {
	local service="$1" destination="$2" cached
	cached="$cache_dir/$service.lst"
	local downloaded normalized downloaded_size

	# A user-owned service or override is the complete definition. It is never
	# merged with a changing provider behind the administrator's back.
	if [ -f "$user_services_dir/$service.lst" ]; then
		normalized="$(mktemp)"
		if normalize_domains "$user_services_dir/$service.lst" \
			>"$normalized"; then
			mv "$normalized" "$destination"
			return 0
		fi
		rm -f "$normalized"
		return 1
	fi

	# Check local bundled services first, but validate them exactly like remote
	# content so a packaging mistake cannot poison the active ruleset.
	if [ -s "$local_services_dir/$service.lst" ]; then
		normalized="$(mktemp)"
		if normalize_domains "$local_services_dir/$service.lst" \
			>"$normalized" && [ -s "$normalized" ]; then
			mv "$normalized" "$destination"
			return 0
		fi
		rm -f "$normalized"
		return 1
	fi

	downloaded="$(mktemp)"
	normalized="$(mktemp)"
	if cache_is_fresh "$cached" &&
	   normalize_remote_domains "$cached" >"$destination"; then
		rm -f "$downloaded" "$normalized"
		return 0
	fi

	if uclient-fetch -q -T 20 -O "$downloaded" "$raw_base/$service.lst"; then
		downloaded_size="$(wc -c < "$downloaded" | tr -d ' ')"
	else
		downloaded_size=0
	fi

	if [ "$downloaded_size" -gt 0 ] &&
		[ "$downloaded_size" -le "$max_service_bytes" ] &&
		normalize_remote_domains "$downloaded" > "$normalized" &&
		[ -s "$normalized" ]; then
		mkdir -p "$cache_dir"
		[ ! -s "$cached" ] || cp "$cached" "$cached.prev"
		cp "$normalized" "$cached.tmp"
		mv "$cached.tmp" "$cached"
		mark_cache_fetched "$cached"
		record_fetch_success "$cached" "$raw_base/$service.lst" "$cached.prev"
		rm -f "$cached.prev"
		cp "$normalized" "$destination"
		rm -f "$downloaded" "$normalized"
		return 0
	fi

	if [ "$downloaded_size" -gt "$max_service_bytes" ]; then
		echo "downloaded service exceeds size limit: $service" >&2
	fi
	record_fetch_error "$cached" "$raw_base/$service.lst" \
		"$(fetch_failure_reason "$downloaded_size")"

	rm -f "$downloaded" "$normalized"
	if [ -s "$cached" ] && normalize_remote_domains "$cached" >"$destination"; then
		echo "$service" >> "$destination.stale"
		return 0
	fi
	rm -f "$destination"

	echo "unable to download service without cache: $service" >&2
	return 1
}

# Networks a vendor publishes for its own service, fetched from the vendor rather
# than the community subnet tree. Such a list is authoritative and changes
# without a package release, so it refreshes on the same cache cycle as the
# community lists and passes the same unsafe-range filter. Prints nothing for a
# service without one.
service_cidr_source() {
	case "$1" in
		zoom) printf '%s\n' "${IKEV2_ZOOM_CIDR_URL:-https://assets.zoom.us/docs/ipranges/ZoomMeetings.txt}" ;;
	esac
}

# Networks for one service, written to $destination. Unlike the domain lists the
# bundled file does not win outright: it is curated but frozen, so it is merged
# with the published list. A range that upstream has not learned about yet is
# still routed, and a range it adds arrives without a package release. On a
# download failure the cache, then the bundled file, keep the previous coverage.
download_service_cidrs() {
	local service="$1" destination="$2"
	local cached="$cache_dir/$service.cidrs"
	local downloaded normalized source_url expected

	: >"$destination"
	if [ -f "$user_services_dir/$service.cidrs" ] ||
	   [ -f "$user_services_dir/$service.lst" ]; then
		[ ! -s "$user_services_dir/$service.cidrs" ] ||
			normalize_cidrs "$user_services_dir/$service.cidrs" >"$destination"
		return $?
	fi

	if [ -s "$local_services_dir/$service.cidrs" ]; then
		normalize_cidrs "$local_services_dir/$service.cidrs" >>"$destination" ||
			{ : >"$destination"; return 1; }
	fi
	source_url="$(service_cidr_source "$service")"
	# The provider catalog is the authoritative list of services that publish
	# networks. Avoid a serial HTTP 404 for every domain-only service whenever a
	# user saves an unrelated custom domain. A service with its own vendor source
	# is absent from that catalog by definition and must not be skipped by it.
	if [ -z "$source_url" ] && [ -s "$subnet_catalog_file" ] &&
	   ! grep -Fxq "$service" "$subnet_catalog_file" 2>/dev/null; then
		return 0
	fi
	# Past this point the service is expected to publish networks, except while
	# no subnet catalog has been fetched: then every service is tried, and a
	# missing list only means the service has none.
	expected=1
	if [ -z "$source_url" ]; then
		source_url="$subnet_raw_base/$service.lst"
		[ -s "$subnet_catalog_file" ] || expected=0
	fi

	downloaded="$(mktemp)"
	normalized="$(mktemp)"
	local downloaded_size=0
	if cache_is_fresh "$cached" &&
	   normalize_service_cidrs "$cached" >"$normalized" 2>/dev/null; then
		cat "$normalized" >>"$destination"
		rm -f "$downloaded" "$normalized"
		return 0
	fi

	if uclient-fetch -q -T 20 -O "$downloaded" "$source_url"; then
		downloaded_size="$(wc -c < "$downloaded" | tr -d ' ')"
	fi

	if [ "$downloaded_size" -gt 0 ] &&
		[ "$downloaded_size" -le "$max_service_bytes" ] &&
		normalize_service_cidrs "$downloaded" > "$normalized" 2>/dev/null &&
		[ -s "$normalized" ]; then
		mkdir -p "$cache_dir"
		[ ! -s "$cached" ] || cp "$cached" "$cached.prev"
		cp "$normalized" "$cached.tmp"
		mv "$cached.tmp" "$cached"
		mark_cache_fetched "$cached"
		record_fetch_success "$cached" "$source_url" "$cached.prev"
		rm -f "$cached.prev"
		cat "$normalized" >>"$destination"
	else
		if [ "$downloaded_size" -gt "$max_service_bytes" ]; then
			echo "downloaded service networks exceed size limit: $service" >&2
		fi
		[ "$expected" = 0 ] || record_fetch_error "$cached" "$source_url" \
			"$(fetch_failure_reason "$downloaded_size")"
		# A service with no published networks is normal, not an error.
		[ ! -s "$cached" ] || normalize_service_cidrs "$cached" >>"$destination" 2>/dev/null || true
	fi

	rm -f "$downloaded" "$normalized"
	return 0
}

publish_status() {
	local source="$1" action_id="${2:-}" target
	mkdir -p "$status_dir" || return 1
	if [ -n "$action_id" ]; then
		target="$status_dir/$action_id.status"
		cp "$source" "${target}.new" || return 1
		mv "${target}.new" "$target" || return 1
	fi
	cp "$source" "${status_file}.new" || return 1
	mv "${status_file}.new" "$status_file"
}

write_simple_status() {
	local action_id="$1" state="$2" message="${3:-}" tmp
	tmp="$(mktemp)" || return 1
	{
		[ -z "$action_id" ] || echo "action_id=$action_id"
		echo "state=$state"
		echo "updated=$(date '+%Y-%m-%d %H:%M:%S %z')"
		[ -z "$message" ] || echo "message=$message"
	} >"$tmp"
	publish_status "$tmp" "$action_id"
	rm -f "$tmp"
}

publish_output() {
	cp "$1" "$2.tmp" && chmod 600 "$2.tmp" && mv "$2.tmp" "$2" || {
		rm -f "$2.tmp"
		return 1
	}
}

restore_output() {
	local backup="$1" destination="$2"
	if [ -f "$backup" ]; then
		cp "$backup" "${destination}.restore" && mv "${destination}.restore" "$destination"
	else
		rm -f "$destination"
	fi
}

# Inside a router action the restart helper finds the lock held by its caller
# and does not wait for it.
restart_policy() {
	"$restart_helper" --wait
}

apply_once() {
	local work selected normalized_manual service failed stale
	local selected_count domain_count cidr_count custom_cidr_count pids pid action_id
	local batch_count final_bytes
	action_id="${1:-}"
	[ -z "$action_id" ] ||
		write_simple_status "$action_id" running 'Preparing selected domain lists...' || true

	validate_resource_limits || return 1
	work="$(mktemp -d)" || return 1
	selected="$work/selected"
	normalized_manual="$work/manual"
	failed=0
	pids=''
	batch_count=0

	[ -f "$manual_file" ] || cp "$final_file" "$manual_file"
	[ -f "$manual_cidr_file" ] || : >"$manual_cidr_file"
	[ -f "$manual_exclude_file" ] || : >"$manual_exclude_file"
	[ -f "$manual_exclude_cidr_file" ] || : >"$manual_exclude_cidr_file"
	[ -f "$selected_file" ] || : >"$selected_file"

	if ! normalize_domains "$manual_file" >"$normalized_manual" ||
	   ! normalize_services "$selected_file" >"$selected"; then
		rm -rf "$work"
		return 1
	fi
	selected_count="$(wc -l <"$selected" | tr -d ' ')"
	if [ "$selected_count" -gt "$max_selected_services" ]; then
		echo "too many selected services: $selected_count (limit $max_selected_services)" >&2
		rm -rf "$work"
		return 1
	fi
	[ -z "$action_id" ] ||
		write_simple_status "$action_id" running 'Downloading selected service lists...' || true

	while IFS= read -r service; do
		[ -n "$service" ] || continue
		download_service "$service" "$work/$service.lst" &
		pids="$pids $!"
		batch_count=$((batch_count + 1))
		if [ "$batch_count" -ge "$max_parallel_downloads" ]; then
			for pid in $pids; do wait "$pid" || failed=1; done
			pids=''
			batch_count=0
		fi
	done <"$selected"
	for pid in $pids; do wait "$pid" || failed=1; done
	if [ "$failed" -ne 0 ]; then
		rm -rf "$work"
		return 1
	fi
	[ -z "$action_id" ] ||
		write_simple_status "$action_id" running 'Building the combined policy list...' || true

	if ! normalize_domains "$manual_exclude_file" >"$work/exclude.manual"; then
		rm -rf "$work"
		return 1
	fi
	{
		cat "$work/exclude.manual"
		while IFS= read -r service; do
			[ -n "$service" ] && [ "$(service_mode "$service")" = exclude ] &&
				cat "$work/$service.lst"
		done <"$selected"
	} | sort -u >"$work/bypass"
	# A routed domain inside an excluded one is dropped; a routed domain above
	# an excluded one stays, and the routing keeps the excluded part out.
	{
		cat "$normalized_manual"
		while IFS= read -r service; do
			[ -n "$service" ] && [ "$(service_mode "$service")" = route ] &&
				cat "$work/$service.lst"
		done <"$selected"
	} | awk -v excluded="$work/bypass" '
		BEGIN { while ((getline line <excluded) > 0) skip[line] = 1 }
		{
			name = $0
			while (name != "") {
				if (name in skip) next
				if (index(name, ".") == 0) break
				name = substr(name, index(name, ".") + 1)
			}
			print
		}
	' | sort -u >"$work/final"

	if ! normalize_cidrs "$manual_cidr_file" >"$work/manual.cidrs"; then
		rm -rf "$work"
		return 1
	fi
	if ! normalize_cidrs "$manual_exclude_cidr_file" >"$work/bypass.cidrs.unsorted"; then
		rm -rf "$work"
		return 1
	fi
	cp "$work/manual.cidrs" "$work/cidrs.unsorted"
	while IFS= read -r service; do
		[ -n "$service" ] || continue
		if ! download_service_cidrs "$service" "$work/$service.cidrs"; then
			rm -rf "$work"
			return 1
		fi
		[ -s "$work/$service.cidrs" ] || continue
		if [ "$(service_mode "$service")" = exclude ]; then
			cat "$work/$service.cidrs" >>"$work/bypass.cidrs.unsorted"
		else
			cat "$work/$service.cidrs" >>"$work/cidrs.unsorted"
		fi
	done <"$selected"
	sort -u "$work/cidrs.unsorted" 2>/dev/null >"$work/cidrs"
	sort -u "$work/bypass.cidrs.unsorted" 2>/dev/null >"$work/bypass.cidrs"

	if [ ! -s "$work/final" ] && [ ! -s "$work/cidrs" ] &&
	   [ ! -s "$work/bypass" ] && [ ! -s "$work/bypass.cidrs" ] && [ -s "$selected" ]; then
		echo 'refusing to install an empty domain list (services selected but no domains resolved)' >&2
		rm -rf "$work"
		return 1
	fi
	domain_count="$(wc -l <"$work/final" | tr -d ' ')"
	final_bytes="$(wc -c <"$work/final" | tr -d ' ')"
	if [ "$domain_count" -gt "$max_total_domains" ] ||
	   [ "$final_bytes" -gt "$max_total_bytes" ]; then
		echo "combined domain list exceeds resource limits: $domain_count entries, $final_bytes bytes" >&2
		rm -rf "$work"
		return 1
	fi

	if [ -e "$final_file" ] && [ -e "$cidr_file" ] &&
	   cmp -s "$work/final" "$final_file" &&
	   cmp -s "$work/cidrs" "$cidr_file" &&
	   cmp -s "$work/bypass" "$bypass_file" 2>/dev/null &&
	   cmp -s "$work/bypass.cidrs" "$bypass_cidr_file" 2>/dev/null &&
	   "$restart_helper" --check; then
		[ -z "$action_id" ] ||
			write_simple_status "$action_id" running \
				'Policy list unchanged; current routing is healthy.' || true
	else
		[ ! -e "$final_file" ] || cp "$final_file" "$work/final.before"
		[ ! -e "$cidr_file" ] || cp "$cidr_file" "$work/cidrs.before"
		[ ! -e "$bypass_file" ] || cp "$bypass_file" "$work/bypass.before"
		[ ! -e "$bypass_cidr_file" ] || cp "$bypass_cidr_file" "$work/bypass.cidrs.before"
		[ -z "$action_id" ] ||
			write_simple_status "$action_id" running 'Restarting policy routing...' || true
		if ! publish_output "$work/final" "$final_file" ||
		   ! publish_output "$work/cidrs" "$cidr_file" ||
		   ! publish_output "$work/bypass" "$bypass_file" ||
		   ! publish_output "$work/bypass.cidrs" "$bypass_cidr_file" ||
		   ! restart_policy; then
			restore_output "$work/final.before" "$final_file" || true
			restore_output "$work/cidrs.before" "$cidr_file" || true
			restore_output "$work/bypass.before" "$bypass_file" || true
			restore_output "$work/bypass.cidrs.before" "$bypass_cidr_file" || true
			restart_policy >/dev/null 2>&1 || true
			rm -rf "$work"
			return 1
		fi
	fi

	cidr_count="$(wc -l <"$work/cidrs" | tr -d ' ')"
	custom_cidr_count="$(wc -l <"$work/manual.cidrs" | tr -d ' ')"
	stale="$(cat "$work"/*.stale 2>/dev/null | sort -u | tr '\n' ' ')"
	{
		[ -z "$action_id" ] || echo "action_id=$action_id"
		echo 'state=ok'
		echo "updated=$(date '+%Y-%m-%d %H:%M:%S %z')"
		echo "services=$selected_count"
		echo "domains=$domain_count"
		echo "cidrs=$cidr_count"
		echo "custom_cidrs=$custom_cidr_count"
		echo "excluded_domains=$(wc -l <"$work/bypass" | tr -d ' ')"
		echo "excluded_cidrs=$(wc -l <"$work/bypass.cidrs" | tr -d ' ')"
		echo "selected=$(tr '\n' ',' <"$selected" | sed 's/,$//')"
		[ -z "$stale" ] || echo "cached_services=$stale"
	} >"$work/status"
	publish_status "$work/status" "$action_id" || true
	rm -rf "$work"
}

apply_failure_file="${IKEV2_APPLY_FAILURE_FILE:-/var/run/ikev2-domains-community.failure}"

# Every abort below used to return silently, so an operator saw "Community
# update failed" with an empty log and no way to tell which check rejected the
# input. Record the reason for both the log and the status message.
apply_failed() {
	printf 'apply rejected: %s\n' "$1" >&2
	mkdir -p "${apply_failure_file%/*}" 2>/dev/null || :
	printf '%s\n' "$1" >"$apply_failure_file" 2>/dev/null || :
	return 1
}

apply_staged_input() {
	local action_id="$1" token="$2" work kind kinds source destination bytes
	local restore_kind restore_destination
	valid_input_token "$token" || {
		apply_failed 'the submitted input token is malformed'
		return 1
	}
	validate_resource_limits || {
		apply_failed 'configured resource limits are invalid'
		return 1
	}
	work="$(mktemp -d)" || {
		apply_failed 'no writable temporary directory'
		return 1
	}
	# The exclusion lists are optional: a page that predates them sends three
	# files, and the lists it does not know stay as they are.
	kinds='domains cidrs services'
	for kind in xdomains xcidrs; do
		source="$(input_file "$token" "$kind")"
		[ ! -e "$source" ] && [ ! -L "$source" ] || kinds="$kinds $kind"
	done
	for kind in $kinds; do
		source="$(input_file "$token" "$kind")"
		[ -f "$source" ] && [ ! -L "$source" ] || {
			rm -rf "$work"
			apply_failed "submitted $kind input is missing or not a regular file"
			return 1
		}
		bytes="$(wc -c <"$source" | tr -d ' ')"
		case "$kind" in
			domains | xdomains) [ "$bytes" -le "$max_total_bytes" ] ;;
			cidrs | xcidrs) [ "$bytes" -le 1048576 ] ;;
			services) [ "$bytes" -le 65536 ] ;;
		esac || {
			rm -rf "$work"
			apply_failed "submitted $kind input exceeds its size limit ($bytes bytes)"
			return 1
		}
	done
	# Capture every previous input before replacing any of them. This keeps a
	# failed multi-file publish from deleting an input that was not backed up yet.
	for kind in $kinds; do
		destination="$(staged_destination "$kind")"
		[ ! -e "$destination" ] || cp "$destination" "$work/$kind.before" || {
			rm -rf "$work"
			apply_failed "unable to back up the current $kind list"
			return 1
		}
	done
	for kind in $kinds; do
		destination="$(staged_destination "$kind")"
		source="$(input_file "$token" "$kind")"
		if ! cp "$source" "${destination}.new.$$" ||
		   ! chmod 600 "${destination}.new.$$" ||
		   ! mv "${destination}.new.$$" "$destination"; then
			for restore_kind in $kinds; do
				restore_destination="$(staged_destination "$restore_kind")"
				restore_output "$work/$restore_kind.before" "$restore_destination" || true
			done
			rm -f "${destination}.new.$$"
			rm -rf "$work"
			apply_failed "unable to publish the new $kind list"
			return 1
		fi
	done
	for kind in $kinds; do rm -f "$(input_file "$token" "$kind")"; done
	if apply_once "$action_id"; then
		rm -rf "$work"
		return 0
	fi
	for kind in $kinds; do
		restore_output "$work/$kind.before" "$(staged_destination "$kind")" || true
	done
	rm -rf "$work"
	return 1
}

staged_destination() {
	case "$1" in
		domains) printf '%s\n' "$manual_file" ;;
		cidrs) printf '%s\n' "$manual_cidr_file" ;;
		services) printf '%s\n' "$selected_file" ;;
		xdomains) printf '%s\n' "$manual_exclude_file" ;;
		xcidrs) printf '%s\n' "$manual_exclude_cidr_file" ;;
	esac
}

restore_service_files() {
	local backup="$1" service="$2" kind
	mkdir -p "$user_services_dir"
	for kind in lst cidrs name origin mode; do
		rm -f "$user_services_dir/$service.$kind"
		[ ! -e "$backup/$kind" ] ||
			cp "$backup/$kind" "$user_services_dir/$service.$kind"
	done
}

set_service_selected() {
	local service="$1" enabled="$2" normalized
	normalized="$(mktemp)" || return 1
	{
		cat "$selected_file" 2>/dev/null
		[ "$enabled" = 1 ] && printf '%s\n' "$service"
	} | awk -v service="$service" -v enabled="$enabled" '
		$0 == service && enabled != 1 { next }
		{ print }
	' | normalize_services >"$normalized" || {
		rm -f "$normalized"
		return 1
	}
	chmod 600 "$normalized"
	mv "$normalized" "$selected_file"
}

apply_staged_service() {
	local action_id="$1" token="$2" meta domains cidrs operation service label
	local selected origin work kind bytes extension mode
	valid_input_token "$token" || {
		apply_failed 'the submitted service token is malformed'
		return 1
	}
	meta="$(service_input_file "$token" meta)"
	domains="$(service_input_file "$token" domains)"
	cidrs="$(service_input_file "$token" cidrs)"
	for kind in "$meta" "$domains" "$cidrs"; do
		[ -f "$kind" ] && [ ! -L "$kind" ] || {
			apply_failed 'submitted service input is missing or not a regular file'
			return 1
		}
		bytes="$(wc -c <"$kind" | tr -d ' ')"
		[ "$bytes" -le "$max_service_bytes" ] || {
			apply_failed 'submitted service input exceeds its size limit'
			return 1
		}
	done
	operation="$(sed -n 's/^operation=//p' "$meta" | sed -n '1p')"
	service="$(sed -n 's/^id=//p' "$meta" | sed -n '1p')"
	label="$(sed -n 's/^label=//p' "$meta" | sed -n '1p')"
	selected="$(sed -n 's/^selected=//p' "$meta" | sed -n '1p')"
	# Absent from a page that predates exclusion services: the service keeps
	# what it was.
	mode="$(sed -n 's/^mode=//p' "$meta" | sed -n '1p')"
	[ -n "$mode" ] || mode="$(service_mode "$service")"
	case "$mode" in route | exclude) ;; *) apply_failed 'invalid service mode'; return 1 ;; esac
	case "$operation" in save | reset | delete) ;; *) apply_failed 'invalid service operation'; return 1 ;; esac
	valid_service_id "$service" || { apply_failed 'invalid service identifier'; return 1; }
	case "$selected" in 0 | 1 | keep) ;; *) apply_failed 'invalid service selection state'; return 1 ;; esac
	[ "$operation" != save ] || valid_service_label "$label" || {
		apply_failed 'invalid service display name'
		return 1
	}

	work="$(mktemp -d)" || return 1
	mkdir -p "$work/service-before"
	for kind in lst cidrs name origin mode; do
		[ ! -e "$user_services_dir/$service.$kind" ] ||
			cp "$user_services_dir/$service.$kind" "$work/service-before/$kind"
	done
	[ ! -e "$selected_file" ] || cp "$selected_file" "$work/selected.before"

	case "$operation" in
		save)
			if ! normalize_domains "$domains" >"$work/domains" ||
		   ! normalize_cidrs "$cidrs" >"$work/cidrs" ||
		   { [ ! -s "$work/domains" ] && [ ! -s "$work/cidrs" ]; }; then
			rm -rf "$work"
			apply_failed 'a service needs at least one valid domain or IPv4 network'
			return 1
		fi
		origin="$(service_origin "$service")"
		if [ "$origin" != custom ]; then
			if base_service_exists "$service"; then origin=override; else origin=custom; fi
		fi
		# A prepared service routes; only one the operator made can exclude.
		[ "$mode" = route ] || [ "$origin" = custom ] || {
			rm -rf "$work"
			apply_failed 'only a user-created service can keep its destinations out of the tunnel'
			return 1
		}
		mkdir -p "$user_services_dir" || { rm -rf "$work"; return 1; }
		chmod 700 "$user_services_dir"
		for kind in domains cidrs; do
			extension=lst
			[ "$kind" = domains ] || extension=cidrs
			cp "$work/$kind" "$user_services_dir/$service.$extension.new" || {
				restore_service_files "$work/service-before" "$service"
				rm -rf "$work"
				return 1
			}
			chmod 600 "$user_services_dir/$service.$extension.new"
			mv "$user_services_dir/$service.$extension.new" "$user_services_dir/$service.$extension"
		done
		printf '%s\n' "$label" >"$user_services_dir/$service.name.new"
		printf '%s\n' "$origin" >"$user_services_dir/$service.origin.new"
		chmod 600 "$user_services_dir/$service.name.new" "$user_services_dir/$service.origin.new"
		mv "$user_services_dir/$service.name.new" "$user_services_dir/$service.name"
		mv "$user_services_dir/$service.origin.new" "$user_services_dir/$service.origin"
		if [ "$mode" = exclude ]; then
			printf 'exclude\n' >"$user_services_dir/$service.mode.new" &&
				chmod 600 "$user_services_dir/$service.mode.new" &&
				mv "$user_services_dir/$service.mode.new" "$user_services_dir/$service.mode"
		else
			rm -f "$user_services_dir/$service.mode"
		fi
		;;
	reset)
		base_service_exists "$service" || {
			rm -rf "$work"
			apply_failed 'only a prepared service can be reset'
			return 1
		}
		rm -f "$user_services_dir/$service.lst" "$user_services_dir/$service.cidrs" \
			"$user_services_dir/$service.name" "$user_services_dir/$service.origin" \
			"$user_services_dir/$service.mode"
		;;
	delete)
		[ "$(service_origin "$service")" = custom ] || {
			rm -rf "$work"
			apply_failed 'only a user-created service can be deleted'
			return 1
		}
		selected=0
		rm -f "$user_services_dir/$service.lst" "$user_services_dir/$service.cidrs" \
			"$user_services_dir/$service.name" "$user_services_dir/$service.origin" \
			"$user_services_dir/$service.mode"
		;;
	esac

	if { [ "$selected" = keep ] || set_service_selected "$service" "$selected"; } &&
	   apply_once "$action_id"; then
		:
	else
		restore_service_files "$work/service-before" "$service"
		restore_output "$work/selected.before" "$selected_file" || true
		apply_once >/dev/null 2>&1 || true
		rm -rf "$work"
		return 1
	fi
	for kind in meta domains cidrs; do rm -f "$(service_input_file "$token" "$kind")"; done
	# apply_once already published the complete policy status, including the
	# action id. Do not replace it with a reduced success record here: the same
	# status file also feeds the policy counters in LuCI.
	rm -rf "$work"
}

refresh_state_set() {
	local key="$1" value="$2" tmp
	mkdir -p "${refresh_state_file%/*}" || return 1
	tmp="$refresh_state_file.$$"
	{
		grep -v "^$key=" "$refresh_state_file" 2>/dev/null
		printf '%s=%s\n' "$key" "$value"
	} >"$tmp" && mv "$tmp" "$refresh_state_file"
}

# Whether the scheduled refresh should run now. Never while routing is paused or
# with nothing selected, at most once per retry window, once after every boot,
# and otherwise daily at a stable per-router offset so a fleet does not reach
# the same sources in the same minute. With "probe" nothing is written.
refresh_due() {
	local mode="${1:-}" now last_attempt last_success jitter uptime boot
	[ "$(uci -q get ikev2-manager.domains.paused 2>/dev/null)" != 1 ] || return 1
	[ -s "$selected_file" ] || return 1
	now="$(date +%s)"
	last_attempt="$(numeric_or_zero "$(meta_value "$refresh_state_file" last_attempt)")"
	last_success="$(numeric_or_zero "$(meta_value "$refresh_state_file" last_success)")"
	jitter="$(meta_value "$refresh_state_file" jitter)"
	case "$jitter" in
		'' | *[!0-9]*)
			jitter=$(( ${RANDOM:-$$} % 3600 ))
			[ "$mode" = probe ] || refresh_state_set jitter "$jitter" || true
			;;
	esac
	uptime="$(numeric_or_zero "$(cut -d. -f1 "$uptime_file" 2>/dev/null)")"
	boot=$((now - uptime))
	[ $((now - last_attempt)) -ge "$refresh_retry" ] || return 1
	[ "$last_attempt" -ge "$boot" ] || return 0
	[ $((now - last_success)) -ge $((refresh_interval + jitter)) ]
}

# Rebuild every selected service from its source. A forced run ignores the cache
# freshness window; the daily run does not need to, because its interval is far
# longer than that window. apply_once leaves routing untouched when nothing
# differs, so a quiet day costs the downloads and no restart.
refresh_worker() {
	local action_id="$1" mode="${2:-due}" rc
	refresh_state_set last_attempt "$(date +%s)" || true
	# The cache window is a validated positive limit, so a forced run marks the
	# caches stale instead of lowering it.
	force_refresh=0
	[ "$mode" != force ] || force_refresh=1
	apply_once "$action_id"
	rc=$?
	force_refresh=0
	if [ "$rc" -eq 0 ]; then
		refresh_state_set last_success "$(date +%s)" || true
		refresh_state_set last_error '' || true
		return 0
	fi
	refresh_state_set last_error "$(date +%s)" || true
	apply_failed 'the selected lists could not be rebuilt'
}

queue_refresh() {
	local mode="$1" action_id
	action_id="$(date +%s)-$$"
	mkdir -p "$pending_dir" || return 1
	printf 'refresh %s\n' "$mode" >"$pending_dir/$action_id"
	write_simple_status "$action_id" running 'Queued...' || {
		rm -f "$pending_dir/$action_id"
		return 1
	}
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _run; then
			rm -f "$pending_dir/$action_id"
			write_simple_status "$action_id" error 'Unable to start the list refresh worker' || true
			return 1
		fi
	else
		setsid "$0" _run </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$action_id"
}

print_list_source() {
	local kind="$1" cached="$2" origin="$3" url="$4" bundled="$5" key fetched
	printf '%s_origin=%s\n' "$kind" "$origin"
	[ -z "$url" ] || printf '%s_url=%s\n' "$kind" "$url"
	if [ -n "$bundled" ] && [ -s "$bundled" ]; then
		printf '%s_bundled=%s\n' "$kind" \
			"$(awk 'NF && substr($1, 1, 1) != "#"' "$bundled" | wc -l | tr -d ' ')"
	fi
	if [ -f "$cached.meta" ]; then
		for key in entries fetched changed added removed sha256; do
			printf '%s_%s=%s\n' "$kind" "$key" "$(meta_value "$cached.meta" "$key")"
		done
		fetched="$(numeric_or_zero "$(meta_value "$cached.meta" fetched)")"
		[ $(( $(date +%s) - fetched )) -lt "$source_stale_after" ] ||
			printf '%s_stale=1\n' "$kind"
	fi
	if [ -f "$cached.error" ]; then
		printf '%s_failed=%s\n' "$kind" "$(meta_value "$cached.error" failed)"
		printf '%s_error=%s\n' "$kind" "$(meta_value "$cached.error" reason)"
	fi
}

# One record per selected service describing where its domains and networks
# come from and how fresh the cached revisions are. Read-only: nothing is
# downloaded and no state is written.
print_sources() {
	local service key value url bundled
	printf 'now=%s\n' "$(date +%s)"
	printf 'stale_after=%s\n' "$source_stale_after"
	printf 'refresh_interval=%s\n' "$refresh_interval"
	for key in last_attempt last_success last_error; do
		value="$(meta_value "$refresh_state_file" "$key")"
		[ -z "$value" ] || printf 'refresh_%s=%s\n' "$key" "$value"
	done
	if refresh_due probe; then
		printf 'refresh_due=1\n'
	else
		printf 'refresh_due=0\n'
	fi
	[ -s "$selected_file" ] || return 0
	normalize_services "$selected_file" 2>/dev/null | while IFS= read -r service; do
		[ -n "$service" ] || continue
		printf '%s\n' '---service---'
		printf 'service=%s\n' "$service"
		printf 'label=%s\n' "$(service_label "$service")"
		if [ -f "$user_services_dir/$service.lst" ]; then
			print_list_source domains "$cache_dir/$service.lst" user '' "$user_services_dir/$service.lst"
		elif [ -s "$local_services_dir/$service.lst" ]; then
			print_list_source domains "$cache_dir/$service.lst" bundled '' "$local_services_dir/$service.lst"
		else
			print_list_source domains "$cache_dir/$service.lst" community "$raw_base/$service.lst" ''
		fi
		url="$(service_cidr_source "$service")"
		bundled=''
		[ ! -s "$local_services_dir/$service.cidrs" ] || bundled="$local_services_dir/$service.cidrs"
		if [ -f "$user_services_dir/$service.lst" ] || [ -f "$user_services_dir/$service.cidrs" ]; then
			[ ! -s "$user_services_dir/$service.cidrs" ] ||
				print_list_source networks "$cache_dir/$service.cidrs" user '' "$user_services_dir/$service.cidrs"
		elif [ -n "$url" ]; then
			print_list_source networks "$cache_dir/$service.cidrs" vendor "$url" "$bundled"
		elif grep -Fxq "$service" "$subnet_catalog_file" 2>/dev/null ||
			[ -f "$cache_dir/$service.cidrs.meta" ]; then
			print_list_source networks "$cache_dir/$service.cidrs" community "$subnet_raw_base/$service.lst" "$bundled"
		elif [ -n "$bundled" ]; then
			print_list_source networks "$cache_dir/$service.cidrs" bundled '' "$bundled"
		fi
	done
}

run_scheduled() {
	local idle_passes pending action_id operation token extra worker failed reason
	local kind failure_prefix preserved
	sleep 1
	pid_lock_acquire "$lock_dir" || exit 0
	trap 'pid_lock_release "$lock_dir"' EXIT INT TERM
	idle_passes=0
	while [ "$idle_passes" -lt 2 ]; do
		pending="$(find "$pending_dir" -type f 2>/dev/null | sort | head -n1)"
		if [ -z "$pending" ]; then
			idle_passes=$((idle_passes + 1))
			sleep 1
			continue
		fi
		idle_passes=0
		action_id="${pending##*/}"
		operation=''
		token=''
		extra=''
		IFS=' ' read -r operation token extra <"$pending" || true
		[ -z "$extra" ] || operation=''
		rm -f "$pending"
		rm -f "$apply_failure_file"
		case "$operation" in
			apply) worker=apply_staged_input ;;
			service) worker=apply_staged_service ;;
			refresh) worker=refresh_worker ;;
			*) worker='' ;;
		esac
		failed=0
		if [ -z "$worker" ] || ! "$worker" "$action_id" "$token" >>"$log_file" 2>&1; then
			failed=1
		fi
		case "$operation" in
			apply)
				for kind in domains cidrs services; do rm -f "$(input_file "$token" "$kind")"; done
				;;
			service)
				for kind in meta domains cidrs; do rm -f "$(service_input_file "$token" "$kind")"; done
				;;
		esac
		if [ "$failed" -ne 0 ]; then
			reason="$(sed -n '1p' "$apply_failure_file" 2>/dev/null || true)"
			rm -f "$apply_failure_file"
			if [ "$operation" = service ]; then
				failure_prefix='Service update failed'
				preserved='previous service, selection and policy preserved'
			elif [ "$operation" = refresh ]; then
				failure_prefix='List refresh failed'
				preserved='previous lists and policy preserved'
			else
				failure_prefix='Community update failed'
				preserved='previous combined list preserved'
			fi
			if [ -n "$reason" ]; then
				write_simple_status "$action_id" error \
					"$failure_prefix: $reason; $preserved" || true
			else
				write_simple_status "$action_id" error \
					"$failure_prefix; $preserved" || true
			fi
		fi
	done
}

case "${1:-}" in
	catalog)
		catalog_services
		;;
	services)
		list_service_records
		;;
	service-read)
		read_service "${2:-}"
		;;
	ip-services)
		if [ ! -s "$subnet_catalog_file" ] ||
			find "$subnet_catalog_file" -mtime +0 -print 2>/dev/null | grep -q .; then
			refresh_subnet_catalog
		fi
		{
			cat "$subnet_catalog_file" 2>/dev/null
			for source in "$local_services_dir"/*.cidrs; do
				[ -s "$source" ] || continue
				printf '%s\n' "${source##*/}" | sed 's/\.cidrs$//'
			done
		} | sort -u
		;;
	schedule)
		token="${2:-}"
		valid_input_token "$token" || { echo 'invalid input token' >&2; exit 2; }
		for kind in domains cidrs services; do
			path="$(input_file "$token" "$kind")"
			[ -f "$path" ] && [ ! -L "$path" ] || {
				echo "missing staged $kind input" >&2
				exit 1
			}
		done
		action_id="$(date +%s)-$$"
		mkdir -p "$pending_dir"
		find "$status_dir" -type f -mtime +7 -exec rm -f {} \; 2>/dev/null || true
		printf 'apply %s\n' "$token" >"$pending_dir/$action_id"
		write_simple_status "$action_id" running 'Queued...' || {
			rm -f "$pending_dir/$action_id"
			exit 1
		}
		# rpcd's `file exec` reads the child's stdout until EOF, so a plain
		# background/setsid job keeps the pipe open and the caller blocks until
		# the ubus timeout (~30s). start-stop-daemon -b fully daemonizes —
		# closing every inherited descriptor — so rpcd gets EOF immediately and
		# the rebuild proceeds detached.
		if command -v start-stop-daemon >/dev/null 2>&1; then
			if ! start-stop-daemon -b -q -S -x "$0" -- _run; then
				rm -f "$pending_dir/$action_id"
				write_simple_status "$action_id" error 'Unable to start the community update worker' || true
				exit 1
			fi
		else
			setsid "$0" _run </dev/null >/dev/null 2>&1 &
		fi
		printf 'action_id=%s\n' "$action_id"
		;;
	service-schedule)
		token="${2:-}"
		valid_input_token "$token" || { echo 'invalid input token' >&2; exit 2; }
		for kind in meta domains cidrs; do
			path="$(service_input_file "$token" "$kind")"
			[ -f "$path" ] && [ ! -L "$path" ] || {
				echo "missing staged service $kind input" >&2
				exit 1
			}
		done
		action_id="$(date +%s)-$$"
		mkdir -p "$pending_dir"
		printf 'service %s\n' "$token" >"$pending_dir/$action_id"
		write_simple_status "$action_id" running 'Queued...' || {
			rm -f "$pending_dir/$action_id"
			exit 1
		}
		if command -v start-stop-daemon >/dev/null 2>&1; then
			if ! start-stop-daemon -b -q -S -x "$0" -- _run; then
				rm -f "$pending_dir/$action_id"
				for kind in meta domains cidrs; do
					rm -f "$(service_input_file "$token" "$kind")"
				done
				write_simple_status "$action_id" error \
					'Unable to start the service update worker' || true
				exit 1
			fi
		else
			setsid "$0" _run </dev/null >/dev/null 2>&1 &
		fi
		printf 'action_id=%s\n' "$action_id"
		;;
	sources)
		print_sources
		;;
	refresh-schedule)
		case "${2:-due}" in
			due | force) queue_refresh "${2:-due}" || exit 1 ;;
			*) echo 'usage: refresh-schedule [due|force]' >&2; exit 2 ;;
		esac
		;;
	refresh-if-due)
		refresh_due || exit 0
		queue_refresh due || exit 1
		;;
	_refresh)
		refresh_worker "${2:-}" "${3:-due}"
		;;
	_run)
		run_scheduled
		;;
	apply)
		pid_lock_acquire "$lock_dir" || {
			echo 'another community update is already running' >&2
			exit 1
		}
		trap 'pid_lock_release "$lock_dir"' EXIT INT TERM
		apply_once
		;;
	_apply-input)
		apply_staged_input "${2:-}" "${3:-}"
		;;
	_apply-service)
		apply_staged_service "${2:-}" "${3:-}"
		;;
	status)
		action_id="${2:-}"
		case "$action_id" in
			'' | *[!0-9-]*) echo 'invalid action id' >&2; exit 2 ;;
		esac
		cat "$status_dir/$action_id.status" 2>/dev/null || printf 'state=idle\n'
		;;
	*)
		echo "usage: $0 {catalog|services|service-read ID|ip-services|sources|schedule TOKEN|service-schedule TOKEN|refresh-schedule [due|force]|refresh-if-due|status ACTION_ID|apply}" >&2
		exit 2
		;;
esac
