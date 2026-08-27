# se-modbus-v4

LAN Edge Driver for a SolarEdge inverter, controlling it over local Modbus
TCP (SunSpec) rather than through SolarEdge's cloud API — no cloud
dependency once set up.

**Discovery**: SolarEdge's Modbus TCP service is a passive server with no
broadcast/SSDP announcement of its own, so this driver doesn't gate
discovery on any network signal — `discovery.lua` creates exactly one
device unconditionally whenever discovery runs (i.e. whenever "Scan
Nearby" is triggered), with a placeholder network ID. The real IP/port/
unit ID are then entered by hand as device **preferences** after the
device is created — see `profiles/solaredge-inverter.yml`. `init.lua`'s
`infoChanged` handler picks up preference changes and (re)starts polling
against the configured address.

## Grid import/export meter (optional hardware)

If your installation has a SolarEdge production/consumption meter attached
(SunSpec model 201–204 — many residential installs do), the driver reads
it automatically alongside the inverter, in the same Modbus session, and
exposes it as a second `grid` component:

- **`powerMeter`** — net grid power, **signed**: negative = importing
  from the grid, positive = exporting surplus. This already nets out
  household consumption, so it's the right value to use for a "don't run
  this unless there's solar surplus" style condition — don't use the
  inverter's own production figure for that, it doesn't account for what
  the house itself is drawing.
- **`aboutisland47519.gridEnergy`** (custom capability) — lifetime
  exported/imported energy.

No meter present is a normal, fully-supported case — the driver detects
this at read time and simply omits the `grid` component's readings
rather than erroring. The `grid` component shows up as its own
selectable condition in SmartThings Routines, confirmed via the app.

## Files

- `config.yml` — driver metadata, `lan` + `discovery` permissions.
- `profiles/solaredge-inverter.yml` — capabilities (powerMeter, energyMeter,
  temperatureMeasurement, refresh) and the IP/port/unitId/pollInterval
  preferences. The `grid` component (see above) is declared here too.
- `src/discovery.lua` — unconditional single-device creation.
- `src/init.lua` — lifecycle handlers, preference-driven polling loop.
- `src/modbus.lua` — minimal Modbus TCP client (Read Holding Registers only,
  function code 0x03). Hand-rolled, since the Edge Driver Lua sandbox has no
  Modbus library — uses `cosock.socket` for the raw TCP connection.
- `src/solaredge.lua` — SunSpec inverter model (101/103) register map and
  scale-factor math, plus the optional meter model (201–204) read for the
  grid import/export figures above.

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
