# skyfan-tuya-lan

SmartThings Edge driver for Ventair Skyfan DC ceiling fans. Controls the fan over Tuya's local LAN protocol (TCP 6668); no cloud.

Community thread: https://community.smartthings.com/t/st-edge-lan-driver-ventair-skyfan-dc-ceiling-fan/310702

## Features

- Fan: on/off, speed (1–5), mode (Normal/ECO/Sleep), direction, sleep timer.
- Light (if fitted): on/off, brightness, colour (warm/natural/cool). The light is its own SmartThings device, so Alexa and Google see it.
- Multiple fans, via an "Add another fan" button.
- Direction changes stop the fan first.
- Commands are retried and verified by reading the state back.

## Setup

1. Get each fan's local key, device ID and LAN IP. [tinytuya](https://github.com/jasonacox/tinytuya) does this: `pip install tinytuya`, then `python -m tinytuya wizard`.
   - Use the fan's LAN IP from your router, not the `ip` field from Tuya's cloud API (that's your WAN address).
   - Error 28841002 means your Tuya IoT Core trial has expired. Extend it at iot.tuya.com (Cloud → Cloud Services → IoT Core).
2. First fan: **Add Device → Scan Nearby**, then open the new device's settings and enter the IP, local key and device ID.
3. More fans: press **Add another fan** on any Skyfan device, then fill in the new device's settings.
4. For fans without a light, turn on **No Physical Light**.
5. Optionally, turn on **Hide 'Add Another Fan' Button** once all fans are added.

Changes to **No Physical Light** and **Hide 'Add Another Fan' Button** take effect when the driver restarts (e.g. a hub reboot).

## Data points

| DP | Code | Values | Shown as |
|---|---|---|---|
| 1 | `switch` | bool | Fan switch |
| 2 | `mode` | Normal/ECO/Sleep | Mode |
| 3 | `fan_speed` | 1–5 | Speed slider |
| 8 | `fan_direction` | forward/reverse | Direction |
| 15 | `light` | bool | Light switch |
| 16 | `bright_value` | 1–5 | Light brightness (0–100%) |
| 19 | `work_mode` | Warmwhite/Naturalwhite/Coolwhite | Light colour |
| 22 | `countdown_set` | cancel, 1h–12h | Sleep timer |

## Limitations

- Protocol 3.3 only.
- A fan accepts one local connection at a time. Other local clients (e.g. Home Assistant) can collide with the driver.
- Some units reset the first connection after being idle. The driver retries automatically.

## Source

- `src/tuya_protocol.lua`: framing and AES encryption (protocol 3.3).
- `src/tuya_client.lua`: one TCP connection per request.
- `src/init.lua`: device handlers, polling, light child devices.
- `src/discovery.lua`: creates the first device; later fans come from the button.
- `src/lockbox`: bundled pure-Lua crypto (the platform has none).
