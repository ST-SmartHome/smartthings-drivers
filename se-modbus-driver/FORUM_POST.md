# [LAN Driver] SolarEdge Inverter via local Modbus TCP (SunSpec)

Reads live power, lifetime energy, DC voltage/power, temperature, and
operating status from a SolarEdge inverter over its **local Modbus TCP**
interface — no cloud dependency, no SolarEdge API key or monitoring-portal
rate limits. If you have a SolarEdge production/consumption meter attached
(e.g. the SE-RGMTR series), it also reads live net grid power (import vs.
export) and lifetime exported/imported energy as a separate "Grid" component
— read-only, detected automatically at startup, no config needed.

**Channel invite**: https://bestow-regional.api.smartthings.com/invite/RBlE0gaNvL2E

Tested against an **SE5000AU** (single-phase, SunSpec Model 101). Should
work on any SolarEdge inverter with Modbus TCP enabled and reachable on
your LAN — SunSpec's inverter model (101/single-phase, 102/split-phase,
103/three-phase) shares the same register layout, and the driver locates it
dynamically rather than assuming a fixed address (see "Notes for other
models" below).

## Requirements

- SolarEdge inverter with Modbus TCP enabled (on the inverter: Communication
  → LAN Conf → Modbus TCP). Disabled by default.
- Known LAN IP of the inverter, and its Modbus TCP port (usually 502, some
  units/firmware use 1502 — check yours).
- A SmartThings Hub (this is a Hub-local LAN Edge Driver, not cloud-connected).

## Setup

1. Accept the channel invite above and enroll your hub.
2. Install the driver ("SE Modbus" or similar) from the channel onto your hub.
3. In the SmartThings app: **Add Device → Scan Nearby**. It should offer a
   generic "SolarEdge Inverter" device immediately — this driver doesn't wait
   on any network broadcast (see why, below), so there's no scan delay.
4. Add it, then open its **device settings** and fill in your inverter's IP,
   Modbus port, and unit ID (SolarEdge's default unit ID is `1`). Save.
5. Polling starts automatically on save, on the interval you set (default 30s).

## Why this exists / what's different from a "normal" LAN driver

Most SmartThings LAN drivers use `search-parameters.yml` to gate discovery
on SSDP or mDNS traffic — the hub only bothers running your driver's
discovery code when it sees a matching network broadcast, which saves
resources. **SolarEdge's Modbus TCP service never broadcasts anything** —
per SolarEdge's own docs, it's a passive server that "does not initiate a
connection... waits for a client to connect." A driver gated on SSDP for a
device like this will *never* be invoked — confirmed the hard way, via a
live `logcat` capture during an actual "Add Device" attempt that produced
zero log lines.

This driver doesn't use `search-parameters.yml` at all. Discovery
unconditionally offers one device when triggered, and you supply the real
IP as a device preference afterward. If you're adapting this pattern for
another self-announcing-nothing LAN device, that's the part worth copying.

(Worth being precise about *why* stock drivers gate on SSDP/mDNS in the first
place, credit to a community reply for the correction: it's because they're
installed automatically on every single hub, so without gating, every hub
would offer to create devices for protocols the user might not even own
hardware for. A community driver is opt-in — you only install it if you
already know you have the device — so that particular problem doesn't apply
here, and unconditional discovery is the simpler, correct choice rather than
a compromise standing in for the "real" pattern.)

## Notes for other SolarEdge models / three-phase units

- The driver walks the SunSpec model chain (reads the `SunS` identifier,
  then follows the model header chain) to find the Inverter model (101/102/
  103) rather than assuming a fixed register address — this varies by
  device/firmware, don't hardcode it.
- SunSpec defines four temperature slots (Cabinet/Sink/Transformer/Other);
  vendors typically populate only one, leaving the rest at the "not
  implemented" sentinel value. This driver reads all four and uses whichever
  one actually has data — on the SE5000AU tested, that's the Heat Sink slot,
  not Cabinet.
- On the inverter side, only reads total AC power, lifetime energy, DC
  voltage/power, temperature, and status — doesn't currently read per-phase
  voltage/current (relevant mainly for three-phase units). Would be a
  straightforward addition using the same model-relative offset pattern in
  `src/solaredge.lua` if anyone wants it. (The optional grid meter, below,
  is a separate thing and already implemented.)

## Grid meter (optional)

If a SunSpec meter model (201/202/203/204) is found in the Modbus chain
right after the inverter model, the driver reads it in the *same* Modbus
session (see "known limitations" below on why) and exposes it as a second
"Grid" component:

- **Power meter**: net grid power in watts, signed — negative means
  importing from the grid (consuming), positive means exporting (selling
  back). Confirmed against a live overnight reading (inverter asleep, 0W
  production) showing a negative value matching real household draw.
- **Grid Energy**: lifetime exported and imported totals in kWh, as two
  separate read-only values (a custom capability — SmartThings has no
  standard capability for this).

No meter, no component — this degrades cleanly, it's not a hard requirement.

## Known limitations

- SolarEdge inverters accept **one Modbus TCP connection at a time** — if
  you already have something else (Home Assistant, etc.) polling the same
  inverter, this driver's connection attempts will conflict with it. This is
  also why the grid meter is read in the same connection as the inverter
  data rather than a second one.
- Operating status (OFF/SLEEPING/STARTING/MPPT/THROTTLED/SHUTTING_DOWN/
  FAULT/STANDBY) is exposed as a free-text custom capability ("Inverter
  Status") rather than a strict enum — there's no great standard capability
  fit for inverter operating state, and SmartThings doesn't support custom
  enum-typed attributes as cleanly as free text.

## Source

Happy to share the source directly if anyone wants to read/modify it —
just ask. (Not posted inline here since it's a few hundred lines across
`config.yml`, a device profile, and five Lua files.)
