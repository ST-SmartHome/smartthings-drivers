# [LAN Driver] Big Ass Fans Haiku H/I Series via local "i6" protocol (auto-discovered, zero config)

Controls Big Ass Fans **Haiku H/I Series** ceiling fans (the models running
firmware 3.0+, "i6" API — not the older SenseME app generation) entirely
over the **local LAN** — no cloud account, no app pairing dance, and
**nothing to type in**. Fan on/off, speed (0-7 native range), mode
(Off/On/Auto), direction, whoosh, eco, plus the light's on/off and
brightness.

**Channel invite**: https://bestow-regional.api.smartthings.com/invite/RBlE0gaNvL2E

Tested against two Haiku H/I Series fans, firmware 3.3.7, api_version 8.

## Requirements

- A Haiku H/I Series fan on firmware 3.0+ (the "i6" protocol generation —
  see "Which fans this supports" below if you're not sure which you have).
- The fan already joined to your Wi-Fi (via the Haiku Home app, one-time
  setup — this driver doesn't do initial provisioning, only ongoing
  control).
- A SmartThings Hub on the same network as the fan.

## Setup

**Add Device → Scan Nearby.** That's it. The fan gets discovered and
fully configured automatically — no IP address, no key, nothing to type.
If you get more fans later, they get picked up automatically too on a
later scan; there's no button to press.

(There's a "Manual IP Override" preference on each device if a specific
fan ever isn't showing up automatically — see "Known limitations" — but
it's not part of the normal flow.)

## Why this one's fully automatic (unlike most LAN drivers here)

Big Ass Fans' local protocol turned out to be a genuinely nice surprise:
the fan advertises itself over standard **mDNS** (`_api._tcp.local.`),
and there's **no authentication or pairing secret of any kind** — anyone
on the LAN who can reach the fan's IP on port 31415 can query and control
it. SmartThings Edge Drivers have native platform support for mDNS
discovery, so this driver just asks the platform "find me anything
advertising `_api._tcp`," filters the results down to actual Haiku fans
(checking the advertised model name, since `_api._tcp` alone is a pretty
generic service name other things could theoretically use), and creates
a fully-working device with zero further input.

This is a real contrast with this account's other drivers for similarly
"dumb," un-cloud-integrated fans (a Tuya-based driver, also posted on this
channel) — Tuya's local discovery is a proprietary broadcast format on a
proprietary port that SmartThings' discovery-gating has no way to hook
into, so that one needs IP/key entered by hand per device. Not every LAN
protocol is equally friendly to this platform; this one happened to be.

## Protocol notes, for anyone curious or extending this

- Transport: plain TCP, port 31415, SLIP-framed (RFC 1055) protocol
  buffer messages — this driver hand-rolls both the SLIP framing and a
  minimal protobuf codec in pure Lua (no external deps), since neither
  exists in the Edge Driver Lua environment.
- The protocol's own "ALL" query category is a bit of a trap — despite
  the name, it only returns general/identity fields (model, firmware
  version, MAC), not fan or light state. Those need separate `FAN`- and
  `LIGHT`-category queries, confirmed by direct probing rather than any
  documentation (there isn't much).
- Schema reverse-engineered from `jfroy/aiobafi6`'s `.proto` file
  (credit where due — didn't reverse-engineer this from raw packet
  captures myself, that project already did the hard part).

## Known limitations

- **No color temperature control.** Deliberate, not missing: this
  household's fans have a fixed-temperature bulb (confirmed via a live
  query — warmest and coolest color temp report the same value), and the
  physical remote doesn't expose that control either. If your fan's light
  kit actually supports tunable white, this driver won't control it —
  would be a small addition if anyone needs it.
- Setting fan speed to a nonzero value also turns the fan on, and zero
  turns it off — a UX choice on my part, not a confirmed device behavior.
  The protocol keeps speed and on/off as genuinely separate properties.
- Only tested against two fans, same model/firmware. If you try it on a
  different Haiku/i6 model (especially one without a light kit) and hit
  something broken, I'd like to hear about it.
- mDNS discovery relies on your network actually passing mDNS traffic
  between the hub and the fan — if they're on different VLANs without
  multicast/mDNS reflection enabled, discovery won't find it and you'd
  need the manual IP override.

## Source

Happy to share the source if anyone wants to read/modify it — just ask.
Same as the other drivers on this channel, not posted inline here (a
handful of Lua files plus a device profile).
