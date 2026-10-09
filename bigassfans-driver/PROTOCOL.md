# BAF i6 protocol field reference

## Confirmed `Properties` field numbers

Fields of the proto2 `Properties` message: from `aiobafi6.proto`, plus some found on real fans. "Category" is the `Query` that returns the field. `MORE push-only` fields are never returned by a query; the fan pushes them after a commit on a connection that opened with an identity query (`BafClient.commit_and_verify_more`).

| No. | Name | Kind | Category | Meaning |
|---|---|---|---|---|
| 1 | `name` | string | ALL | Fan's configured name |
| 2 | `model` | string | ALL | Hardware model string (e.g. "Haiku H/I Series") |
| 7 | `firmware_version` | string | ALL | e.g. "3.3.7" |
| 8 | `mac_address` | string | ALL | Fan's MAC address |
| 9 | `uuid9` | string | ALL | A device UUID; how it differs from `dns_sd_uuid` is undocumented |
| 10 | `dns_sd_uuid` | string | ALL | Same UUID as the mDNS TXT record. The driver reads it from mDNS, not this field |
| 13 | `api_version` | string | ALL | e.g. "8" |
| 42 | `unoccupied_behavior` | bytes (nested 2-field submessage) | FAN | Motion screen's "when unoccupied" behavior — sub-field 1 = mode enum (1 = "Smart Mix" confirmed; 0 presumably "Turn Off", the app's only other option, not itself observed committed), sub-field 2 = `fan_speed` (native 0–7, only meaningful for Smart Mix). Read and write confirmed; the only nested field the driver commits |
| 43 | `fan_mode` | enum | FAN | Off/On/Auto |
| 44 | `reverse_enable` | bool | FAN | Direction (false = forward, true = reverse). Can take minutes to apply |
| 45 | `speed_percent` | int | FAN | Fan speed as 0–100% |
| 46 | `speed` | int | FAN | Fan speed, native 0–7 range |
| 47 | `comfort_enable` | bool | FAN | Comfort screen's "Auto Comfort" toggle |
| 48 | `comfort_ideal_temp` | int (×100 °C) | FAN | Comfort screen's target temperature |
| 50 | `comfort_min_speed` | int | FAN | Comfort screen's "Min Speed", native 0–7 |
| 51 | `comfort_max_speed` | int | FAN | Comfort screen's "Max Speed", native 0–7 (7 = on-screen "No Max") |
| 52 | `motion_sense_enable` | bool | FAN | Motion sensing enable. Only works while `fan_mode = AUTO`. Applies immediately |
| 53 | `motion_sense_timeout` | int (seconds) | FAN | Run time after motion stops (7200 = 2 h). `motion_timeout_secs` in the code |
| 54 | `return_to_auto_enable` | bool | FAN | Fan menu's "Return to Auto" toggle (Sleep has its own: 129/130) |
| 55 | `return_to_auto_secs` | int (seconds) | FAN | Duration for the above |
| 58 | `whoosh_enable` | bool | FAN | Can take minutes to apply |
| 60 | `heat_assist_enable` | bool | FAN | Comfort screen's "Heat Assist" toggle |
| 61 | `heat_assist_speed` | int | FAN | Heat Assist's own fan speed, native 0–7, independent of the main `speed` field |
| 62 | `heat_assist_reverse` | bool | FAN | Comfort screen's "Reverse" toggle under Heat Assist |
| 63 | `fan_target_rpm` | int | FAN | Target RPM. Jumps on a speed change while 64 ramps up over ~20 s. Varies by fan size (speed 5: 125 vs 141) |
| 64 | `current_rpm` | int | FAN | Live motor RPM (read-only) |
| 65 | `eco_enable` | bool | FAN | Takes ~1–2 min to apply |
| 66 | `fan_occupancy_detected` | bool | FAN | Read-only: motion currently detected. Not used by the driver |
| 68 | `light_mode` | enum | LIGHT | Off/On/Auto |
| 69 | `light_brightness_percent` | int | LIGHT | 0–100%, maps directly to the app's brightness slider |
| 73 | `light_auto_motion_timeout` | int (seconds) | LIGHT | Light's Auto-mode motion timeout (not Sleep's, which is 117) |
| 74 | `light_return_to_auto_enable` (name ours) | bool | LIGHT | Light screen's Return to Auto toggle (the fan's is 54) |
| 75 | `light_return_to_auto_secs` (name ours) | int (seconds) | LIGHT | Duration for 74 |
| 85 | `light_occupancy_detected` | bool | LIGHT | Read-only: light's motion detection (from the upstream schema; untested) |
| 86 | `temperature_raw` | int (×100 °C) | SENSORS | Built-in temperature sensor (3170 = 31.70 °C), within ~1 °C of a reference |
| 98 | `sleep_mode_enable` | bool | MORE push-only | Sleep Mode toggle (also a remote button) |
| 100 | `sleep_fan_mode` | enum | FAN | Sleep tab's fan mode (Off/On/Auto) |
| 101 | `sleep_speed` | int | FAN | Sleep tab's fan speed (0–7) |
| 102 | `sleep_ideal_temp` | int (×100 °C) | FAN | Sleep Auto target temperature (2056 = 20.56 °C) |
| 103 | `sleep_brightness_mode` | enum | LIGHT | Light's Sleep preset (Off/On/Auto) |
| 104 | `sleep_brightness_percent` | int | LIGHT | Sleep preset brightness (0–100%) |
| 107 | `wake_up_mode` | enum | LIGHT | Light's Wake Up preset (Off/On/Auto) |
| 108 | `wake_up_brightness` | int | LIGHT | Wake Up preset brightness (0–100%) |
| 110 | `sleep_timer_enable` | bool | FAN | Sleep tab's Timer toggle |
| 111 | `sleep_timer_end_speed` | int | FAN | Sleep Timer end speed (0–7), reached over `sleep_timer_duration` |
| 112 | `sleep_timer_duration` | int (seconds) | FAN | Sleep Timer duration |
| 117 | `sleep_light_auto_motion_timeout_secs` | int (seconds) | LIGHT | Sleep preset's light Auto motion timeout (main light: 73, Wake Up: 128) |
| 120 | `network_ip` | string | NETWORK | Fan's LAN IP |
| 124 | `network_wifi_info` | nested | NETWORK | Sub-field 1: Wi-Fi SSID, in plaintext, readable by anyone on the LAN. Sub-field 2 (not upstream): probably RSSI (dBm) |
| 128 | `wake_up_motion_timeout_secs` | int (seconds) | LIGHT | Wake Up preset's post-motion timeout |
| 129 | `sleep_return_to_auto` | bool | FAN | Auto screen's "Return to Auto" toggle |
| 130 | `sleep_return_to_auto_secs` | int (seconds) | FAN | Duration for the above |
| 134 | `led_indicators_enable` | bool | MORE push-only | LED indicators on/off |
| 135 | `fan_beep_enable` | bool | MORE push-only | Fan beep on/off |
| 136 | `legacy_ir_remote_enable` | bool | MORE push-only | Legacy IR remote support on/off |

## Schedules

`QueryResult.schedules` (field 3, absent from public schemas) carries one `Schedule` per on-fan schedule. Its field numbers are a separate space from `Properties`.

- **One `SCHEDULES` query returns one SLIP frame per schedule.** Read until idle, not just the first frame.
- **Writes use `Commit` field 4:** `{1: <slot>, 2: <Schedule, or empty to delete>}`. The slot isn't a stable ID (two schedules can share one), and the official app always sends `1`. Match schedules by name.
- **Shapes seen:**
  - Named light schedule: `{2: "My Schedule", 4: [1..7], 5: 1, 6: 1, 7: {1: "17:00", 2: {5: 2}, 2: {18: 10800}}}`. In the light action, 5 = light mode and 18 = auto motion timeout.
  - Bedtime/Wake-Up (unnamed): `{1: 1, 4: [2,3,4,5,6,7,1], 5: 2, 6: 1, 7: {1: "23:00"}, 8: {1: "06:00"}}`. It carries no Sleep settings; it appears to just toggle Sleep Mode.
  - Delete: `{1: 2, 2: {1: 1}}`.
  - Start/end range with fan and light actions (decoded once, not isolation-tested): `7: {1: "22:00", 2: {1: 1}, 2: {4: 4}, 2: {5: 1}, 2: {6: 64}}, 8: {1: "08:00", 2: {1: 2}, 2: {11: 1}, ...}`.
- **Always read-modify-write**; never build a schedule from scratch.
- **Decode gotcha:** a short time string like `"08:00"` can parse as valid protobuf. Check `bytes` fields as strings first.

## `Capabilities` (field 17, SENSORS)

Hardware flags: `has_comfort1` = 1, `has_comfort3` = 3, `has_light` = 4, `has_uplight` = 6. A missing flag means false. The driver only creates a light device if `has_light` or `has_uplight` is set.

## Fan configuration (field 230)

A nested message: sub-field 1 = blade size, sub-field 2 = mount.

| Value | App shows |
|---|---|
| `{1: 5, 2: 3}` | 52" (132 cm), Long Mount |
| `{1: 4, 2: 2}` | 60" (152 cm), Short Mount |

- **Read-only.** Commits are ignored, and the app has no setting for it.
- **Stored on the SenseMe board.** A replacement board reports its donor fan's size.
- **Probably sets the speed → RPM mapping** (inferred): the fan reporting 60" ran speed 5 at ~125 rpm, against ~141 rpm on a 52" fan.

## Unconfirmed fields

Seen in captures or a read-only sweep (2026-09-27), but not isolation-tested.

| No. | Name | Kind | Category | Notes |
|---|---|---|---|---|
| 4 | `local_datetime` | string | | Local date-time (ISO 8601) |
| 5 | `utc_datetime` | string | | UTC date-time |
| 6 | | string | | Time zone |
| 11 | `api_endpoint` | string | | Cloud API host |
| 15 | | int | ALL | 7 on both fans |
| 16 | `firmware` | nested | ALL | Sub-field 2: firmware version. Sub-field 3: bootloader (2.2.22 on rev A boards, 2.5.0 on rev B/C/D/E). Sub-field 4: SenseMe board part number (e.g. `"005777"`). Sub-field 5: board revision. Fields 4 and 5 were matched to the app's About Fan screen |
| 67 | | | | Changes with fan mode, but isn't an Auto flag |
| 70 | `light_brightness_level` | int | | 0–16 |
| 71, 78, 79 | light colour temperatures | int (K) | | All 2700 (fixed bulb). 116 and 127 also read 2700 |
| 77 | `light_dim_to_warm_enable` | bool | | |
| 87 | `humidity` | int | | 100000; probably "no sensor" |
| 109 | | | | Differs between the two fans |
| 121, 153 | | int | | 0 on both fans |
| 156 | `stats` | nested | | Sub-field 1: uptime in minutes |

Other unidentified fields not in the upstream schema: 3, 59, 72, 82, 83, 89, 95, 96, 113–115, 118, 126, 140, 150, 171–175, 207.
