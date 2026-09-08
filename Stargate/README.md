# Stargate Dialing Computer

For CC:Tweaked + Stargate Journey
Created by: Jacob + Claude

## About

This repo provides ComputerCraft (CC:Tweaked) programs for controlling Stargates
from the [Stargate Journey](https://povstalec.github.io/StargateJourney) Minecraft mod
([dev wiki](https://lukaskabc.github.io/StargateJourney/) for in-progress/unreleased docs).
The main dialer auto-detects your gate type and interface, and exposes a
touch-screen GUI plus remote control support.

## Which script should I use?

| Script | Status | Notes |
|---|---|---|
| `Working/GateDial-GUI-WS.lua` | **Recommended** | Full touch GUI, real-time control over WebSocket, auto interface detection. This is the one actually in use. |
| `Working/GateDial-GUI-HTTP.lua` | Working fallback | Same as the WS version but polls the API over HTTP every second instead of a push connection. Use if the websocket endpoint is unavailable. |
| `Working/RemoteDHD.lua` | Working | Pocket-computer companion app — lets you dial gates remotely via the API from a Pocket Computer. |
| `Working/GateNetwork-Registry.lua` | ⚠️ Known bug | Admin tool for viewing/registering gates on a monitor. The "Add Gate" form's touch handling doesn't capture tap coordinates correctly (it discards the real x/y from the `monitor_touch` event and waits on an unrelated event instead), so taps may land in the wrong place. Also currently points at an old `192.168.1.41` API URL/path scheme rather than the current `croul1.duckdns.org` one — verify the endpoint before relying on it. |
| `Working/GateDial-Legacy-Hybrid.lua` | ⚠️ Broken | Manual `dial <gate>` command only fires for raw dash-separated addresses, not gate names — the name-lookup branch is unreachable in current code. `stargateName` placeholder was also never filled in. Kept for reference only. |
| `Working/GateDial-Legacy-AutoAPI.lua` | ⚠️ Broken | `stargateName` placeholder never filled in (command matching won't work). Also has no interface-type branching, so it assumes a basic interface's rotate/open/encode dial sequence even on crystal/advanced interfaces. Kept for reference only. |
| `Working/GateDial-Terminal-Manual.lua` | Incomplete | Simple terminal menu, functionally sound but `Gates` table ships with empty placeholder addresses to fill in. Like the AutoAPI script, it has no interface-type branching, so it assumes a basic-interface dial sequence. |
| `CSW-GateDial.lua` | Unfinished | Local-network (non-API) fallback dialer for use when the API isn't reachable. Left unfinished since there's been no need for it on a self-hosted setup — main gate-listing loop cuts off partway through. |

## Supported Gates

| Gate Type | Interface | Iris |
|---|---|---|
| Classic | Basic | Yes |
| Milky Way | Basic | Yes |
| Universe | Crystal/Advanced | Yes |
| Pegasus | Crystal/Advanced | Yes |
| Tollan | Crystal/Advanced | No |

## Requirements

**Hardware:**
- Computer (normal or advanced)
- **Advanced monitor** (required for touch — normal monitors do not support touch events)
- Stargate Interface (any type)
- Wired modems + network cables
- Stargate (any type)

## Installation

1. Place the computer next to an advanced monitor, or connect via a wired modem network.
2. Connect the Stargate interface to the computer via wired modems and network cables.
3. Turn on both modems (right-click).
4. Copy `Working/GateDial-GUI-WS.lua` to the computer.
5. Run the program.

## First-Time Setup (after swapping gates)

CC:Tweaked needs its interface connection refreshed after a gate swap:
1. Shut down the computer.
2. Break and replace the interface.
3. Reconnect network cables.
4. Toggle modems on.
5. Restart the computer.

## Configuration

Edit the `CONFIG` table at the top of the script:

```lua
CONFIG = {
    STARGATE_NAME = "Earth",       -- This gate's name
    STARGATE_ADDRESS = {1,2,3,4,5,6,0}, -- This gate's address (see Address Format below)
    API_URL = "http://...",        -- API endpoint (remote control)
    API_ENABLED = true,            -- Set false to disable API/remote control
    DEBUG_MODE = true,             -- Verbose terminal logging
}
```

## Address Format

**Addresses must be 7 or 9 symbols long, ending in `0`.**

The `0` represents the **Point of Origin** — as of Stargate Journey's dialing
mechanics, the origin is always symbol `0` and must be encoded as the final
symbol of the address for a dial to be considered complete. Manually-added
addresses (e.g. in `GateNetwork-Registry.lua`'s Add Gate form, or any legacy
script's hardcoded `Gates` table) need to follow this too, or you'll hit an
"Incomplete address" error.

Example: `{26, 6, 14, 31, 11, 29, 0}`

This applies to every gate's own `STARGATE_ADDRESS` in its config — since that's
what gets reported to the API and picked up as a destination by other gates on
the network. If one gate's address is missing the trailing `0`, dialing *that*
destination from anywhere else will fail.

## Usage — Main Screen

- Gate type and interface type
- Current status (Idle / Dialing / Connected)
- Energy level with progress bar
- Chevron lock indicators
- Iris status (if installed)
- Event log

**Buttons:**
- `DIAL` — opens the destination selector
- `DISCONNECT` — closes the active wormhole
- `IRIS OPEN` / `IRIS CLOSE` — iris control (if installed)
- `REFRESH HARDWARE` — re-scans peripherals

## Iris Progress Values

| Value | Meaning |
|---|---|
| 0 | Fully open |
| 1–57 | Moving |
| 58 | Fully closed |

## Remote Control

`RemoteDHD.lua` runs on a Pocket Computer and sends `open`/`close`/`iris-open`/
`iris-close` commands to a target gate via the same API the GUI dialers use —
useful for dialing gates in Minecraft without standing at the DHD.
