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
  preferences. The `grid` and `dc` components (see above) are declared
  here too.
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

Deployed as `se-modbus-v4`. Device preferences take an IP:port
(sentinel `192.168.1.100:1502` — real LAN IP set per-install), Modbus
unit ID (typically `1`), and poll interval (30s by default).

### What shows up in the SmartThings app

| Component | Capability | Shows |
|---|---|---|
| `main` | `powerMeter` | Live inverter output power (W) |
| `main` | `energyMeter` | Lifetime energy produced (kWh) |
| `main` | `temperatureMeasurement` | Inverter temperature (°C) |
| `main` | `aboutisland47519.inverterStatus` | Operating status (MPPT/THROTTLED/FAULT/etc — see below) |
| `main` | `refresh` | Manual refresh button |
| `grid` (optional hardware) | `powerMeter` | Net grid power, signed — see "Grid import/export meter" above |
| `grid` (optional hardware) | `aboutisland47519.gridEnergy` | Lifetime exported/imported energy (kWh) |
| `dc` | `voltageMeasurement` | DC voltage straight off the solar panels, before inversion |
| `dc` | `powerMeter` | DC power straight off the solar panels, before inversion |

## Inverter operating status

`I_Status` (OFF/SLEEPING/STARTING/MPPT/THROTTLED/SHUTTING_DOWN/FAULT/
STANDBY) is exposed as a custom capability, `aboutisland47519.
inverterStatus` — no standard SmartThings capability fits inverter
operating state, so it's a free-text status attribute visible in the app,
not just in logs.

## Remaining open items

- **Single Modbus connection at a time**: if anything else (Home Assistant,
  etc.) polls this inverter's Modbus TCP service, this driver's connection
  attempts will conflict with it.

## SmartThings Community

https://community.smartthings.com/t/st-edge-driver-solaredge-pv-inverter/310477
