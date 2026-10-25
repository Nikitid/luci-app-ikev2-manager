#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
source="$root/windows-profile-installer/Program.cs"
script="$root/windows-profile-installer/VpnProfile.ps1"
binary="$root/windows-profile-installer/bin/Nikitid-IKEv2-Setup.exe"

[ -s "$binary" ] || {
	printf 'Windows profile installer binary is missing\n' >&2
	exit 1
}

# A PE executable starts with MZ. Keep this deliberately portable: od is
# available both in developer environments and the CI runner.
[ "$(od -An -tx1 -N2 "$binary" | tr -d ' \n')" = 4d5a ] || {
	printf 'Windows profile installer is not a PE executable\n' >&2
	exit 1
}

# The shipped program carries the profile script as it is now: a source
# change without a rebuild would ship the old behaviour.
python3 - "$binary" "$script" <<'EOF' || {
import sys
binary, script = (open(path, 'rb').read() for path in sys.argv[1:3])
sys.exit(0 if script in binary else 1)
EOF
	printf 'Windows profile installer binary does not carry the current VpnProfile.ps1; run windows-profile-installer/build.sh\n' >&2
	exit 1
}

# The profile is made for the user who runs the program, with Windows' own
# VPN commands: no administrator, no MDM bridge.
if grep -Eq 'MDM_VPNv2|Verb = "runas"' "$source"; then
	printf 'Windows profile installer went back to the MDM bridge or to elevation\n' >&2
	exit 1
fi

if grep -Fq 'button.Region =' "$source"; then
	printf 'Windows profile installer still clips native button borders\n' >&2
	exit 1
fi

if grep -Fq 'BackdropPanel backdrop' "$source"; then
	printf 'Windows profile installer still creates the removed inset backdrop\n' >&2
	exit 1
fi

if grep -Fq 'DNS-политика действует только' "$source"; then
	printf 'Windows profile installer still contains the removed DNS notice\n' >&2
	exit 1
fi

# Reading a profile, the script's answers and the friendly name, under Mono.
if command -v mcs >/dev/null 2>&1 && command -v mono >/dev/null 2>&1; then
	"$root/windows-profile-installer/test.sh"
fi

printf 'Windows profile installer tests OK\n'
