# se-modbus-v4

LAN Edge Driver for a SolarEdge inverter, controlling it over local Modbus
TCP (SunSpec) rather than through SolarEdge's cloud API — no cloud
dependency once set up. Distributed via a SmartThings channel invite
(see the Community thread below).

**Discovery**: the inverter's Modbus TCP service is passive with no
broadcast/SSDP of its own, so discovery doesn't gate on any network
signal — `discovery.lua` creates one device unconditionally on "Scan
Nearby", with a placeholder network ID. Real IP/port/unit ID are then
entered as device **preferences** afterward (see
`profiles/solaredge-inverter.yml`); `init.lua`'s `infoChanged` picks up
preference changes and (re)starts polling.

## Grid import/export meter

If your installation has a SolarEdge production/consumption meter
(SunSpec model 201–204), the driver reads it automatically in the same
Modbus session and exposes a second `grid` component:

- **`powerMeter`** — net grid power, **signed** (negative = importing,
  positive = exporting). Already nets out household consumption, so use
  this (not the inverter's own production figure) for a "only run if
  there's solar surplus" condition.
- **`gridEnergy`** (custom capability) — lifetime exported/imported
  energy.

No meter present is a normal case — readings are simply omitted, not
errored. `grid` shows up as its own selectable condition in Routines.

## Files

- `config.yml` — driver metadata, `lan` + `discovery` permissions.
- `profiles/solaredge-inverter.yml` — capabilities (powerMeter,
  energyMeter, temperatureMeasurement, refresh, plus `grid`/`dc`) and the
  IP/port/unitId/pollInterval preferences.
- `src/discovery.lua` — unconditional single-device creation.
- `src/init.lua` — lifecycle handlers, preference-driven polling loop.
- `src/modbus.lua` — minimal Modbus TCP client (Read Holding Registers,
  function code 0x03), hand-rolled since the Lua sandbox has no Modbus
  library — uses `cosock.socket` directly.
- `src/solaredge.lua` — SunSpec inverter model (101/103) register map and
  scale-factor math, plus the optional meter model (201–204) read.

## Status: working, verified live

Confirmed via live `logcat` against a real SE5000AU — power, lifetime
energy, DC voltage/power, temperature, and status all reporting sane,
stable values, visible in the app. Example log shape (illustrative):

```
SolarEdge reading: <W>W, <Wh> lifetime, <V> DC, <W> DC, <°C>, status=MPPT
```

Device preferences take an IP:port (sentinel `192.168.1.100:1502` — real
LAN IP set per-install), Modbus unit ID (typically `1`), and poll
interval (30s default).

### What shows up in the app

| Component | Capability | Shows |
|---|---|---|
| `main` | `powerMeter` | Live inverter output power (W) |
| `main` | `energyMeter` | Lifetime energy produced (kWh) |
| `main` | `temperatureMeasurement` | Inverter temperature (°C) |
| `main` | `inverterStatus` | Operating status (MPPT/THROTTLED/FAULT/etc) |
| `main` | `refresh` | Manual refresh button |
| `grid` | `powerMeter` | Net grid power, signed |
| `grid` | `gridEnergy` | Lifetime exported/imported energy (kWh) |
| `dc` | `voltageMeasurement` | DC voltage before inversion |
| `dc` | `powerMeter` | DC power before inversion |

`inverterStatus` (OFF/SLEEPING/STARTING/MPPT/THROTTLED/SHUTTING_DOWN/
FAULT/STANDBY) is a custom capability — no standard SmartThings
capability fits inverter operating state.

## Known limitation: one Modbus connection at a time

SolarEdge inverters only accept a single Modbus TCP connection — a
hardware/firmware constraint, not something any driver can work around.
Anything else polling the same inverter (Home Assistant, another driver
instance, SolarEdge's own tools) will collide with this one. Also
documented in the [solaredge-modbus-multi wiki](https://github.com/WillCodeForCats/solaredge-modbus-multi/wiki/Known-Issues).

## SmartThings Community

https://community.smartthings.com/t/st-edge-driver-solaredge-pv-inverter/310477
