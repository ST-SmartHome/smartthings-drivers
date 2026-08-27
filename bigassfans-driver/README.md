# bigassfans-i6-lan

LAN Edge Driver for Big Ass Fans Haiku H/I Series ceiling fans, controlling
them over their local "i6" protocol (SLIP-framed protobuf over TCP, port
31415) — no cloud dependency, no authentication of any kind.

## Status: working end-to-end

Deployed as `bigassfans-i6-lan`, driverId
`e39b708d-4db9-4c7b-a76c-0d04e5fdcdd9`, channel `Drivers`
(`781ea3f1-a95c-492f-9952-59ef19f43505`), hub
`c215e4a2-98e7-4272-9cd8-ebf178079631` — same channel/hub as
other drivers in this account. Current profile: `bigassfans-h.v1`.

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

## Architecture

- `config.yml` — `lan` + `discovery` permissions.
- `search-parameters.yml` — gates the hub's pre-scan on the `_api._tcp`
  mDNS service, so `discovery_handler` only fires when something matching
  is actually present.
- `profiles/bigassfans-h.yml` — three components:
  - `main` — `switch`, `fanSpeed` (native range 0–7, not a percentage),
    `refresh`, and three custom capabilities: `fanMode` (Off/On/Auto),
    `fanDirection` (Forward/Reverse), `whoosh` (Off/On), `ecoMode`
    (Off/On).
  - `light` — `switch`, `switchLevel` (0–100%, maps directly to the
    device's own `light_brightness_percent` field, no scaling needed).
  - `management` — `aboutisland47519.addAnotherFan`, the same custom
    capability (and already-correct presentation) reused from
    another driver in this workspace — capability IDs are account-wide,
    not per-driver.
  - One preference: "Manual IP Override" (`ipAddress`, sentinel
    `0.0.0.0` meaning "use the mDNS-discovered address"), plus
    `pollInterval`. No secrets to enter — see protocol notes above.
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
  length prefix to read ahead by), close.
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
  polling (queries `FAN` then `LIGHT` each cycle, wrapped in `pcall` — an
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

- Only tested against two real fans, both the same model/firmware.
  Behavior on other Haiku/i6 models (e.g. ones without a light kit) is
  unconfirmed.
- `setFanSpeed` also sets `fan_mode` (nonzero speed → ON, zero → OFF) —
  a UX judgment call, not a confirmed device behavior. The protocol keeps
  `speed` and `fan_mode` as genuinely separate properties; whether the
  firmware itself couples them isn't verified.
- Whoosh/eco/comfort-mode interactions with each other aren't modeled or
  tested — e.g. what happens if eco and whoosh are both on.
- Fields seen in real `FAN` responses but not in the reference `.proto`
  (e.g. field 207) are silently ignored — likely properties added by
  firmware newer than the library's schema capture, harmless to ignore
  for this driver's scope.
- mDNS reflection across VLANs depends on the network's "Multicast DNS"
  setting (a UniFi-specific term, may vary by router/controller) —
  confirmed enabled network-wide on the network this was tested on, but
  not empirically tested with a fan actually segmented onto a different
  VLAN from the hub (both fans tested are on the same network as each
  other and, presumably, the hub).
