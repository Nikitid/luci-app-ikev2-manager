#!/bin/sh
# What a router is missing after an upgrade or once a feature is in use, and
# when that is handed to the installer: only on a router whose dependencies
# this application installed, only when something is missing, and with the
# mail program only once mail is set up.
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
fail() { printf 'deps reconcile: %s\n' "$*" >&2; exit 1; }

sed -n '/^runtime_packages() {/,/^}/p; /^feature_packages() {/,/^}/p; /^wanted_packages() {/,/^}/p; /^missing_wanted_packages() {/,/^}/p; /^reconcile_deps() {/,/^}/p' \
	"$root/ikev2-manager-runtime/lib/system-deps.sh" >"$tmp/functions.sh"
[ "$(grep -c '() {' "$tmp/functions.sh")" = 5 ] || fail 'a function is missing'
# shellcheck disable=SC1091
. "$tmp/functions.sh"

IKEV2_MAIL_SETTINGS="$tmp/mail.json"
configured=1
ready=0
installed="$(runtime_packages | tr '\n' ' ')"
getv() { [ "$1 $2" = 'globals configured' ] && printf '%s\n' "$configured"; }
deps_state_ready() { [ "$ready" = 1 ]; }
pkg_installed() { case " $installed " in *" $1 "*) return 0 ;; esac; return 1; }
logger() { :; }
install_deps() { printf 'install\n' >>"$tmp/installs"; }
: >"$tmp/installs"
installs() { wc -l <"$tmp/installs" | tr -d ' '; }

# Without mail the mail program is not wanted.
! wanted_packages | grep -qx msmtp || fail 'the mail program is wanted without mail'
printf '{"host":"smtp.example.com"}\n' >"$IKEV2_MAIL_SETTINGS"
wanted_packages | grep -qx msmtp || fail 'set-up mail does not want the mail program'

# A router whose packages this application did not install is left alone.
reconcile_deps
[ "$(installs)" = 0 ] || fail 'packages were installed on a router this application does not manage'
ready=1
[ "$(missing_wanted_packages)" = msmtp ] || fail "missing packages: $(missing_wanted_packages)"
configured=0
reconcile_deps
[ "$(installs)" = 0 ] || fail 'packages were installed on a router that is not set up'
configured=1
reconcile_deps
[ "$(installs)" = 1 ] || fail 'a missing package was not handed to the installer'
# Nothing missing, nothing started.
installed="$installed msmtp"
reconcile_deps
[ "$(installs)" = 1 ] || fail 'the installer was started with nothing missing'
# A package a new version adds is found missing on its own.
installed="$(printf '%s\n' $installed | grep -vx kmod-nft-xfrm | tr '\n' ' ')"
[ "$(missing_wanted_packages)" = kmod-nft-xfrm ] || fail 'a runtime package the router lacks was not found'
printf '%s\n' 'deps reconcile tests OK'
