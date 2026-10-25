#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
out="${1:-$root/bin}"
mkdir -p "$out"

mcs -nologo -sdk:4.8 -optimize+ -target:winexe -platform:anycpu \
	-win32manifest:"$root/app.manifest" \
	-win32icon:"$root/app.ico" \
	-resource:"$root/VpnProfile.ps1",VpnProfile.ps1 \
	-r:System.dll -r:System.Core.dll -r:System.Drawing.dll \
	-r:System.Management.dll -r:System.Windows.Forms.dll -r:System.Xml.dll \
	-out:"$out/Nikitid-IKEv2-Setup.exe" "$root/Program.cs"
