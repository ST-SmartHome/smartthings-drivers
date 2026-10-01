# SmartThings LAN Edge Drivers

Custom SmartThings LAN Edge Drivers for a few devices with no official
SmartThings support — all controlled entirely over the local network, no
cloud dependency once set up.

- **[skyfan-driver](skyfan-driver/)** (`skyfan-tuya-lan`) — Ventair
  Skyfan DC ceiling fans, over Tuya's local LAN protocol.
- **[se-modbus-driver](se-modbus-driver/)** (`se-modbus-tcp`) —
  SolarEdge inverter, over local Modbus TCP (SunSpec).
- **[bigassfans-driver](bigassfans-driver/)** (`bigassfans-i6-lan`) —
  Big Ass Fans Haiku H/I Series ceiling fans, over their local "i6"
  protocol, mDNS auto-discovered.

Each has its own `README.md` (technical details, setup).

## Zigbee

- **[ZCL Switch ST-SmartHome](https://github.com/ST-SmartHome/smartthings-zigbee-edge-drivers/tree/main/deploy/zcl-switch-st-smarthome)**
  — Mercator Ikuü SPP02GIP double power point (Tuya `TS011F`): outlet 2
  as its own device (for Alexa/Google), correct energy readings,
  adjustable reporting, and a per-outlet Auto Off Timer that runs on the
  plug itself. It lives in a separate repository because it's a fork of
  [wonjj6768's Zigbee Edge drivers](https://github.com/wonjj6768/smartthings-zigbee-edge-drivers),
  which keeps it in sync with upstream and lets fixes go back upstream.
