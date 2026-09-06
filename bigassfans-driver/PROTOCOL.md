# BAF i6 protocol field reference

Moved out of the main README once the confirmed-fields table grew past
30 rows — this file is the deep reference; the README stays a quick
overview and links here.

## Confirmed `Properties` field numbers

Field numbers from the fan's proto2 `Properties` message (`aiobafi6.proto`
plus fields confirmed empirically that aren't in the public reference
schema at all). "Category" is which `Query` reaches it directly — `MORE
push-only` means it's never returned by any direct query, only pushed
unsolicited after a commit on a connection that opened with an identity
query first (see `BafClient.commit_and_verify_more`).

| No. | Name | Kind | Category | Meaning |
|---|---|---|---|---|
| 1 | `name` | string | ALL | Fan's configured name |
| 2 | `model` | string | ALL | Hardware model string (e.g. "Haiku H/I Series") |
| 7 | `firmware_version` | string | ALL | e.g. "3.3.7" |
| 8 | `mac_address` | string | ALL | Fan's MAC address |
| 9 | `uuid9` | string | ALL | A device identity UUID — present in the public reference schema, purpose vs. `dns_sd_uuid` not documented anywhere |
| 10 | `dns_sd_uuid` | string | ALL | Same UUID published in the fan's mDNS TXT record — confirmed identical via a real probe. This driver currently reads that UUID at the mDNS layer for its DNI, not via this field |
| 13 | `api_version` | string | ALL | e.g. "8" |
| 42 | `unoccupied_behavior` | bytes (nested 2-field submessage) | FAN | Motion screen's "when unoccupied" behavior — sub-field 1 = mode enum (1 = "Smart Mix" confirmed; 0 presumably "Turn Off", the app's only other option, not itself observed committed), sub-field 2 = `fan_speed` (native 0–7, only meaningful for Smart Mix). Confirmed both read AND write — the only field in this driver needing a real nested-message encoder in `Commit` |
| 43 | `fan_mode` | enum | FAN | Off/On/Auto |
| 44 | `reverse_enable` | bool | FAN | Direction (false=forward, true=reverse). Confirmed to apply with unpredictable delay, sometimes minutes — see the direction-control section in the README |
| 45 | `speed_percent` | int | FAN | Fan speed as 0–100% |
| 46 | `speed` | int | FAN | Fan speed, native 0–7 range |
| 47 | `comfort_enable` | bool | FAN | Comfort screen's "Auto Comfort" master toggle — confirmed via an isolated 0→1 commit |
| 48 | `comfort_ideal_temp` | int (×100 °C) | FAN | Comfort screen's target temperature |
| 50 | `comfort_min_speed` | int | FAN | Comfort screen's "Min Speed", native 0–7 |
| 51 | `comfort_max_speed` | int | FAN | Comfort screen's "Max Speed", native 0–7 (7 = on-screen "No Max") |
| 52 | `motion_sense_enable` | bool | FAN | Motion/occupancy sensing master enable. Only takes effect while `fan_mode = AUTO`. Confirmed working — write applies immediately, not delayed |
| 53 | `motion_sense_timeout` | int (seconds) | FAN | How long to keep running after motion stops, once triggered by occupancy (confirmed 7200 = 2 hours on one fan's setting) |
| 54 | `return_to_auto_enable` | bool | FAN | The FAN-menu "Return to Auto" master toggle — distinct from the Sleep-specific pair at 129/130 below |
| 55 | `return_to_auto_secs` | int (seconds) | FAN | Duration for the above |
| 58 | `whoosh_enable` | bool | FAN | Confirmed to apply with unpredictable delay, sometimes minutes — same caveat as `reverse_enable` |
| 60 | `heat_assist_enable` | bool | FAN | Comfort screen's "Heat Assist" toggle |
| 61 | `heat_assist_speed` | int | FAN | Heat Assist's own fan speed, native 0–7, independent of the main `speed` field |
| 62 | `heat_assist_reverse` | bool | FAN | Comfort screen's "Reverse" toggle under Heat Assist. (Fields 52 and 62 were once confused with each other during initial discovery — an isolated capture resolved which is which; both rows above now reflect the confirmed answer.) |
| 64 | `current_rpm` | int | FAN | Live motor RPM, read-only telemetry |
| 65 | `eco_enable` | bool | FAN | Confirmed not instant — typically ~1–2 minutes to apply |
| 66 | `fan_occupancy_detected` | bool | FAN | Read-only — whether the fan currently detects motion in the room |
| 68 | `light_mode` | enum | LIGHT | Off/On/Auto |
| 69 | `light_brightness_percent` | int | LIGHT | 0–100%, maps directly to the app's brightness slider |
| 85 | `light_occupancy_detected` | bool | LIGHT | Read-only, light's own motion detection — field number/name confirmed via the upstream `aiobafi6.proto` schema directly, not yet independently queried or tested against real hardware by this driver |
| 98 | `sleep_mode_enable` | bool | MORE push-only | Sleep Mode master toggle (a real physical remote button) |
| 100 | `sleep_fan_mode` | enum | FAN | Off/On/Auto — the Sleep tab's own fan-mode selector, distinct from the main `fan_mode` |
| 101 | `sleep_speed` | int | FAN | Native 0–7 — the Sleep tab's own current fan speed (shown as "Speed" on the Sleep ON-mode screen), distinct from the main `speed` field |
| 102 | `sleep_ideal_temp` | int (×100 °C) | FAN | Sleep Auto mode's target temperature (e.g. 2056 = 20.56°C) |
| 103 | `sleep_brightness_mode` | enum | LIGHT | Off/On/Auto — the light's Sleep preset |
| 104 | `sleep_brightness_percent` | int | LIGHT | 0–100%, Sleep preset brightness — pairs with `sleep_brightness_mode` the same way `wake_up_brightness` pairs with `wake_up_mode` |
| 107 | `wake_up_mode` | enum | LIGHT | Off/On/Auto — the light's Wake Up preset |
| 108 | `wake_up_brightness` | int | LIGHT | 0–100%, Wake Up preset brightness |
| 110 | `sleep_timer_enable` | bool | FAN | The Sleep tab's own on-device Timer toggle (separate from `sleep_mode_enable` and from SmartThings' unrelated generic "Timer" card) |
| 111 | `sleep_timer_end_speed` | int | FAN | Native 0–7 — the Sleep Timer's "End Speed", the target speed it gradually decreases to over `sleep_timer_duration` |
| 112 | `sleep_timer_duration` | int (seconds) | FAN | Sleep Timer's duration |
| 128 | `wake_up_motion_timeout_secs` | int (seconds) | LIGHT | Wake Up preset's post-motion timeout |
| 129 | `sleep_return_to_auto` | bool | FAN | The Auto screen's "Return to Auto" toggle — auto-reverts a manual adjustment after `sleep_return_to_auto_secs` |
| 130 | `sleep_return_to_auto_secs` | int (seconds) | FAN | Duration for the above |
| 134 | `led_indicators_enable` | bool | MORE push-only | LED indicators on/off |
| 135 | `fan_beep_enable` | bool | MORE push-only | Fan beep on/off |
| 136 | `legacy_ir_remote_enable` | bool | MORE push-only | Legacy IR remote support on/off |

Separately, `QueryResult.schedules` (field 3, unmodeled in every public
reference project) carries a `Schedule` message per configured on-device
schedule — its own `action` sub-field uses field numbers 5 (light mode
enum) and 18 (`light_auto_motion_timeout` in seconds) when the light
action is Auto. These live inside a completely different nested message
from the `Properties` table above — the field numbers coincidentally
overlapping with unrelated `Properties` fields is not a conflict, just
two independent numbering spaces.

**Schedule writes go through `Commit` field 4** (the same `Commit`
message every other write in this driver uses), shape
`{1: <slot index, varint>, 2: <Schedule message, or empty for a
delete>}`. Three captured examples:

- Re-saving an existing light-type schedule unchanged: `4: {1: 1, 2: {2:
  "My Schedule", 4: [1,2,3,4,5,6,7], 5: 1, 6: 1, 7: {1: "17:00",
  2: {5: 2}, 2: {18: 10800}}}}` — content matches the read-side decode
  exactly (day list, name, time, light action).
- Creating a new Bedtime/Wake-Up-type schedule (no name, no light
  action): `4: {1: 1, 2: {1: 1, 4: [2,3,4,5,6,7,1], 5: 2, 6: 1,
  7: {1: "23:00"}, 8: {1: "06:00"}}}` — a genuinely different shape from
  the light schedule's; `Schedule`'s content depends on its type. None of
  the fan's live Sleep sub-settings appear in this payload at all — the
  best-supported reading is that a Bedtime/Wake-Up schedule just triggers
  Sleep Mode on/off at the given times using whatever Sleep configuration
  the fan already has, rather than carrying its own snapshot.
- Deleting that schedule: `4: {1: 2, 2: {1: 1}}` — slot index 2 here, not
  the 1 both saves used; the outer wrap's slot/"index" field is not a
  stable per-schedule identity (two schedules on the same fan have been
  observed reporting the identical value simultaneously — more likely a
  revision/generation counter) and **every known write in this driver
  and the official app itself always sends `1` regardless**. Match/target
  a specific schedule by name, never by this slot value.

**A single `SCHEDULES` query returns multiple SLIP frames, one per
configured schedule** — a reader that stops after the first frame will
silently appear to see only one schedule even when several exist. Always
read to an idle timeout, not just the first frame.

**A third, richer `Schedule` shape** was found from a real user schedule
(a start/end time range with per-boundary fan+light actions):
`{1: 1, 2: "Test schedule", 4: [1..7], 5: 1, 6: 1,
7: {1: "22:00", 2: {1: 1}, 2: {4: 4}, 2: {5: 1}, 2: {6: 64}},
8: {1: "08:00", 2: {1: 2}, 2: {11: 1}, 2: {12: 2300}, 2: {13: 4},
2: {14: 3}, 2: {15: 1}}}` — raw decode only, matched loosely against the
app's own screen (Start 22:00: Speed 4, Light 64%; End 08:00: Fan Auto,
no light action) but not independently isolated-tested; treat as a lead
for a future capture, not documented behavior.

**Decode gotcha**: a short ASCII time string (e.g. "08:00") can
coincidentally parse as a syntactically-valid nested tag+varint
sequence — always sanity-check a `bytes` field as a plain string first
before trusting a recursive protobuf re-decode of it.

**Practical implication**: a write should default to read-modify-write
(fetch existing schedules, change only what's needed) rather than
constructing one from scratch, since exact multi-schedule capacity/
collision rules are still unconfirmed.

## `Capabilities` submessage (field 17, SENSORS category)

Actively used, not just documented: `ensure_light_child` queries this
field directly before creating a light-child device, skipping creation
if `has_light`/`has_uplight` both come back false — see `baf.
decode_light_capability` in `src/baf_protocol.lua`.

A nested submessage reporting hardware capability flags. Per the upstream
`aiobafi6.proto`, only 4 sub-fields are named: `has_comfort1`=1,
`has_comfort3`=3, `has_light`=4, `has_uplight`=6 (the last one specific
to Haiku H/I Series fans with a separate uplight module, distinct from
the regular downlight). Sub-fields not present in a query response are
false, same "missing means default" convention as the main `Properties`
message.

## Candidate fields — found but NOT independently confirmed

Everything below was found via either a packet capture of the official
app or a raw sweep of every query category, but hasn't been confirmed via
an isolated single-field capture (toggle exactly one control, verify
exactly that field changes and nothing else). Treat these as leads, not
documented behavior — see the "Full category sweep" section of
`src/baf_protocol.lua`'s `FIELDS` table for the fullest detail and
caveats on each.

- **Found via a full category sweep** (not a pcap): `fan_target_rpm`(63,
  FAN) — identical value to the read-only `current_rpm`(64) in the same
  query, worth checking whether it's a real commanded setpoint;
  `wifi_module_version`(16, ALL category, nested submessage with a
  version string distinct from the main fan firmware version); and the
  `NETWORK` category (never queried by this driver before), which
  exposes the fan's own IP and — notably — **the connected Wi-Fi SSID
  name in plaintext** to anyone on the LAN who queries it, unauthenticated
  (a real protocol-level fact worth knowing on its own, regardless of
  whether it ever becomes a capability).
