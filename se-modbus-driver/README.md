# se-modbus-tcp

SmartThings Edge driver for SolarEdge inverters over local Modbus TCP (SunSpec); no cloud.

Community thread: https://community.smartthings.com/t/st-edge-driver-solaredge-pv-inverter/310477

Installed before 2026-09-10? The driver was previously `se-modbus-v4`; see the thread for switching over.

## Setup

1. Enable Modbus TCP on the inverter (SetApp or the installer menu). The default port is 1502.
2. **Add Device → Scan Nearby** creates one "SolarEdge Inverter" device. The inverter doesn't announce itself on the network, so the driver can't find it on its own.
3. In the device settings, enter the inverter's IP and port, Modbus unit ID (usually 1) and poll interval.

## What shows up

| Section | Shows |
|---|---|
| Main | Output power, lifetime energy, temperature, status (MPPT, Throttled, Fault…), refresh |
| Grid (if a SolarEdge meter is fitted) | Net grid power (+ export / − import), lifetime exported/imported energy |
| DC | DC voltage and power from the panels |

Grid power already accounts for household use, so use it, not inverter output, for "solar surplus" Routines. Installs without a meter just don't show the Grid section.

## Limitations

- The inverter accepts one Modbus connection at a time. Anything else polling it (Home Assistant, another driver) will collide. See the [solaredge-modbus-multi wiki](https://github.com/WillCodeForCats/solaredge-modbus-multi/wiki/Known-Issues).
- One inverter per hub. With leader/follower inverters, only the unit set in the device's settings is read. The grid meter is normally on the leader, so the Grid section still covers the whole site.

## Source

- `src/modbus.lua`: minimal Modbus TCP client (function 0x03).
- `src/sunspec.lua`: SunSpec model discovery.
- `src/solaredge.lua`: inverter (101/103) and meter (201–204) register maps and scale factors.
- `src/init.lua`: lifecycle, polling, device events.
- `src/discovery.lua`: creates the single device.
