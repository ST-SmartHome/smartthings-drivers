# bigassfans-i6-lan

LAN Edge Driver for Big Ass Fans Haiku H/I Series ceiling fans, controlling
them over their local "i6" protocol (SLIP-framed protobuf over TCP, port
31415) — no cloud dependency, no authentication of any kind.

SmartThings Community post: https://community.smartthings.com/t/st-edge-driver-big-a-fans-haiku-h-i-series-via-local-i6-protocol/310526

## Status: working end-to-end

Deployed as `bigassfans-i6-lan`, distributed via a SmartThings channel
invite (see the Community thread above) — same channel as this account's
other drivers.

Both known fans (same model "Haiku H/I Series", firmware 3.3.7,
api_version 8) were auto-discovered via mDNS on the first scan and
confirmed fully working end-to-end: fan switch/speed/mode/direction/
whoosh/eco, light switch/brightness (as its own child device, for Alexa
visibility), LED indicators/fan beep/legacy IR remote, temperature, and
a full Sleep section (auto mode, timer, brightness, wake-up) with a
master switch that collapses/expands the whole section.

4 profile variants exist, auto-selected per-device from the
`hideAddFan`/`noLight` preferences — in practice every real fan lands on
`bigassfans-h-no-light-no-addfan` (currently `.v35`) since the light
always splits into its own child device. The other 3 variants exist for
fans still using the "Add another fan" management tile, or (briefly,
before the light child device is created) the pre-split light layout.

## Protocol details (confirmed empirically against two real fans, not from docs alone)

- **Transport**: plain TCP to port 31415, one connection per request.
- **Framing**: SLIP (RFC 1055) — `0xC0` start/end delimiters, `0xDB`
  escape sequences for literal `0xC0`/`0xDB` bytes in the payload.
- **Payload**: proto2 protobuf, `Root{ root2: Root2{ query | commit } }`.
  Full schema in `src/baf_protocol.lua`'s `FIELDS` table and comments;
  originally sourced from `jfroy/aiobafi6`'s `proto/aiobafi6.proto`.
- **Querying is category-scoped, and the "ALL" category is misleadingly
  named** — confirmed by direct probing, not documented anywhere: `ALL`
  only returns general/identity properties (model, firmware_version,
  mac_address, api_version). Fan properties need a `FAN`-category query,
  light properties a `LIGHT`-category query. This driver queries both
  every poll cycle.
- **Missing fields mean "at default"**: the firmware omits bool/enum
  fields that are at their zero value (OFF/false) rather than sending them
  explicitly, even in a full category response. `baf_protocol.lua`'s
  `parse_category_result` fills in known defaults for anything the
  category didn't mention, rather than leaving them nil.
- **Discovery**: mDNS service `_api._tcp`, domain `local`. TXT records
  include `model`, `uuid`, `name`, `api version`. Because `_api._tcp` is a
  very generic service name, every mDNS candidate is filtered on its TXT
  `model` record actually containing "Haiku" before a device gets
  created — not just on the service type matching.

## Architecture

- `config.yml` — `lan` + `discovery` permissions.
- `search-parameters.yml` — gates the hub's pre-scan on the `_api._tcp`
  mDNS service, so `discovery_handler` only fires when something matching
  is actually present.
- `profiles/*.yml` — 4 variants (see Status above). The live one
  (`bigassfans-h-no-light-no-addfan`) has:
  - `main` — `switch` (cascades to the light child on/off too),
    `fanSpeed` (native range 0–7 with numeric slider labels, not a
    percentage), `refresh`, and custom capabilities `fanMode`
    (Off/On/Auto, above `fanSpeed`, also cascades the light), `fanDirection`
    (Forward/Reverse), `whoosh` (Off/On), `ecoMode` (Off/On).
  - `settings` (labeled "Device Settings") — a phantom `showSettings`
    switch (heading "Settings", values Hide/Show) gating LED indicators,
    fan beep, legacy IR remote, and temperature.
  - `sleep` — a master `sleepMode` switch gating every sub-field (auto
    mode, speed, timer, return-to-auto, brightness, wake-up) via
    `visibleCondition` and 4 headless "gate" capabilities. `sleepMode`
    sits first and deliberately ungated — a section's first `detailView`
    tile can never fully hide on this platform (confirmed via a live
    test), so it's the anchor the other fields hide behind.
  - `schedule` — binds SmartThings to the fan's own on-device schedules
    (decoded via a real pcap — see `baf_protocol.lua`'s "Schedule write
    path" comment). **Auto-discovers** up to 3 named schedules every
    poll — no typing required. Every schedule with a name is sorted
    alphabetically and bound to slot 1/2/3 in that order (the fan's own
    "slot" field is a revision counter, not a stable identity, so it
    can't be used directly); each slot is a read-only name (`Schedule
    One`/`Two`/`Three`) followed by its own enable/disable toggle
    (`Schedule One Enabled` etc.), and the toggle re-resolves the same
    sort at command time so it always matches what's currently
    displayed. A slot beyond however many named schedules actually exist
    is hidden entirely (not shown as an empty "(none)" placeholder) via a
    dedicated per-slot existence gate that folds Show Schedule + "does a
    schedule actually exist here" into one condition — `visibleCondition`
    only supports checking one attribute, so this needed its own headless
    gate capability per slot, same pattern as the Sleep section's mode
    gates. The name and enabled-state tiles are read-only/list-style
    (`state`/`list` displayType, not `textField`) so they carry no
    edit-pencil icon — a real, deliberate tradeoff: the app visually
    groups tiles by display type rather than by list order, so the
    labels and toggles render as two separate blocks rather than
    interleaved pairs. Always read-modify-write (never constructs a
    schedule from scratch), since the exact rules for schedule
    capacity/write semantics are still not fully understood. Nameless
    schedules (the Bedtime/Wake-Up shape) are out of scope here — no
    stable key to sort/match them by. Same `showSchedule` phantom-switch
    collapsible pattern as Device Settings for the section as a whole —
    no separate opt-in gate beyond that; any named schedule (including a
    real one) becomes visible/controllable the moment Show Schedule is
    on. Full design for going further (nameless-schedule support, and
    creating new ones): see `SCHEDULE_FEATURE_PLAN.md`.
  - The light itself is a **separate child device** (`-light` DNI
    suffix, `bigassfans-light-child.v1` profile) — Alexa discovers by
    device, not component, so a fan's light was invisible to Alexa as
    long as it lived on the same device as the fan.
  - Preferences: "Manual IP Override" (`ipAddress`, sentinel `0.0.0.0`
    meaning "use the mDNS-discovered address"), `pollInterval`,
    `hideAddFan`/`noLight` (profile-variant switching). No preferences
    for schedules — that section auto-discovers, see above. No secrets
    to enter — see protocol notes above.
- `src/slip.lua` — SLIP encode/decode.
- `src/protobuf.lua` — minimal hand-written protobuf wire codec (varint +
  length-delimited encode/decode). Not a general protobuf library — just
  enough for this schema; no packed-repeated or 32/64-bit fixed type
  support, since BAF's schema never uses them.
- `src/baf_protocol.lua` — builds Query/Commit messages and parses
  QueryResult responses into flat property tables, using the field-number
  schema from `aiobafi6.proto`.
- `src/baf_client.lua` — TCP client: connect, send a SLIP frame, read the
  response frame byte-by-byte until the closing delimiter (SLIP has no
  length prefix to read ahead by), close. Also handles the MORE_PUSH
  commit-and-verify pattern (LED/beep/IR/sleep mode): send an identity
  query, then the commit, then keep reading a short window for the fan's
  unsolicited push of the new value.
- `src/discovery_mdns.lua` — wraps `st.mdns.discover`, decodes TXT
  records, filters for real BAF fans, returns candidates keyed by a DNI
  derived from the fan's own `uuid` TXT record (stable across DHCP IP
  changes, unlike a DNI derived from the IP itself).
- `src/discovery.lua` — orchestrates device creation for new candidates
  and **self-heals the persisted IP** of already-known devices if mDNS
  reports a different current address (unless the user has set a real
  "Manual IP Override" value, which always wins). Also exposes
  `create_another` for the manual-fallback button.
- `src/init.lua` — lifecycle handlers, all capability command handlers,
  `ensure_light_child` (child-device creation + parent profile
  migration — now gated on the fan's own reported `has_light`/
  `has_uplight`, a direct synchronous `SENSORS` query at the decision
  point, rather than creating unconditionally; fails open on any query
  failure), the Sleep-section gating logic, `cascade_light`, the
  direction-reversal stop-first safety interlock, and polling (queries
  `FAN`, `LIGHT`, `SENSORS` each cycle, matching response frames by
  content rather than assuming send-order, wrapped in `pcall` — an
  uncaught error here would otherwise stop the recurring poll timer from
  ever registering, silently killing polling for good, not just for one
  cycle).

## Development approach: verify offline before touching the hub

Every protocol layer (SLIP framing, protobuf encode/decode, category-query
parsing, the TCP client's byte-by-byte frame reader) was unit-tested
against **real bytes captured from the actual fans** using a Lua 5.4
interpreter extracted locally via `apt-get download lua5.4 liblua5.4-0` +
`dpkg-deb -x` (no root needed) — before any of it was ever packaged or
deployed to the hub. This is a different, cheaper development loop than earlier drivers in
this workspace used, which iterated live against the hub via `logcat`
from early on. Worth reusing for future protocol-heavy drivers: get a
local interpreter, capture real traffic with a throwaway Python probe
script, and unit-test the Lua wire-format code against it directly.

## Known open items

- Only tested against two real fans, both the same model/firmware, both
  with a physical light — a no-light unit gets its light-child creation
  skipped via a real capability check (`has_light`/`has_uplight`, see
  Architecture), but that check is only verified via decode logic against
  real has-light bytes, not tested end-to-end against an actual no-light
  fan.
- `setFanSpeed` also sets `fan_mode` — a UX judgment call, not confirmed
  firmware-level coupling.
- Whoosh/eco/comfort-mode interactions with each other aren't modeled or
  tested.
- Fields seen in real `FAN` responses but not in the reference `.proto`
  are silently ignored — likely newer-firmware additions, harmless here.
- mDNS reflection across VLANs is untested with a fan actually segmented
  from the hub.
- Comfort mode and Motion-detection screen fields (occupancy timeout,
  ideal-temperature auto mode, min/max speed) were found via a packet
  capture of the official app but aren't confirmed via isolated
  single-field captures or wired into any capability yet — one live
  conflict found (field 52 guessed for both `heat_assist_reverse` and
  the already-confirmed `motion_sense_enable`, unresolved) and a
  live-diff verification method tried and ruled out (this cluster
  behaves like MORE_PUSH, invisible to any query from a separate
  connection); a real passive capture is still the only path forward.
- Schedule read/write is shipped with real auto-discovery (up to 3 named
  schedules, see the `schedule` component above) — not full schedule
  creation/editing (day/time/action), which stays a real gap, and not
  nameless (Bedtime/Wake-Up-type) schedules, which have no stable key to
  auto-discover by. Full design for going further: see
  `SCHEDULE_FEATURE_PLAN.md` (planning only, nothing built there yet).
- ~~`showSchedule`'s toggle knob rendering stuck on the right~~ —
  **RESOLVED**: this driver had no confirmed-working `displayType:
  switch` tile anywhere (see the LED/Beep/IR switch-flip history), and a
  capability's rendering is controlled entirely by its own
  `/capabilities/{id}/{version}/presentation` sub-resource, not by
  anything in a device-config's `detailView` entry. Fixed by converting
  `showSchedule` to `displayType: list` (matching `scheduleEnabled`, the
  proven-correct sibling tile) via a direct capability-presentation PUT,
  plus a new `setShowSchedule` command/handler and a fresh device-config
  vid baked from the corrected presentation. Confirmed both via API and a
  real screenshot — now renders identically to `Settings`/`Sleep Mode`,
  no knob at all.
- Fan-speed slider shows plain numeric labels (0/1/.../7) rather than
  named tiers — no established naming convention for an 8-speed fan to
  go on; open to relabeling if a better scheme comes up.
- ~~Fan-speed slider's 0-7 range/8-label override silently reverted to
  the stock 0-4 range~~ — **RESOLVED**: a device-config rebuild
  accidentally used the platform's *resolved* presentation endpoint as
  its base instead of the *raw stored* one; the resolved view never
  exposes the `values` array a standard capability's per-device slider
  override actually lives in, so every rebuild silently sent an empty
  override, dropping back to the stock 0-4 range. Fixed by rebuilding
  from the raw endpoint and restoring the original override entry;
  confirmed live (all 8 slider positions render correctly again).
- A never-populated attribute (a schedule-enabled toggle for a slot with
  no schedule at that position) could show up in the app as "This device
  hasn't updated all of its status information yet" — the platform shows
  that message for any capability with zero cached value, not just a
  slow one. Fixed by always emitting a definite value (`Off`) for an
  empty slot instead of skipping the emit, matching the pattern the
  read-only name tile already used.
