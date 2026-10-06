#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
if [ "$(uname -s)" = Darwin ]; then
	swift test --package-path "$root/desktop-clients/macos" --scratch-path "$root/build/client-macos"
else
	printf '%s\n' 'macOS native tests require a macOS runner'
fi
if command -v mcs >/dev/null 2>&1 && command -v mono >/dev/null 2>&1; then
	mkdir -p "$root/build/client-windows"
	mcs -out:"$root/build/client-windows/HostsTests.exe" -r:System.Web.Extensions.dll \
		"$root/desktop-clients/windows/ManagedHosts.cs" "$root/desktop-clients/windows/HostsTests.cs"
	mono "$root/build/client-windows/HostsTests.exe" "$root/desktop-clients/fixtures/hosts.json"
else
	printf '%s\n' 'Windows native tests: run desktop-clients/windows/test.ps1 on Windows'
fi
