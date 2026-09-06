# bigassfans-i6-lan

LAN Edge Driver for Big Ass Fans Haiku H/I Series ceiling fans, controlling
them over their local "i6" protocol (SLIP-framed protobuf over TCP, port
31415) — no cloud dependency, no authentication of any kind.

SmartThings Community post: https://community.smartthings.com/t/st-edge-driver-big-a-fans-haiku-h-i-series-via-local-i6-protocol/310526

## Status: working end-to-end

Deployed as `bigassfans-i6-lan`, distributed via a SmartThings channel
invite (see the Community thread above).

Both known fans (Haiku H/I Series, firmware 3.3.7, api_version 8) were
auto-discovered via mDNS and are fully working: fan switch/speed/mode/
direction/whoosh/eco, light switch/brightness (its own child device, for
Alexa visibility), LED indicators/fan beep/legacy IR remote, temperature,
a collapsible Sleep section, 4 more collapsible sections (Comfort, Heat
Assist, Motion, Return to Auto), and a collapsible auto-discovered
Schedule section. Every collapsible section uses the same pattern: a
phantom show/hide dropdown as the always-visible anchor, with the real
fields (including the section's own enable/disable toggle) nested
inside, gated on it.

4 profile variants exist, auto-selected per-device from the
`hideAddFan`/`noLight` preferences — in practice every real fan lands on
`bigassfans-h-no-light-no-addfan` since the light always splits into its
own child device. The other 3 cover fans still using the "Add another
fan" management tile, or the pre-split light layout.

## Protocol details (confirmed empirically against two real fans)

- **Transport**: plain TCP to port 31415, one connection per request.
- **Framing**: SLIP (RFC 1055) — `0xC0` start/end delimiters, `0xDB`
  escapes for literal `0xC0`/`0xDB` bytes in the payload.
- **Payload**: proto2 protobuf, `Root{ root2: Root2{ query | commit } }`.
  Full schema in `src/baf_protocol.lua`'s `FIELDS` table; originally
  sourced from `jfroy/aiobafi6`'s `proto/aiobafi6.proto`.
- **`ALL` doesn't mean all**: it only returns identity properties (model,
  firmware, MAC, api_version). Fan/light properties need their own
  `FAN`/`LIGHT`-category queries — this driver queries both every cycle.
- **Missing fields mean "at default"**: the firmware omits bool/enum
  fields at their zero value rather than sending them explicitly.
  `parse_category_result` fills in known defaults for anything a category
  didn't mention.
- **Discovery**: mDNS `_api._tcp`. Since that service name is generic,
  candidates are also filtered on their TXT `model` record containing
  "Haiku".

## Architecture

- `config.yml` — `lan` + `discovery` permissions.
- `search-parameters.yml` — gates the hub's pre-scan on `_api._tcp`.
- `profiles/*.yml` — 4 variants (see Status). The live one
  (`bigassfans-h-no-light-no-addfan`) has:
  - `main` — `switch` (cascades to the light child too), `fanSpeed`
    (native 0–7 range, numeric slider labels, not a percentage),
    `refresh`, and custom `fanMode` (Off/On/Auto), `fanDirection`
    (Forward/Reverse), `whoosh`, `ecoMode`.
  - `sleep` — a master `sleepMode` switch gating every sub-field (auto
    mode, speed, timer, return-to-auto, brightness, wake-up) via
    `visibleCondition` and 4 headless "gate" capabilities. `sleepMode`
    stays first and ungated — a section's first `detailView` tile can
    never fully hide on this platform, so it's the anchor the rest hide
    behind.
  - `comfort` / `heat` / `motion` / `returnToAuto` — 4 sections for the
    official app's Auto Comfort/Heat Assist/Motion Sense/Return-to-Auto
    screens (field mapping confirmed via an isolated passive packet
    capture, not inferred from co-occurrence). Each is a phantom
    show/hide dropdown gating everything else in that component,
    including its own enable/disable toggle (a dedicated list-style
    capability, not the stock `switch` — see Known open items). Sub-
    fields: Comfort has ideal temperature plus min/max fan-speed
    sliders; Heat Assist has its own fan-speed slider plus a Reverse
    toggle; Motion has a timeout plus an Unoccupied Behavior mode
    (Turn Off / Smart Mix, with its own fan speed for Smart Mix) encoded
    as a 2-field nested protobuf submessage — the only field here needing
    a real nested-message encoder; Return to Auto has just a duration.
  - `settings` — a phantom `showSettings` dropdown gating LED indicators,
    fan beep, legacy IR remote, and temperature. Sits directly above
    `schedule`.
  - `schedule` — auto-discovers up to 5 *named* on-device schedules every
    poll (decoded via a real pcap, see `baf_protocol.lua`'s "Schedule
    write path" comment): sorted alphabetically and bound to slots 1–5,
    since the fan's own "slot" field is a revision counter, not a stable
    identity. **5 is a practical ceiling, not a discovered limit** —
    SmartThings can't render a truly unbounded list (every tile needs a
    capability declared statically ahead of time), and neither the fan's
    firmware nor the official app documents an actual maximum schedule
    count. If you have more than 5 named schedules on a fan, only the
    alphabetically-first 5 are visible/controllable here — the rest are
    simply not surfaced (not an error, just not built). Each slot shows
    a read-only name plus its own enable/
    disable toggle; unused slots hide entirely rather than showing empty,
    via a per-slot existence-gate capability (`visibleCondition` only
    checks one attribute, so Show-Schedule + exists is folded into one).
    Read-only tiles use `state`/`list` displayType, not `textField`, so
    there's no edit-pencil — the tradeoff is the app visually groups
    tiles by display type, so names and toggles render as two blocks
    rather than interleaved pairs. Always read-modify-write, never
    reconstructs a schedule. Nameless schedules (Bedtime/Wake-Up type)
    are out of scope — no stable key to match them by. Full design for
    going further: `SCHEDULE_FEATURE_PLAN.md`.
  - The light is a **separate child device** — Alexa discovers by device,
    not component.
  - Preferences: "Manual IP Override" (`ipAddress`, `0.0.0.0` = use
    mDNS), `pollInterval`, `hideAddFan`/`noLight`. No preferences for
    schedules — that section auto-discovers.
- `src/slip.lua` — SLIP encode/decode.
- `src/protobuf.lua` — minimal hand-written protobuf wire codec (varint +
  length-delimited only — no packed-repeated or fixed32/64, unused by
  this schema).
- `src/baf_protocol.lua` — builds Query/Commit messages, parses
  QueryResult responses into flat property tables.
- `src/baf_client.lua` — TCP client: SLIP-frame send/receive over one
  connection. Also drives the MORE_PUSH commit-and-verify pattern
  (LED/beep/IR/sleep mode): identity query, commit, then a short read
  window for the fan's unsolicited push of the new value.
- `src/discovery_mdns.lua` — wraps `st.mdns.discover`, filters for real
  BAF fans, keys candidates by the fan's own `uuid` TXT record (stable
  across DHCP changes, unlike an IP-derived key).
- `src/discovery.lua` — creates devices for new candidates and
  self-heals a known device's persisted IP if mDNS reports a new one
  (unless Manual IP Override is set).
- `src/init.lua` — lifecycle handlers, all command handlers,
  `ensure_light_child` (gated on the fan's own reported `has_light`,
  fails open on query failure), Sleep-section gating, `cascade_light`,
  the direction-reversal stop-first interlock, and polling (`FAN`/
  `LIGHT`/`SENSORS` each cycle over one connection, matching response
  frames by content rather than send-order, wrapped in `pcall` so one
  bad cycle can't kill the recurring poll timer for good).

## Development approach: verify offline before touching the hub

Every protocol layer (SLIP framing, protobuf codec, category-query
parsing, frame reading) was unit-tested against **real captured bytes**
using a locally-extracted Lua 5.4 interpreter (`apt-get download
lua5.4 liblua5.4-0` + `dpkg-deb -x`, no root needed) — before any of it
touched the hub. Worth reusing for future protocol-heavy drivers: get a
local interpreter, capture real traffic, unit-test the wire-format code
directly against it.

## Known open items

- Only tested against two real fans, both with a physical light — the
  no-light skip path (`has_light` check) is verified via decode logic
  only, not against real no-light hardware.
- `setFanSpeed` also sets `fan_mode` — a UX choice, not a confirmed
  firmware coupling.
- Whoosh/eco/comfort-mode interactions with each other aren't modeled.
- Fields in real `FAN` responses but missing from the reference `.proto`
  are silently ignored.
- mDNS reflection across VLANs is untested.
- ~~Comfort/Motion-detection fields not confirmed / not wired into any
  capability~~ — **shipped**: every field in this cluster is confirmed
  via an isolated passive packet capture and live as its own
  collapsible section (see Architecture). The earlier live conflict
  (field 52 guessed for both `heat_assist_reverse` and
  `motion_sense_enable`) is resolved: field 52 is really
  `motion_sense_enable`, `heat_assist_reverse` is field 62. The
  Unoccupied Behavior nested-submessage write path is built and
  confirmed live too, not just read-only.
- Schedule auto-discovery covers up to 5 *named* schedules only (see
  Architecture above for why 5, not an unbounded list) — full create/edit
  (day/time/action) and nameless (Bedtime/Wake-Up) schedules are unbuilt.
  Design for going further: `SCHEDULE_FEATURE_PLAN.md`.
- This driver has no confirmed-working `displayType: switch` tile
  anywhere — every custom toggle here (Schedule, Settings, and all 9 in
  the newer Comfort/Heat/Motion/Return-to-Auto sections) renders as a
  `list`-style dropdown instead, after a switch-style knob was found to
  never reliably track state. Ruled out one open theory before settling
  on dropdowns for good: an isolated test using the stock `switch`
  capability's own lowercase `on`/`off` value convention (vs. this
  driver's usual capitalized `On`/`Off`) showed the identical
  stuck-knob bug, so it isn't about value casing — it's a genuine
  platform rendering defect, and dropdowns aren't a workaround, they're
  the only reliable option.
- A capability's rendered label is frozen permanently at
  `capabilities:create` time from whatever name was submitted — no
  later presentation/translation edit has ever been observed to change
  it. A component's first `detailView` tile also always renders as a
  prominent banner regardless of capability type. Both shaped this
  driver's collapsible-section design: a phantom show/hide dropdown
  always occupies the first slot (it's fine to be a banner, since it's
  always visible anyway), with the real enable toggle second.
- Fan-speed slider shows plain numeric labels (0–7) — no established
  naming convention for an 8-speed fan exists yet.
