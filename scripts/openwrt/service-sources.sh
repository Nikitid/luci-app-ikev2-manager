#!/bin/sh
# Real BusyBox normalization and real uclient-fetch failure, in a disposable
# rootfs. No live router policy, services or management paths are changed.
set -eu
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
helper=/usr/libexec/ikev2-domains-community
mkdir -p "$work/local" "$work/user" "$work/cache"
for fn in normalize_domains normalize_remote_domains normalize_service_domains service_domain_source service_source_file valid_source_url download_service cache_is_fresh record_fetch_error fetch_failure_reason refresh_due meta_value numeric_or_zero; do
	sed -n "/^$fn() {/,/^}/p" "$helper" >>"$work/functions.sh"
done
# shellcheck disable=SC1091
. "$work/functions.sh"
local_services_dir="$work/local"
user_services_dir="$work/user"
cache_dir="$work/cache"
public_suffix_file=/usr/share/ikev2-domains/public-suffixes
max_service_bytes=1048576
service_cache_ttl=3600
force_refresh=1
raw_base=https://127.0.0.1:1
printf 'safe.example\n' >"$work/local/probe.lst"
printf 'v2fly\nhttps://127.0.0.1:1/list\n' >"$work/local/probe.source"
printf 'tenant.example\n' >"$work/local/probe.omit"
printf 'safe.example\nsub.tenant.example\nfull:ads.example @ads\n' >"$work/provider"
[ "$(normalize_service_domains probe "$work/provider" v2fly)" = safe.example ]
# With an empty filter, BusyBox must retain every ordinary domain.
: >"$work/local/probe.omit"
[ "$(normalize_service_domains probe "$work/provider" v2fly | wc -l)" -eq 2 ]
for bad in com 'include:another' 'weird:thing.example' 'two words.example'; do
	printf 'safe.example\n%s\n' "$bad" >"$work/provider"
	if normalize_service_domains probe "$work/provider" v2fly >"$work/result" 2>/dev/null; then
		printf 'provider accepted unsafe syntax: %s\n' "$bad" >&2
		exit 1
	fi
done
# An exact host is taken, an attribute that only describes a domain is
# dropped, a pattern is left out, and what the project adds comes with every
# revision.
printf 'safe.example\nfull:bucket.storage.example\nregional.example @cn\nregexp:^x-.+\\.example$\nkeyword:safe\nfull:track.example @ads\n' >"$work/provider"
printf '# ours\nadded.example\n' >"$work/local/probe.extra"
[ "$(normalize_service_domains probe "$work/provider" v2fly | sort | tr '\n' ' ')" = 'added.example bucket.storage.example regional.example safe.example ' ]
rm -f "$work/local/probe.extra"
# These installed services must have valid snapshots and source definitions.
local_services_dir=/usr/share/ikev2-domains/local-services
for service in wise revolut shopify hetzner_console supabase notion anthropic_ai openai perplexity x_ai linkedin spotify tiktok huggingface; do
	[ -n "$(service_domain_source "$service")" ]
	normalize_service_domains "$service" "$local_services_dir/$service.lst" plain >"$work/result"
	[ -s "$work/result" ]
done
local_services_dir="$work/local"
# Connection refusal is exercised by the real HTTPS downloader, not a stub.
download_service probe "$work/result" 2>"$work/fetch.log"
[ "$(cat "$work/result")" = safe.example ]
[ -s "$work/cache/probe.lst.error" ]
printf 'cached.example\n' >"$work/cache/probe.lst"
download_service probe "$work/result" 2>"$work/fetch.log"
[ "$(cat "$work/result")" = cached.example ]
printf 'override.example\n' >"$work/user/probe.lst"
download_service probe "$work/result"
[ "$(cat "$work/result")" = override.example ]
# A user service that follows a list: while the address does not answer and
# nothing was fetched yet, it routes the domains typed into it.
printf 'v2fly\nhttps://127.0.0.1:1/mine\n' >"$work/user/probe.source"
rm -f "$work/cache"/probe.lst*
download_service probe "$work/result" 2>"$work/fetch.log"
[ "$(cat "$work/result")" = override.example ]
grep -qx probe "$work/result.stale"
grep -q '^url=https://127.0.0.1:1/mine$' "$work/cache/probe.lst.error"
# A fetched revision is kept and the typed domains come with it. A typed
# public suffix is the administrator's own decision; the same name in the
# fetched list would reject the revision.
printf 'listed.example\n' >"$work/cache/probe.lst"
printf 'override.example\nco.uk\n' >"$work/user/probe.lst"
download_service probe "$work/result" 2>"$work/fetch.log"
[ "$(tr '\n' ' ' <"$work/result")" = 'co.uk listed.example override.example ' ]
printf 'listed.example\nco.uk\n' >"$work/provider"
if normalize_service_domains probe "$work/provider" v2fly >"$work/rejected" 2>/dev/null; then
	printf 'a fetched public suffix was accepted for a user service\n' >&2
	exit 1
fi
# What the package holds for the same name stays out of a user service.
printf 'packaged.example\n' >"$work/local/probe.extra"
printf 'listed.example\n' >"$work/local/probe.omit"
download_service probe "$work/result" 2>"$work/fetch.log"
[ "$(tr '\n' ' ' <"$work/result")" = 'co.uk listed.example override.example ' ]
rm -f "$work/local/probe.extra"; : >"$work/local/probe.omit"
# Only an https link without spaces is an address.
for bad in 'http://lists.example/a' 'https://' 'https://lists.example/a b' 'https://lists.example/a"b' 'ftp://lists.example/a'; do
	printf 'v2fly\n%s\n' "$bad" >"$work/user/probe.source"
	if download_service probe "$work/result" 2>/dev/null; then
		printf 'accepted a bad list address: %s\n' "$bad" >&2
		exit 1
	fi
done
valid_source_url 'https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/openai'
valid_source_url 'https://lists.example/get?name=a&v=1'
# Without an address the service is again only what was typed.
rm -f "$work/user/probe.source" "$work/cache"/probe.lst*
download_service probe "$work/result"
[ "$(tr '\n' ' ' <"$work/result")" = 'co.uk override.example ' ]
selected_file="$work/selected"
printf 'probe\n' >"$selected_file"
refresh_state_file="$work/refresh.state"
uptime_file=/proc/uptime
refresh_interval=86400
refresh_retry=3600
now="$(date +%s)"
printf 'last_success=%s\nlast_error=%s\nlast_attempt=%s\njitter=0\n' "$now" "$now" "$now" >"$refresh_state_file"
if refresh_due probe; then
	printf 'failed fetch bypassed its retry window\n' >&2
	exit 1
fi
printf 'last_success=%s\nlast_error=%s\nlast_attempt=%s\njitter=0\n' "$now" "$now" "$((now - 3601))" >"$refresh_state_file"
refresh_due probe
printf 'service provider scenarios OK\n'
