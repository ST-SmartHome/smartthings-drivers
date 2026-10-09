# bigassfans-i6-lan

SmartThings Edge driver for Big Ass Fans Haiku H/I Series ceiling fans. Uses the fan's local "i6" protocol (SLIP-framed protobuf over TCP 31415); no cloud, no login.

Community thread: https://community.smartthings.com/t/st-edge-driver-big-a-fans-haiku-h-i-series-via-local-i6-protocol/310526

## Features

- Fan: on/off, speed (0–7), mode (Off/On/Auto), direction, Whoosh, Eco.
- Light: on/off and brightness, as its own SmartThings device (so Alexa and Google see it). The fan's main switch also switches the light.
- Collapsible sections:
  - Sleep;
  - Comfort (ideal temperature, min/max speed);
  - Heat Assist;
  - Motion (timeout, unoccupied behaviour);
  - Return to Auto;
  - Settings (LED indicators, beep, IR remote, temperature);
  - Schedules (enable/disable up to 5 named on-fan schedules).
- Temperature from the fan's built-in sensor.
- Direction changes stop the fan first.

## Setup

**Add Device → Scan Nearby.** Fans are found automatically over mDNS (`_api._tcp`, filtered on model "Haiku"), and follow DHCP address changes.

Settings:
- **Manual IP Override**: `0.0.0.0` means use discovery.
- **Poll Interval**.
- **No Physical Light**.
- **Hide 'Add Another Fan' Button**: the button covers fans that discovery misses.

## Limitations

- Schedules: only named schedules, at most 5 per fan (the first 5 alphabetically), enable/disable only. Creating or editing them, and Bedtime/Wake-Up schedules, aren't supported.
- Direction, Whoosh and Eco can take up to a few minutes to apply on the fan. This is firmware behaviour.
- Discovery across VLANs (mDNS reflection) is untested.
- Tested on two fans, both with lights, firmware 3.3.7.

## Protocol

[PROTOCOL.md](PROTOCOL.md) lists every confirmed field number. Key points:

- Plain TCP, one connection per request. SLIP framing (RFC 1055). The payload is proto2 `Root{root2{query|commit}}`, based on [jfroy/aiobafi6](https://github.com/jfroy/aiobafi6).
- An `ALL` query returns identity only. Fan and light state need `FAN`/`LIGHT` queries.
- Fields at their default value are omitted from replies.
- LED, beep, IR and sleep-mode fields are never returned by a query. The fan only pushes them after a commit on a connection that opened with an identity query.

## Source

- `src/slip.lua`, `src/protobuf.lua`: framing and a minimal protobuf codec.
- `src/baf_protocol.lua`: field table, query/commit builders, reply parsing.
- `src/baf_client.lua`: TCP client, including commit-and-verify for push-only fields.
- `src/discovery_mdns.lua`, `src/discovery.lua`: mDNS discovery keyed on the fan's UUID.
- `src/init.lua`: handlers, polling, light child devices, section gating.
