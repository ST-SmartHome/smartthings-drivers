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

### Known `Properties` field numbers

Field numbers from the fan's proto2 `Properties` message (`aiobafi6.proto`
plus fields confirmed empirically that aren't in the public reference
schema at all). "Category" is which `Query` reaches it directly — `MORE
push-only` means it's never returned by any direct query, only pushed
unsolicited after a commit on a connection that opened with an identity
query first (see `BafClient.commit_and_verify_more`).

| No. | Name | Kind | Category | Meaning |
|---|---|---|---|---|
| 1 | `name` | string | ALL | Fan's configured name |
| 2 | `model` | string | ALL | Hardware model string (e.g. "Haiku H/I Series") |
| 7 | `firmware_version` | string | ALL | e.g. "3.3.7" |
| 8 | `mac_address` | string | ALL | Fan's MAC address |
| 9 | `uuid9` | string | ALL | A device identity UUID — present in the public reference schema, purpose vs. `dns_sd_uuid` not documented anywhere |
| 10 | `dns_sd_uuid` | string | ALL | Same UUID published in the fan's mDNS TXT record — confirmed identical via a real probe. This driver currently reads that UUID at the mDNS layer for its DNI, not via this field |
| 13 | `api_version` | string | ALL | e.g. "8" |
| 43 | `fan_mode` | enum | FAN | Off/On/Auto |
| 44 | `reverse_enable` | bool | FAN | Direction (false=forward, true=reverse). Confirmed to apply with unpredictable delay, sometimes minutes — see the direction-control section below |
| 45 | `speed_percent` | int | FAN | Fan speed as 0–100% |
| 46 | `speed` | int | FAN | Fan speed, native 0–7 range |
| 52 | `motion_sense_enable` | bool | FAN | Motion/occupancy sensing master enable. Only takes effect while `fan_mode = AUTO`. Confirmed working — write applies immediately, not delayed |
| 53 | `motion_sense_timeout` | int (seconds) | FAN | How long to keep running after motion stops, once triggered by occupancy (confirmed 7200 = 2 hours on one fan's setting) |
| 58 | `whoosh_enable` | bool | FAN | Confirmed to apply with unpredictable delay, sometimes minutes — same caveat as `reverse_enable` |
| 64 | `current_rpm` | int | FAN | Live motor RPM, read-only telemetry |
| 65 | `eco_enable` | bool | FAN | Confirmed not instant — typically ~1–2 minutes to apply |
| 66 | `fan_occupancy_detected` | bool | FAN | Read-only — whether the fan currently detects motion in the room |
| 68 | `light_mode` | enum | LIGHT | Off/On/Auto |
| 69 | `light_brightness_percent` | int | LIGHT | 0–100%, maps directly to the app's brightness slider |
| 98 | `sleep_mode_enable` | bool | MORE push-only | Sleep Mode master toggle (a real physical remote button) |
| 100 | `sleep_fan_mode` | enum | FAN | Off/On/Auto — the Sleep tab's own fan-mode selector, distinct from the main `fan_mode` |
| 101 | `sleep_speed` | int | FAN | Native 0–7 — the Sleep tab's own current fan speed (shown as "Speed" on the Sleep ON-mode screen), distinct from the main `speed` field |
| 102 | `sleep_ideal_temp` | int (×100 °C) | FAN | Sleep Auto mode's target temperature (e.g. 2056 = 20.56°C) |
| 103 | `sleep_brightness_mode` | enum | LIGHT | Off/On/Auto — the light's Sleep preset |
| 104 | `sleep_brightness_percent` | int | LIGHT | 0–100%, Sleep preset brightness — pairs with `sleep_brightness_mode` the same way `wake_up_brightness` pairs with `wake_up_mode` |
| 107 | `wake_up_mode` | enum | LIGHT | Off/On/Auto — the light's Wake Up preset |
| 108 | `wake_up_brightness` | int | LIGHT | 0–100%, Wake Up preset brightness |
| 110 | `sleep_timer_enable` | bool | FAN | The Sleep tab's own on-device Timer toggle (separate from `sleep_mode_enable` and from SmartThings' unrelated generic "Timer" card) |
| 111 | `sleep_timer_end_speed` | int | FAN | Native 0–7 — the Sleep Timer's "End Speed", the target speed it gradually decreases to over `sleep_timer_duration` |
| 112 | `sleep_timer_duration` | int (seconds) | FAN | Sleep Timer's duration |
| 128 | `wake_up_motion_timeout_secs` | int (seconds) | LIGHT | Wake Up preset's post-motion timeout |
| 129 | `sleep_return_to_auto` | bool | FAN | The Auto screen's "Return to Auto" toggle — auto-reverts a manual adjustment after `sleep_return_to_auto_secs` |
| 130 | `sleep_return_to_auto_secs` | int (seconds) | FAN | Duration for the above |
| 134 | `led_indicators_enable` | bool | MORE push-only | LED indicators on/off |
| 135 | `fan_beep_enable` | bool | MORE push-only | Fan beep on/off |
| 136 | `legacy_ir_remote_enable` | bool | MORE push-only | Legacy IR remote support on/off |

Separately, `QueryResult.schedules` (field 3, unmodeled in every public
reference project) carries a `Schedule` message per configured on-device
schedule — its own `action` sub-field uses field numbers 5 (light mode
enum) and 18 (`light_auto_motion_timeout` in seconds) when the light
action is Auto. These live inside a completely different nested message
from the `Properties` table above — the field numbers coincidentally
overlapping with unrelated `Properties` fields is not a conflict, just
two independent numbering spaces. The schedule **write** path (creating/
editing a schedule entry) remains completely unknown — see Known open
items.

## Architecture

- `config.yml` — `lan` + `discovery` permissions.
- `search-parameters.yml` — gates the hub's pre-scan on the `_api._tcp`
  mDNS service, so `discovery_handler` only fires when something matching
  is actually present.
- `profiles/bigassfans-h.yml` — five components:
  - `main` (labeled "Fan+Light" on the live no-light-no-addfan variant)
    — `switch`, `fanMode` (Off/On/Auto, placed above `fanSpeed`),
    `fanSpeed` (native range 0–7, not a percentage), `refresh`,
    `fanDirection` (Forward/Reverse), `whoosh` (Off/On), `ecoMode`
    (Off/On). The plain On/Off switch and Fan Mode's Off transition both
    cascade to the light child device too (a second, separate LIGHT-
    category commit, never merged into the fan's own FAN-category one —
    see `cascade_light` in `init.lua`), so turning the fan off from
    either control turns the light off as well, and back on again.
    `sleepMode` moved to the `sleep` component — see below.
  - `light` — `switch`, `switchLevel` (0–100%, maps directly to the
    device's own `light_brightness_percent` field, no scaling needed).
  - `management` — `aboutisland47519.addAnotherFan`, the same custom
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
    incompatibilities). Since `sleepMode` and `sleepAutoMode`/
    `sleepBrightnessMode`/`wakeUpMode` are independent fields with no
    real coupling in the protocol, three headless "gate" capabilities
    (`sleepAutoModeGate`, `sleepBrightnessModeGate`, `wakeUpModeGate` —
    never rendered themselves, no presentation) fold `sleepMode`'s state
    into a value the sub-fields' `visibleCondition`s can actually chain
    on; each fails *open* (stays visible) if `sleepMode`'s own MORE-push
    value hasn't been captured yet, rather than collapsing the whole
    section on every driver restart.
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
  killing polling for good, not just for one cycle).

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

- Only tested against two real fans, both the same model/firmware —
  behavior on other Haiku/i6 models (e.g. no light kit) is unconfirmed.
- `setFanSpeed` also sets `fan_mode` (nonzero → ON, zero → OFF), a UX
  choice, not a confirmed firmware coupling.
- Whoosh/eco/comfort-mode interactions with each other aren't modeled.
- Fields seen in real `FAN` responses but missing from the reference
  `.proto` (e.g. 207) are silently ignored.
- mDNS reflection across VLANs depends on your router's multicast-DNS
  setting — untested with the fan on a different VLAN from the hub.
- No write path for the fan's own on-device schedule — a packet capture
  showed schedule edits go through BAF's cloud API, not this driver's
  local protocol.
- Motion sensing (field 52) works at the protocol level but isn't
  exposed as a SmartThings capability yet.
