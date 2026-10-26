# Waypoint as a full VPN application

The design for the next major release: what a service is, what each person is
given and chooses, what the router enforces, and the application on Windows
and macOS built on that. One release carries all of it; the current clients
get no further features, only what moves into the new service.

## Services

A service is a name and what it reaches:

- **domains** - as now: each gets a stable virtual address, names resolve to it
  inside the tunnel and the router's exit reaches the real domain;
- **networks** - new: address ranges reached as themselves (Telegram, a
  provider's IP ranges, a company network). They travel as traffic selectors,
  so every system routes them without a hosts file. At most 64 networks for
  one device.

Services come from the existing catalogue and the operator's own services; the
Policy Routing page stays where they are defined.

## What a person is given

The owner gives each person a set of services. Every entry is one of:

| entry | the person sees | without the tunnel |
| --- | --- | --- |
| required, closed | on, cannot switch it off | blocked |
| required, open | on, cannot switch it off | goes direct |
| optional | a switch, off until the person turns it on | goes direct, or blocked if the owner allowed the person to choose that and they did |

The set belongs to the person; every device of the person gets it. Choices
belong to the device: a laptop may carry a service the desktop does not. The
"everything through the tunnel" mode stays a per-person setting beside the set.

Today's per-person "open" flag becomes the default for new entries; existing
assignments migrate to "required" entries with that flag, so nothing changes
for a person until the owner edits them.

## What the owner sees

On Remote clients, per person: the set as given, and per device what is chosen
and what is active now (tunnel up, which services pass, which are blocked).
Editing a set follows the page's Save/Discard flow; a change reaches devices
with their next policy poll.

## The router

- **Policy**: the device API carries the person's set with each entry's rule
  and the device's choices; a device posts its choices, the router validates
  them against the set and keeps them per device.
- **Admission**: grants follow the effective set - required entries plus the
  device's chosen optional ones - for domains and networks alike.
- **Networks and traffic selectors**: one swanctl connection per device
  identity, its local traffic selectors the virtual subnet plus the networks of
  that device's effective set. A changed set reloads that connection and the
  device reconnects to take the new selectors; other devices are untouched.
  (One shared connection with every network would route a network the device
  was not given into the tunnel on macOS, where it would be refused.)
- **Exit**: as now, through the dedicated proxy for domains; networks are
  routed into the exit tunnel by the router's own policy routing.

## The application

| part | Windows | macOS |
| --- | --- | --- |
| interface | WinUI 3 (Windows App SDK), current .NET LTS | SwiftUI; menu-bar extra first, window second |
| background | the service, moved to current .NET; per architecture | the launchd daemon |
| tunnel | Windows' own IKEv2 (RAS): native on x64 and ARM64, no driver | the system's IKEv2 profile |
| blocking | WFP filters per service | packet-filter anchor per service |
| names | hosts block for the effective set; real resolution for open services while the tunnel is down | the same |
| installer | MSI per architecture (WiX) | signed, notarized package; universal binary |

What it shows, taken from the clients that get this right (WireGuard,
Tailscale, Mullvad, Proton, WARP):

- one state and one sentence with the cause ("no route to the server from
  this network"), never a bare "service error";
- the services as a list: required ones marked as such, optional ones with
  their switch, and where allowed the person's "block without the tunnel";
- a tray / menu-bar icon that shows the state and connects without the window;
- updates that install themselves, with the notes one click away;
- a report with one button, what is sent shown first;
- a reset that always finishes and says what it removed.

ARM: separate x64 and ARM64 Windows builds, tested on an ARM64 runner in CI,
not only built; a universal macOS binary, tested on Apple silicon.

## Order of work

1. Router: the service model with networks, per-person sets, device choices,
   the API, admission and per-device connections; the owner's page.
2. The background parts on both systems, against the new API: per-service
   blocking and names, choices, causes, reset.
3. The interfaces: WinUI and SwiftUI, tray and menu bar.
4. Installers per architecture, signing, the update from the current clients
   with registration and settings kept.
5. One release: router, feed and both clients together.

The current clients' fixes (the cause of an error, a reset that finishes)
move into step 2 rather than being kept apart.
