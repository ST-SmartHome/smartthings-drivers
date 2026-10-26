# SmartThings LAN Edge Drivers

Custom SmartThings LAN Edge Drivers for a few devices with no official
SmartThings support — all controlled entirely over the local network, no
cloud dependency once set up.

- **[skyfan-driver](skyfan-driver/)** (`skyfan-tuya-lan`) — Ventair
  Skyfan DC ceiling fans, over Tuya's local LAN protocol.
- **[hunterpacific-driver](hunterpacific-driver/)** (`hunterpacific-tuya-lan`) —
  Hunter Pacific DC ceiling fans (e.g. Aqua DC), over Tuya's local LAN
  protocol.
- **[se-modbus-driver](se-modbus-driver/)** (`se-modbus-tcp`) —
  SolarEdge inverter, over local Modbus TCP (SunSpec).
- **[rainmachine-driver](rainmachine-driver/)** (`rainmachine-lan`) —
  RainMachine irrigation controllers (Mini-8, Touch HD, Pro), over their
  local HTTP API, mDNS auto-discovered.
- **[bigassfans-driver](bigassfans-driver/)** (`bigassfans-i6-lan`) —
  Big Ass Fans Haiku H/I Series ceiling fans, over their local "i6"
  protocol, mDNS auto-discovered.
- **[panasonic-climacontrol-driver](panasonic-climacontrol-driver/)**
  (`panasonic-climacontrol-lan`) — Panasonic air conditioners fitted with
  ProtoART's ClimateControl module, over its local HTTP API, mDNS
  auto-discovered. First version, not yet tested on a real module.

Each has its own `README.md` (technical details, setup).

## Zigbee

- **[ZCL Switch ST-SmartHome](https://github.com/ST-SmartHome/smartthings-zigbee-edge-drivers/tree/main/deploy/zcl-switch-st-smarthome)**
  — Mercator Ikuü SPP02GIP double power point (Tuya `TS011F`): outlet 2
  as its own device (for Alexa/Google), correct energy readings,
  adjustable reporting, and a per-outlet Auto Off Timer that runs on the
  plug itself.
- **[EF00 Sensors ST-SmartHome](https://github.com/ST-SmartHome/smartthings-zigbee-edge-drivers/tree/main/deploy/ef00-sensors-st-smarthome)**
  — 7-in-1 pool water quality meter (Tuya `TS0601` / `_TZE200_v1jqz5cy`):
  pH and free chlorine limits shown and set as decimals (7.8 pH, 2.4 mg/L),
  negative ORP limits, and readable labels.

Both live in a separate repository because they're forks of
[wonjj6768's Zigbee Edge drivers](https://github.com/wonjj6768/smartthings-zigbee-edge-drivers),
which keeps them in sync with upstream and lets fixes go back upstream.
