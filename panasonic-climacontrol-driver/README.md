# panasonic-climacontrol-lan

SmartThings Edge driver for Panasonic air conditioners fitted with ProtoART's **ClimateControl** module for Panasonic (PANA_CNCNT_ATA_WIFI). It uses the module's local HTTP API, with no cloud.

The module plugs into the indoor unit's CN-CNT connector and joins your Wi-Fi. ProtoART: [product](https://lectronz.com/products/climacontrol-panasonic), [HTTP API](https://protoart.net/knowledgebase/pana_cncnt_ata_wifi_http_api_mqtt_topics/), [manual](https://protoart.net/manual).

Tested on modules with firmware 3.6.2 on cooling-only Panasonic split systems. The driver logs the status JSON's keys once at startup, so a difference on other firmware shows up in the hub log.

## Device

One device per module (one per indoor unit):

- **Switch:** power on/off.
- **Air Conditioner Mode:** Auto, Cool, Dry, Fan Only, Heat (Heat left out with *Cooling only*, or once the unit has rejected it). Choosing a mode while the unit is off also switches it on (setting *Mode change turns the unit on*).
- **Fan Speed:** Auto, Quiet, Low, Medium, High, Turbo (the module's auto, silent, low, med, high, superhigh).
- **Set Temperature:** in 0.5 °C steps, within the range the module reports; 16–30 °C until it does.
- **Temperature:** the room temperature the module reports.
- **Presets:** Quiet, Normal, Powerful.
- **Vane Up/Down:** Highest, Middle, Normal, Low, Lowest, Swing, Auto.
- **Vane Left/Right:** Maximum Left, Left, Middle, Right, Maximum Right, Auto (only on units with left/right louvres).
- **Power:** watts, when the unit reports it.
- **Outdoor Unit** component: outdoor temperature, when the unit reports it.
- **Eco**, **Eco Navi**, **nanoe X** and **Mild Dry** components: one switch each, shown only for the features the unit has (see [Unit features](#unit-features)).
- **Wireless Thermometer** component, while ProtoART's wireless thermometer is paired: temperature, humidity and battery.
- **Windows/Doors** component, while ProtoART's window/door sensors are paired: one combined contact (open if any is open) and the lowest battery. Each sensor is also its own contact-sensor child device (open/closed, battery).
- **Module** component (the ClimateControl module itself):
  - **Indoor Unit Link:** whether the module can talk to the air conditioner over CN-CNT (and "EXT port in use" when it is);
  - **Temperature Input:** Internal (the unit's own sensor), Wireless (thermometer) or External (remote temperature), as on the module's page;
  - **Room Guard:** the module's temperature guard and its range;
  - **Wifi Signal** (dBm and a rating), **Ip Address**, **Mac Address**;
  - **Firmware**, with the latest version when an update is available;
  - **Uptime** (to the hour) and **Module ID**;
  - **Restart module** button.

## Unit features

The module reports every Panasonic extra whether or not the indoor unit has it, so the driver decides what to show in two ways:

- **The *Unit features* setting:** All extras, nanoe X models, Eco Navi models or Basic (no Eco Navi, nanoe X or Mild Dry). The left/right vane is left to learning: a unit without left/right louvres refuses it.
- **Learning:** a unit that doesn't support a setting puts it back by itself, usually within 10–30 s. After a command the driver reads the status every 5 s for a minute. If Eco, Eco Navi, nanoe X, Mild Dry, Vane Left/Right or Heat is put back to its previous value twice, it's hidden on that unit. It only learns while the unit is on in Cool or Heat (a unit may refuse e.g. Eco in Auto although it has it), no window is open and no other setting changes in the meantime (a preset change can cancel Eco, for example). A failed command never counts, and a setting that holds for a minute clears the count. Changing *Unit features* forgets what was learned.

Some older units silently accept a feature they don't have (for example Eco Navi) and never put it back, so learning can't catch it: use *Unit features* for those. Some older units also don't report power or room temperature over CN-CNT; the tiles then show 0 W or a fixed value.

Vane Up/Down, Presets and Fan Speed always show all their options.

## Sensors

ProtoART's wireless thermometer and window/door sensors (the window/door sensor is a MOES ZSS-GWM-C) are Bluetooth sensors paired to the module on its web page; SmartThings sees them through the module. With the CN-TH cable fitted, the air conditioner uses the thermometer in place of its own sensor (Temperature Input "Wireless"). If it stays "Internal" with a thermometer paired, the module couldn't calibrate the input: check the CN-TH cable (Panasonic units use 4-pin or 6-pin ones).

A sensor's component, or child device, goes away (or offline) after 3 polls in a row without it. A child device you delete isn't added again until the next Scan nearby.

Not included: the module's remote room-temperature input. It has to be resent every 5 seconds, and an Edge driver can't read other SmartThings sensors.

## Setup

1. Connect each module to your 2.4 GHz Wi-Fi (WPS, or its own access point; see the manual). A DHCP reservation for each module is a good idea.
2. **Add Device → Scan Nearby.** One device appears per module, named after the name set on the module's web page, or "Panasonic AC" plus the end of its MAC address.
3. If the module has a web password, enter it as **Module Password** in the device's Settings. A password already set on another device is tried automatically during the scan, and remembered for the module it unlocks.
4. If no module is found (for example the hub is on another network segment), one "Panasonic AC" device appears: enter the module's IP address in its settings.

Settings:

- **IP Address (optional):** leave as `0.0.0.0` for automatic discovery.
- **Module Password:** only if the module has a web password.
- **Cooling only:** leaves Heat out of the modes.
- **Unit features:** see above.
- **Room guard**, **lowest** and **highest** (5–40 °C): sent to the module only when you change them (both limits together), and retried until the module accepts them. "Leave as set on the module" never changes it.
- **Poll Interval:** 15 s by default (5–300 s).
- **Mode change turns the unit on:** on by default.

## How it works

- **Discovery:** every mDNS `_http._tcp` web server is asked for `GET /control` (likely module names first). A reply with a `heatpump` section is a module; one for another brand (`sys.hw`) is skipped. Its MAC address becomes the device network id, so scanning again never duplicates a device. A module whose password isn't known yet is added under its mDNS name. Passwords are only sent to servers whose login page is a ClimateControl one.
- **Status:** `GET /control` every poll. A value is sent to SmartThings only when it changes.
- **Commands:** `GET /control?cmd=heatpump&<key>=<value>`, then a status read 2 s later and every 5 s for a minute. Room guard: `GET /control?cmd=settings&t_protena=…&t_protmin=…&t_protmax=…`. Restart: `GET /control?cmd=restart`.
- **Login:** a module with a web password answers 401 until `POST /login` returns a session cookie. The module allows one web login at a time: if the session is lost again within a minute of logging in, someone is using the module's page, so the driver waits 3 minutes before logging in again (the device stays online). A wrong password is retried every 5 minutes, not every poll.
- **Offline:** after 3 failed polls in a row; the module is then looked for again by MAC address at most every 5 minutes. A device never takes over another module that now has its old address.

## Status fields

| Reading | JSON path tried |
| --- | --- |
| Power | `heatpump.power` (`on`/`off`, `1`/`0`); `heatpump.mode` = `off` also means off |
| Mode | `heatpump.mode` (`auto`, `cool`, `fan`/`fan_only`, `dry`, `heat`, or `0`–`4`) |
| Fan | `heatpump.fan` (`auto`, `silent`, `low`, `med`, `high`, `superhigh`, or `0`–`5`) |
| Set temperature | `heatpump.set_temperature`; range `general.t_coolmin`/`t_coolmax` or `heatpump.coolmin`/`coolmax` |
| Room temperature | `heatpump.actual_temperature`, else `room_temperature` / `roomtemperature` / `temperature` |
| Outdoor temperature | `heatpump.op.tout`, else `heatpump.tout` |
| Power (W) | `heatpump.op.pinp` |
| Preset | `heatpump.preset` (`normal`, `powerful`, `quiet`, or `1`–`3`) |
| Vane Up/Down | `heatpump.vane` (`1`–`5`, `swing`, `auto`; older `6` = swing) |
| Vane Left/Right | `heatpump.widevane` (`maxleft`, `left`, `middle`, `right`, `maxright`, `auto`, or `0`–`4`; older `swing`/`5` = Auto) |
| Eco, Eco Navi, nanoe X, Mild Dry | `heatpump.eco`, `econavi`, `nanoex`, `milddry` (`on`/`off`, `1`/`0`, `true`/`false`) |
| Indoor Unit Link | `sys.conhp`, `sys.conext` |
| Temperature Input | `heatpump.tinp` (`internal`, `wireless`, `external`) |
| Room Guard | `general.t_protena`, `t_protst`, `t_protmin`, `t_protmax` |
| Wifi Signal, Ip Address | `wifi.rssi`, `wifi.ip` |
| Firmware | `fw.curr`, `fw.last` |
| Uptime, Module ID | `sys.up` (seconds), `sys.id` |
| Mac Address (also the device network id) | `wifi.mac` |
| Device name at discovery | `sys.frname` |
| Wireless Thermometer | `sensor.thermometer` (`tact` °C, `hact` % humidity, `batt` % battery) |
| Window/door sensors | `sensor.window` (slot 1), `sensor.window_1` … `window_3` (slots 2–4): `state`, `batt`, `mac` |

If a reading stays blank on a real module, the hub log line `status JSON layout top: … | heatpump: …` shows which keys the module actually sends.

## Files

- `profiles/`: `climacontrol-panasonic.v3` is the template (all extras, no sensors). `tools/make_profiles.py` generates every other profile from it: each *Unit features* choice, every combination of hidden extras (named `-x<letters>`: e = Eco, v = Eco Navi, n = nanoe X, d = Mild Dry, w = left/right louvre, written as compact JSON), each with or without the thermometer and window components; plus `climacontrol-window-sensor.v1` for sensor child devices. Edit the template, then run the script. SmartThings limits a driver package to 640 KB, and the profiles take most of it.
- `capabilities/`: the custom capability definitions and presentations (namespace `aboutisland47519`). Wifi Signal, Ip Address and Mac Address are shared with the Big Ass Fans driver.
- `src/init.lua`: device lifecycle, polling, commands, learning.
- `src/status.lua`: translation between module and SmartThings values (plain Lua, testable without a hub).
- `src/api.lua`: HTTP client and login.
- `src/discovery.lua`: mDNS discovery.
