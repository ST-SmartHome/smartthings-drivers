# se-modbus-tcp

SmartThings Edge driver for SolarEdge inverters over local Modbus TCP (SunSpec); no cloud.

Community thread: https://community.smartthings.com/t/st-edge-driver-solaredge-pv-inverter/310477

## Setup

1. Enable Modbus TCP on the inverter (SetApp or the installer menu). The default port is 1502.
2. **Add Device → Scan Nearby** creates one "SolarEdge Inverter" device. The inverter doesn't announce itself on the network, so the driver can't find it on its own.
3. In the device settings, enter the inverter's IP and port, Modbus unit ID (usually 1) and poll interval.

## What shows up

| Section | Shows |
|---|---|
| Main | Output power, lifetime energy, temperature, status (MPPT, Throttled, Fault…), refresh |
| Grid (if a SolarEdge meter is fitted) | Net grid power (+ export / − import), lifetime exported/imported energy, and a row per phase (Grid Phase One/Two/Three) with power, voltage and current |
| DC Input | DC power, plus one row with DC voltage and current |
| Battery (if a SolarEdge-connected battery is fitted) | Power (+ charging / − discharging), temperature, Battery Status on its own line, and a Battery Storage row with charge level, health and energy available. Read-only |

Grid power already accounts for household use, so use it, not inverter output, for "solar surplus" Routines. Installs without a meter just don't show the Grid section.

The driver detects a three-phase meter (real voltage on L2 and L3) and a battery on its own, and switches the device's layout once when it finds them. Single-phase sites show one phase row. Phase current is measured by the meter and shown without a sign; the power sign gives the direction.

On hybrid inverters with a battery, the DC voltage is the inverter's shared DC bus, not the panel or battery voltage.

In the 2026-10-10 update, DC voltage and the battery details moved to new rows. Routines that used DC voltage or the old Battery Details values need their condition reselected.

## Limitations

- The inverter accepts one Modbus connection at a time. Anything else polling it (Home Assistant, another driver) will collide. See the [solaredge-modbus-multi wiki](https://github.com/WillCodeForCats/solaredge-modbus-multi/wiki/Known-Issues).
- One inverter per hub. With leader/follower inverters, only the unit set in the device's settings is read. The grid meter is normally on the leader, so the Grid section still covers the whole site.

## Source

- `src/modbus.lua`: minimal Modbus TCP client (function 0x03).
- `src/sunspec.lua`: SunSpec model discovery.
- `src/solaredge.lua`: inverter (101/103), meter (201–204) and SolarEdge battery register maps and scale factors.
- `src/init.lua`: lifecycle, polling, device events.
- `src/discovery.lua`: creates the single device.
