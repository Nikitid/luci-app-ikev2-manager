# Windows profile installer

`Nikitid-IKEv2-Setup.exe` installs, updates, verifies, and removes the IKEv2
VPN connection a VPNv2 XML profile describes, for the current Windows user and
without an administrator. It can receive a profile on the command line,
discover a single adjacent `*.vpnv2.xml`, or let the user choose any XML
through the standard file picker. The connection is made by `VpnProfile.ps1`,
carried inside the program, with Windows' own VPN commands: IKEv2 with the
profile's EAP configuration and cipher suite, its routes in split mode, and the
connection's interface first for names while it is connected. Nothing is left
behind but the connection: no service, scheduled task or machine-wide rule.

The executable targets .NET Framework 4.8 and runs on supported Windows 10 and
Windows 11 installations. Build it with Mono:

```sh
./windows-profile-installer/build.sh
./windows-profile-installer/test.sh
```

Against Windows itself, as an ordinary user, in the build VM:

```sh
scripts/windows-vm.sh run windows-profile-installer/tests/vpn-profile-check.ps1 --user
scripts/windows-vm.sh run windows-profile-installer/tests/store-check.ps1 --user
```

The prebuilt executable shipped in the OpenWrt package must be rebuilt whenever
the source or `app-icon.svg` changes. Regenerate `app.ico` from the SVG before
building. A production release should be Authenticode-signed before
packaging; signing the generic executable doesn't expose profile credentials.
