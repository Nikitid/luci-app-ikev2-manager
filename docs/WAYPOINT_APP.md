# Waypoint as a full VPN application

A proposal to decide on, not a description of what ships. Today's clients
work, but they are a status window over a service; this is the plan for one
application per platform that a person can live with every day.

## What the good clients get right

Taken from WireGuard, Tailscale, Mullvad, Proton VPN and Cloudflare WARP:

- one switch and one sentence of state, with the cause when it is not
  connected ("no route to the server from this network"), never "service
  error";
- a menu-bar or tray icon that shows the state and connects without opening
  a window;
- a kill switch that is visible and explained, and that survives a crash;
- updates that install themselves, signed, with the release notes one click
  away;
- diagnostics a person can send with one button, with what is sent shown
  first;
- a reset that always finishes, and says what it removed;
- native builds for every processor the platform runs on.

## Windows

| part | today | proposal |
| --- | --- | --- |
| window | WinForms, .NET Framework 4.8 | WinUI 3 on the current Windows App SDK, current .NET LTS |
| service | .NET Framework 4.8, x64 and arm64 binaries in one installer | the same code moved to the current .NET, published per architecture (NativeAOT where WFP and RAS interop allow) |
| tunnel | Windows' own IKEv2 (RAS) | unchanged: native on x64 and ARM64, no driver to sign |
| blocking | WFP filters owned by the service | unchanged |
| installer | own Setup.exe | MSI per architecture (WiX), so the service, updates and removal follow Windows' rules |
| tray | none | a tray icon with state and connect |

WinUI 3 needs the current .NET, which is why the service moves too: one
runtime, one set of tests. MSIX is not proposed: a packaged app cannot own a
classic service with the rights the guard needs.

## macOS

| part | today | proposal |
| --- | --- | --- |
| window | AppKit window | SwiftUI, with a menu-bar extra as the main surface |
| daemon | launchd daemon, system IKEv2 profile | unchanged design; signed and notarized |
| binaries | built per machine | universal binary (Apple silicon and Intel) |

## ARM

- Windows: separate x64 and ARM64 builds of the window and the service,
  tested on an ARM64 runner in CI (`windows-11-arm`), not only built.
- macOS: universal binary, tests on Apple silicon runners; Intel is checked
  by the same tests under Rosetta until a runner is needed.

## Order

1. The service and its tests move to the current .NET, behaviour unchanged.
2. The WinUI window replaces the WinForms one, the same states and words.
3. MSI installers per architecture, updates through them.
4. Tray and menu-bar surfaces on both platforms.

Each step ships through the existing update path, so installed clients are
never stranded.
