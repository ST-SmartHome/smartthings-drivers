# hunterpacific-tuya-lan

SmartThings Edge driver for Hunter Pacific DC ceiling fans with a Tuya WiFi module (tested on the Aqua DC). Controls the fan over Tuya's local LAN protocol (TCP 6668); no cloud.

Community thread: https://community.smartthings.com/t/st-edge-lan-driver-hunter-pacific-dc-ceiling-fans-tuya-wifi-local-control/311396

## Features

- Fan: on/off, speed (Off + 1–9), direction.
- Light kit (optional): on/off and brightness, as its own SmartThings device so Alexa and Google see it. Turn on **Light Kit Fitted** to create it.
- Multiple fans, via an "Add another fan" button.
- Commands are retried and verified by reading the state back.
- Shows **offline** if the local key or device ID is wrong, or after 3 failed polls in a row.
- Tuya protocol 3.3 and 3.5, detected per fan.

## Setup

1. Get each fan's local key, device ID and LAN IP. [tinytuya](https://github.com/jasonacox/tinytuya) does this: `pip install tinytuya`, then `python -m tinytuya wizard`.
   - Use the fan's LAN IP from your router, not the `ip` field from Tuya's cloud API (that's your WAN address).
   - Error 28841002 means your Tuya IoT Core trial has expired. Extend it at iot.tuya.com (Cloud → Cloud Services → IoT Core).
2. First fan: **Add Device → Scan Nearby**, then open the new device's settings and enter the IP, local key and device ID. Paste the key rather than typing it: phone keyboards can swap in curly quotes or dashes.
3. More fans: press **Add another fan** on any fan device, then fill in the new device's settings.
4. If a light kit is installed, turn on **Light Kit Fitted**. Turning it off deletes the light device.
5. Optionally, turn on **Hide 'Add Another Fan' Button** once all fans are added.

Settings take effect immediately. If the speed slider doesn't show Off + 1–9 after an update, close and reopen the SmartThings app.

## Data points

Module: Tuya "9 Speed WiFi Remote" (product `agjbamgmrbcbazp7`, category `fsd`).

| DP | Code | Values | Shown as |
|---|---|---|---|
| 60 | `fan_switch` | bool | Fan switch |
| 62 | `fan_speed` | 1–9 | Speed slider (0 = off) |
| 63 | `fan_direction` | forward/reverse | Direction |
| 20 | `switch_led` | bool | Light switch |
| 22 | `bright_value` | 1–9 | Light brightness (0–100%) |

## Behaviour notes

- The module reports the light data points whether or not a light kit is fitted, so the light can't be detected automatically.
- The fan slows, stops and reverses by itself, so the driver doesn't stop it first. It ignores a second direction change for about 30 s while reversing; the driver keeps retrying for up to 45 s.
- Colour temperature (DP 23) is in Tuya's cloud spec but not reported locally, so it isn't supported.

## Limitations

- Protocol 3.4 isn't supported.
- A fan accepts one local connection at a time. Other local clients (e.g. Home Assistant) can collide with the driver.

## Source

- `src/tuya_protocol.lua`: framing and AES encryption (protocol 3.3).
- `src/tuya35.lua`, `src/gcm.lua`: protocol 3.5 session handshake and AES-GCM.
- `src/tuya_client.lua`: one TCP connection per request; picks 3.3 or 3.5 per fan.
- `src/init.lua`: device handlers, polling, connection health, light child devices.
- `src/discovery.lua`: creates the first device; later fans come from the button.
- `src/lockbox`: bundled pure-Lua crypto for 3.3 (the platform has none).

Shares its Tuya transport with [skyfan-driver](../skyfan-driver/).
