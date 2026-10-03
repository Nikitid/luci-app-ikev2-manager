#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ikev2-manager" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/bin"
cp "$root"/ikev2-manager-runtime/lib/*.sh "$tmp/root/usr/libexec/ikev2-manager.d/"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
key=
command=
for argument in "$@"; do
	key="$argument"
	case "$argument" in get | set | commit | add_list | delete) command="$argument" ;; esac
done
[ "$command" = get ] || exit 0
case "$key" in
	ikev2-manager.server.enabled) echo 1 ;;
	ikev2-manager.server.identity) echo 'vpn.example.test' ;;
	ikev2-manager.server.dns4) echo '10.20.30.1' ;;
	ikev2-manager.server.mtu) echo 1400 ;;
	ikev2-manager.server.local_ts) echo '0.0.0.0/0' ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci"

password='p&<secret>"'"'"''
encoded="$(printf '%s' "$password" | openssl base64 -A)"
printf 'user.name@example\t0s%s\n' "$encoded" \
	>"$tmp/root/etc/ikev2-manager/users.db"

export_profile() {
	platform="$1"
	PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" \
		profile-export "$platform" user.name@example
}

export_profile apple >"$tmp/apple.mobileconfig"
export_profile windows >"$tmp/windows.xml"

python3 - "$tmp/apple.mobileconfig" "$tmp/windows.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

for filename in sys.argv[1:]:
    ET.parse(filename)
PY

grep -Fq '<key>AuthPassword</key><string>p&amp;&lt;secret&gt;&quot;&apos;</string>' \
	"$tmp/apple.mobileconfig"
grep -Fq '<key>AuthName</key><string>user.name@example</string>' \
	"$tmp/apple.mobileconfig"
if grep -Fq '<key>DNS</key>' "$tmp/apple.mobileconfig"; then
	printf 'Apple profile contains an unsupported embedded DNS dictionary\n' >&2
	exit 1
fi

grep -Fq '<DomainName>.</DomainName>' "$tmp/windows.xml"
grep -Fq '<DnsServers>10.20.30.1</DnsServers>' "$tmp/windows.xml"
grep -Fq '<ProfileName>vpn.example.test</ProfileName>' "$tmp/windows.xml"
grep -Fq '<Persistent>false</Persistent>' "$tmp/windows.xml"
grep -Fq '<AutoTrigger>false</AutoTrigger>' "$tmp/windows.xml"
if grep -Fq "$password" "$tmp/windows.xml" || grep -Fq "$encoded" "$tmp/windows.xml"; then
	printf 'Windows VPNv2 profile unexpectedly contains the user password\n' >&2
	exit 1
fi

# Android gets the strongSwan app's profile: JSON, with the password intact
# rather than the encoded secret.
export_profile android >"$tmp/user.sswan"
python3 - "$tmp/user.sswan" "$password" <<'PY'
import json
import sys

profile = json.load(open(sys.argv[1]))
assert profile["type"] == "ikev2-eap", profile
assert profile["remote"] == {"addr": "vpn.example.test", "id": "vpn.example.test"}, profile
assert profile["local"] == {"eap_id": "user.name@example", "shared_secret": sys.argv[2]}, profile
assert profile["mtu"] == 1400, profile
PY

# A link opens once, inside its ten minutes, from a private address only.
manager() {
	PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	IKEV2_PROFILE_LINK_DIR="$tmp/links" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" "$@"
}
token="$(manager profile-link android user.name@example | sed -n 's/^token=//p')"
printf '%s\n' "$token" | grep -Eq '^[0-9a-f]{32}$' || { printf 'no link token: %s\n' "$token" >&2; exit 1; }
# GNU stat first: its -f reads the file system and succeeds with other output.
[ "$(stat -c %a "$tmp/links" 2>/dev/null || stat -f %Lp "$tmp/links")" = 700 ] ||
	{ printf 'the link directory is readable by others\n' >&2; exit 1; }
manager profile-link-serve "$token" 203.0.113.7 >"$tmp/served"
grep -q '^Status: 403' "$tmp/served" || { printf 'a public address got the profile\n' >&2; exit 1; }
manager profile-link-serve "$token" '::ffff:192.168.1.20' >"$tmp/served"
grep -q '^Status: 200' "$tmp/served" &&
	grep -q '^Content-Type: application/vnd.strongswan.profile' "$tmp/served" &&
	grep -Fq "\"shared_secret\":" "$tmp/served" ||
	{ printf 'a local phone did not get the profile\n' >&2; cat "$tmp/served" >&2; exit 1; }
manager profile-link-serve "$token" 192.168.1.20 >"$tmp/served"
grep -q '^Status: 410' "$tmp/served" || { printf 'a link opened twice\n' >&2; exit 1; }
token="$(manager profile-link apple user.name@example | sed -n 's/^token=//p')"
printf 'apple\tuser.name@example\t1\n' >"$tmp/links/$token"
manager profile-link-serve "$token" 10.20.30.15 >"$tmp/served"
grep -q '^Status: 410' "$tmp/served" || { printf 'an expired link was served\n' >&2; exit 1; }
manager profile-link-serve '../etc/passwd' 10.20.30.15 >"$tmp/served"
grep -q '^Status: 404' "$tmp/served" || { printf 'a malformed token was looked up\n' >&2; exit 1; }
if manager profile-link windows user.name@example >/dev/null 2>&1; then
	printf 'a link was made for a platform a phone cannot open\n' >&2
	exit 1
fi

printf 'client profile export tests OK\n'
