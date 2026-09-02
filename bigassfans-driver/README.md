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
api_version 8) were auto-discovered via mDNS on the first
scan and confirmed fully working: every capability (fan switch/speed/mode/
direction/whoosh/eco, light switch/brightness) reads and writes correctly
against the real devices.

## Protocol details (confirmed empirically against two real fans, not from docs alone)

- **Transport**: plain TCP to port 31415, one connection per request.
- **Framing**: SLIP (RFC 1055) — `0xC0` start/end delimiters, `0xDB`
  escape sequences for literal `0xC0`/`0xDB` bytes in the payload.
- **Payload**: proto2 protobuf, `Root{ root2: Root2{ query | commit } }`.
  Full schema in `src/baf_protocol.lua`'s `FIELDS` table and comments;
  originally sourced from `jfroy/aiobafi6`'s `proto/aiobafi6.proto`.
- **`ALL` doesn't mean all** — despite its name, an `ALL`-category query
  only returns general/identity properties (model, firmware_version,
  mac_address, api_version), confirmed by direct probing since it's
  undocumented anywhere. Fan properties need their own `FAN`-category
  query, light properties their own `LIGHT`-category one — this driver
  queries both every poll cycle.
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

### Known `Properties` field numbers

Full field-by-field reference (confirmed fields, the `Capabilities`
submessage, and unconfirmed candidates) moved to
[`PROTOCOL.md`](PROTOCOL.md) once the table grew past 30 rows. Short
version: fields are grouped by which `Query` category reaches them
directly (`ALL`/`FAN`/`LIGHT`/etc.), with a `MORE push-only` category for
fields never returned by any direct query, only pushed unsolicited after
a commit on a connection that opened with an identity query first.

## Architecture

- `config.yml` — `lan` + `discovery` permissions.
- `search-parameters.yml` — gates the hub's pre-scan on the `_api._tcp`
  mDNS service, so `discovery_handler` only fires when something matching
  is actually present.
- `profiles/bigassfans-h.yml` — five components:
  - `main` (labeled "Fan+Light" on the two variants with a light child
    device) — `switch`, `fanMode` (Off/On/Auto, placed above `fanSpeed`),
    `fanSpeed` (native range 0–7, not a percentage — the stock capability
    only defines display labels up to its own default 0–4 range, so this
    driver adds its own 8-entry label override, plain numbers rather than
    invented tier names since there's no established naming convention
    for an 8-speed fan), `refresh`,
    `fanDirection` (Forward/Reverse), `whoosh` (Off/On), `ecoMode`
    (Off/On). The plain On/Off switch and Fan Mode's Off transition both
    cascade to the light child device too (a second, separate LIGHT-
    category commit, never merged into the fan's own FAN-category one —
    see `cascade_light` in `init.lua`), so turning the fan off from
    either control turns the light off as well, and back on again.
    `sleepMode` moved to the `sleep` component — see below.
  - `light` — `switch`, `switchLevel` (0–100%, maps directly to the
    device's own `light_brightness_percent` field, no scaling needed).
  - `management` — `addAnotherFan`, the same custom
    capability (and already-correct presentation) reused from
    another driver in this workspace — capability IDs are account-wide,
    not per-driver.
  - `settings` — one-off configuration toggles rather than everyday
    controls, rendered as native switch toggles (not the list-style
    dropdown some of this driver's other custom capabilities use):
    `ledIndicators`, `fanBeep`, `legacyIrRemote` (Off/On), plus
    `temperatureMeasurement` (ambient reading, field 86 — see the field
    table above). A `showSettings` phantom capability ("Show"/"Hide" —
    pure local UI state, no protocol commit at all) sits first and gates
    the other four via `visibleCondition`, same purpose as `sleepMode`'s
    gating tree below but simpler to reason about: nothing to fail open
    around, since there's no real hardware value it could ever be
    waiting on. A native switch toggle needs two separate zero-arg
    commands (`turnOn`/`turnOff`), not one command taking a value —
    these three capabilities carry both the original `setXxx(value)`
    command and the newer `turnOn`/`turnOff` pair; only the latter is
    wired to the current presentation.
  - `sleep` — the Sleep tab's own sub-settings (see the field table
    above for exact numbers): `sleepMode` (the master Sleep Mode switch,
    a physical remote button — MORE-push only, same mechanism as
    `ledIndicators`/etc above, unlike everything else in this list),
    `sleepAutoMode` (Off/On/Auto fan mode) + `sleepSpeed`,
    `sleepIdealTemperature`, `sleepTimer` + `sleepTimerEndSpeed` +
    `sleepTimerDuration`, `sleepReturnToAuto` +
    `sleepReturnToAutoDuration`, `sleepBrightnessMode` (Off/On/Auto, the
    light's Sleep preset) + `sleepBrightnessPercent`,
    `wakeUpMode`/`wakeUpBrightness`/`wakeUpMotionTimeout` (the light's
    Wake Up preset). All but `sleepMode` are directly queryable under
    FAN/LIGHT — no MORE-push mechanism needed, just the normal
    commit-then-verify path.

    The whole section collapses down to just the `sleepMode` tile when
    Sleep Mode is off, via a hand-assembled `visibleCondition` Device
    Configuration (`config.yml`'s embedded `config:` block doesn't
    support this — see the code comments in `init.lua`/
    `apply_sleep_status` for the full mechanism and its platform
    incompatibilities). `sleepMode` is deliberately placed *first* in the
    `sleep` component and left ungated: the platform can never fully hide
    a section's first `detailView` tile at all (confirmed via a live
    position-swap test — it renders disabled instead, regardless of
    `hideOnUnmatch` or what references it), so an always-visible anchor
    tile is required to free every other field to hide correctly. Since
    `sleepMode` and `sleepAutoMode`/`sleepBrightnessMode`/`wakeUpMode` are
    independent fields with no real coupling in the protocol, four
    headless "gate" capabilities (`sleepAutoModeGate`,
    `sleepBrightnessModeGate`, `wakeUpModeGate`, `wakeUpBrightnessGate` —
    never rendered themselves, no presentation) fold `sleepMode`'s state
    into a value the sub-fields' `visibleCondition`s can actually chain
    on; each fails *open* (stays visible) if `sleepMode`'s own MORE-push
    value hasn't been captured yet, rather than collapsing the whole
    section on every driver restart. `wakeUpBrightnessGate` exists
    specifically because `visibleCondition` only ever accepts a single
    `EQUALS` operand (`ONE_OF`/`NOT_EQUALS` both get real `400`s) —
    `wakeUpBrightness` needs to show for both `wakeUpMode` "On" and
    "Auto", so this gate folds both into a single "On" value for it to
    match against.
  - Preferences: "Manual IP Override" (`ipAddress`, sentinel
    `0.0.0.0` meaning "use the mDNS-discovered address"), `pollInterval`,
    "Hide 'Add Another Fan' Button" (`hideAddFan`), and "No Physical
    Light" (`noLight`). No secrets to enter — see protocol notes above.
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
  length prefix to read ahead by), close. `query_multi` (multi-category
  reads) matches each response frame to a category by its actual field
  content, not by assuming the Nth frame read answers the Nth query sent
  — a real off-by-one response lag was found in the fan's back-to-back-
  query behavior on one connection (confirmed against the real deployed
  code; affected the plain 2-category `FAN`+`LIGHT` poll this driver
  already shipped, not just a newly-added third category — masked there
  because the verify-after-command path only ever queries one category
  alone, which isn't affected).
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
  polling (queries `FAN`, `LIGHT`, and `SENSORS` each cycle over one
  shared connection, wrapped in `pcall` — an uncaught error here would
  otherwise stop the recurring poll timer from ever registering, silently
  killing polling for good, not just for one cycle). `ensure_light_child`
  checks the fan's own reported `has_light`/`has_uplight` (a nested
  `capabilities` submessage, SENSORS category field 17) before creating
  a light-child device at all, rather than doing so unconditionally —
  a direct synchronous query at the point of decision, since it runs
  before the first poll cycle ever completes and there's no cached data
  to check yet on a fan's first pairing. Fails open (creates the light
  child, prior behavior) on any query failure — only a successful query
  that positively reports no light skips creation.

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
  with a physical light — a no-light unit gets its light-child device
  creation skipped via a real capability check (see Architecture), but
  that check has only been verified via decode logic against real
  has-light bytes, not tested end-to-end against an actual no-light fan.
- `setFanSpeed` also sets `fan_mode` (nonzero → ON, zero → OFF), a UX
  choice, not a confirmed firmware coupling.
- Whoosh/eco/comfort-mode interactions with each other aren't modeled.
- Fields seen in real `FAN` responses but missing from the reference
  `.proto` (e.g. 207) are silently ignored.
- mDNS reflection across VLANs depends on your router's multicast-DNS
  setting — untested with the fan on a different VLAN from the hub.
- Schedule *read* is decoded and confirmed live. Schedule *write* is now
  decoded too (`Commit`'s field 4 — see `baf_protocol.lua`'s "Schedule
  write path" comment for the full write-up), confirmed via a real pcap
  of the app creating, editing, and deleting schedule entries — an
  earlier claim that schedule writes go through BAF's cloud API instead
  was too broad, based on one screen that happened not to show it. Not
  yet built as a real capability; `build_commit` also needs new nested-
  message encode support first, not just a new `FIELDS` entry.
- Motion sensing (field 52) works at the protocol level but isn't
  exposed as a SmartThings capability yet.
