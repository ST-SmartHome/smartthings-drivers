# se-modbus-v4

Fresh rebuild of the SolarEdge → SmartThings LAN Edge Driver, after the
previous project (`se-modbus-v2`/`se-modbus-v3`) was wiped locally. The
packaged `se-modbus-v3` driver still exists in the SmartThings developer
account (driverId `1fcf8e8e-de05-4ae6-8a7d-a2cc860d5f96`, channel `Drivers`)
and is installed on the hub — this rebuild is a replacement, not a patch of
that package.

## What changed vs. the previous version

The previous version had two separate bugs, found in order:

1. **Missing `discovery: {}` permission** in `config.yml` — fixed in
   `se-modbus-v3`, confirmed present in the packaged version still on the
   hub.
2. **Discovery gated on SSDP via `search-parameters.yml`** — the hub only
   ran the driver's discovery code when it saw SSDP traffic matching the
   configured search term. SolarEdge's Modbus TCP service never sends SSDP
   (or any broadcast) — it's a passive server that "waits for a client to
   connect." So the driver was never invoked at all. Confirmed via a live
   `logcat` capture during an actual "Add Device" attempt: zero log lines,
   not even an error — the code path was never reached.

This rebuild fixes #2 architecturally: there is no `search-parameters.yml`
at all. `discovery.lua` creates exactly one device unconditionally whenever
discovery runs (i.e. whenever "Scan Nearby" is triggered), with a
placeholder network ID. The real IP/port/unit ID are then entered by hand as
device **preferences** after the device is created — see
`profiles/solaredge-inverter.yml`. `init.lua`'s `infoChanged` handler picks
up preference changes and (re)starts polling against the configured address.

## Files

- `config.yml` — driver metadata, `lan` + `discovery` permissions.
- `profiles/solaredge-inverter.yml` — capabilities (powerMeter, energyMeter,
  temperatureMeasurement, refresh) and the IP/port/unitId/pollInterval
  preferences.
- `src/discovery.lua` — unconditional single-device creation.
- `src/init.lua` — lifecycle handlers, preference-driven polling loop.
- `src/modbus.lua` — minimal Modbus TCP client (Read Holding Registers only,
  function code 0x03). Hand-rolled, since the Edge Driver Lua sandbox has no
  Modbus library — uses `cosock.socket` for the raw TCP connection.
- `src/solaredge.lua` — SunSpec inverter model (101/103) register map and
  scale-factor math.

## Status: working, verified live (2026-08-03)

Confirmed via live `logcat` against the real inverter (SE5000AU) — power,
lifetime energy, DC voltage/power, temperature, and status all reporting
sane, stable values across multiple poll cycles, and visible in the
SmartThings app. Example log line shape (values illustrative, not a real
reading):

```
SolarEdge reading: <W>W, <Wh> lifetime, <V> DC, <W> DC, <°C>, status=MPPT
```

Deployed as `se-modbus-v4`, driverId `f96cdedb-9d98-4834-96f4-3af2aab8fecb`,
channel `Drivers` (`781ea3f1-a95c-492f-9952-59ef19f43505`), installed on hub
`c215e4a2-98e7-4272-9cd8-ebf178079631`. Device: "SolarEdge Inverter"
(`acfad246-65c6-4af5-9bb9-fb21f4e633a6`), preferences set to
`192.168.1.100:1502` (placeholder — real LAN IP set per-install), unit id `1`, 30s poll interval.

### Bugs found and fixed along the way (in order)

1. `config.yml` `permissions` needed a mapping (`lan: {}` / `discovery: {}`),
   not a list — caught at packaging.
2. Device profile category `Other` isn't valid — used `SolarPanel`.
3. **The actual original bug**: `search-parameters.yml` gated discovery on
   SSDP traffic the inverter's passive Modbus TCP service never sends —
   driver was simply never invoked. Fixed by dropping network-gated
   discovery entirely in favor of unconditional single-device creation +
   IP/port entered as a device preference afterward.
4. `discovery.lua`'s "does it already exist" check called
   `get_device_info()` with a network-id string instead of a device UUID —
   harmless (platform's own DNI-collision check prevented duplicates
   anyway) but logged an error every run. Fixed to check `driver:get_devices()`.
5. Hardcoded inverter-model base address (documented 40069) was wrong for
   this device — produced sentinel/garbage values (0x8000, NaN, -inf).
   Replaced with a proper SunSpec model-chain walk (`sunspec.lua`) that
   locates Model 101/102/103 dynamically. Actual address on this unit:
   wire 69.
6. Off-by-one in the temperature/status offsets — a phantom "reserved"
   register that doesn't exist in the real spec shifted every field from
   `DCW_SF` onward by one register (`53060000.0C`, `status=UNKNOWN(0)`).
   Removed the phantom offset.
7. Cabinet temperature slot specifically was the SunSpec "not implemented"
   sentinel (`-32768` raw) on this inverter — this unit populates the Heat
   Sink slot instead. Now reads all four temperature slots and uses the
   first non-sentinel one.

Also added: a defensive bounds check before emitting temperature (matching
the platform's own `-460..10000` constraint), since bug #6 crashed the
device's event thread when the platform rejected an out-of-range value —
better to skip and log a bad reading than repeat that.

## Remaining open items

- **Status capability**: `I_Status` (OFF/SLEEPING/STARTING/MPPT/THROTTLED/
  SHUTTING_DOWN/FAULT/STANDBY) is read and logged but not yet exposed as a
  SmartThings capability — no perfect standard capability fits inverter
  operating state. Worth a custom capability later if you want it visible
  in the app rather than just logs.
- **Single Modbus connection at a time**: if anything else (Home Assistant,
  etc.) polls this inverter's Modbus TCP service, this driver's connection
  attempts will conflict with it.
- The `SolarEdge Modbus` (`solaredge-modbus-tcp`) and `se-modbus-v3`
  packages from the earlier attempt are still registered in the account and
  installed on the hub — worth deleting once you're confident `se-modbus-v4`
  is stable, so there aren't three near-duplicate drivers lying around.

## Useful commands

```bash
cd se-modbus-driver  # wherever you cloned this repo

# repackage + reassign + reinstall after any further code change
smartthings edge:drivers:package . --token <pat>
smartthings edge:channels:assign f96cdedb-9d98-4834-96f4-3af2aab8fecb --channel 781ea3f1-a95c-492f-9952-59ef19f43505 --token <pat>
smartthings edge:drivers:install f96cdedb-9d98-4834-96f4-3af2aab8fecb --hub c215e4a2-98e7-4272-9cd8-ebf178079631 --channel 781ea3f1-a95c-492f-9952-59ef19f43505 --token <pat>

# live logs
smartthings edge:drivers:logcat f96cdedb-9d98-4834-96f4-3af2aab8fecb --hub-address <your-hub-ip> --token <pat>
```
