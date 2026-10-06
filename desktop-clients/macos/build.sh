#!/bin/sh
# Builds the macOS client and its installer package:
#   desktop-clients/macos/build.sh X.Y.Z [output-directory]
# The package installs the window, the root daemon and its launchd job, and an
# uninstaller. Nothing is signed with a distribution identity here; see
# docs/CLIENT_ACCESS.md.
set -eu
here="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
version="${1:-}"
case "$version" in
	[0-9]*.[0-9]*.[0-9]*) ;;
	*) printf '%s\n' 'usage: build.sh X.Y.Z [output-directory]' >&2; exit 2 ;;
esac
output="${2:-$here/../../build/client-macos-package}"
scratch="$here/../../build/client-macos"
label=io.github.nikitid.ikev2-manager-client
# Apple silicon only: the current SDK no longer builds for Intel.
swift build --package-path "$here" --scratch-path "$scratch" -c release >/dev/null
products="$(swift build --package-path "$here" --scratch-path "$scratch" -c release --show-bin-path)"
stage="$(mktemp -d)"
trap 'rm -r "$stage"' EXIT
app="$stage/root/Applications/IKEv2 Manager Client.app/Contents"
tools="$stage/root/Library/PrivilegedHelperTools"
mkdir -p "$app/MacOS" "$tools" "$stage/root/Library/LaunchDaemons" "$stage/scripts" "$output"
cp "$products/IKEv2ManagerClient" "$app/MacOS/IKEv2ManagerClient"
cp "$products/ikev2-manager-clientd" "$tools/$label"
cat >"$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$label.app</string>
	<key>CFBundleName</key><string>IKEv2 Manager Client</string>
	<key>CFBundleDisplayName</key><string>IKEv2 Manager Client</string>
	<key>CFBundleExecutable</key><string>IKEv2ManagerClient</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$version</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
cat >"$stage/root/Library/LaunchDaemons/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$label</string>
	<key>ProgramArguments</key>
	<array><string>/Library/PrivilegedHelperTools/$label</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
# Removal is the one place where the denial, the names, the VPN profile and the
# registration are taken away; the daemon knows what it installed.
cat >"$tools/$label.uninstall" <<SCRIPT
#!/bin/sh
set -u
[ "\$(id -u)" = 0 ] || { echo 'Run with sudo.' >&2; exit 1; }
launchctl bootout system/$label 2>/dev/null
"/Library/PrivilegedHelperTools/$label" --remove || echo 'The stored device could not be removed completely.' >&2
rm -f "/Library/LaunchDaemons/$label.plist" "/Library/PrivilegedHelperTools/$label"
rm -rf "/Applications/IKEv2 Manager Client.app"
pkgutil --forget $label >/dev/null 2>&1
rm -f "/Library/PrivilegedHelperTools/$label.uninstall"
echo 'IKEv2 Manager Client removed.'
SCRIPT
chmod 755 "$tools/$label" "$tools/$label.uninstall" "$app/MacOS/IKEv2ManagerClient"
cat >"$stage/scripts/preinstall" <<SCRIPT
#!/bin/sh
launchctl bootout system/$label 2>/dev/null
exit 0
SCRIPT
cat >"$stage/scripts/postinstall" <<SCRIPT
#!/bin/sh
chown root:wheel "/Library/LaunchDaemons/$label.plist" "/Library/PrivilegedHelperTools/$label" "/Library/PrivilegedHelperTools/$label.uninstall"
chmod 644 "/Library/LaunchDaemons/$label.plist"
launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"
SCRIPT
chmod 755 "$stage/scripts/preinstall" "$stage/scripts/postinstall"
plutil -lint "$app/Info.plist" "$stage/root/Library/LaunchDaemons/$label.plist" >/dev/null
# An ad-hoc signature lets the binaries run on Apple silicon; it names nobody.
codesign --force --sign - "$tools/$label" >/dev/null 2>&1
codesign --force --sign - "$stage/root/Applications/IKEv2 Manager Client.app" >/dev/null 2>&1
# Extended attributes of the build machine have no place in the payload.
xattr -cr "$stage/root"
COPYFILE_DISABLE=1 pkgbuild --quiet --root "$stage/root" --scripts "$stage/scripts" --identifier "$label" --version "$version" \
	--install-location / "$output/IKEv2ManagerClient-$version.pkg"
printf '%s\n' "$output/IKEv2ManagerClient-$version.pkg"
