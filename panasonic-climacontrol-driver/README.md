# panasonic-climacontrol-lan

SmartThings Edge driver for Panasonic air conditioners fitted with ProtoART's **ClimateControl** module for Panasonic (PANA_CNCNT_ATA_WIFI). It uses the module's local HTTP API, with no cloud.

The module plugs into the indoor unit's CN-CNT connector and joins your Wi-Fi. ProtoART: [product](https://lectronz.com/products/climacontrol-panasonic), [HTTP API](https://protoart.net/knowledgebase/pana_cncnt_ata_wifi_http_api_mqtt_topics/), [manual](https://protoart.net/manual).

**Status: first version, not yet tested on a real module.** ProtoART's docs don't show the module's status JSON. The paths the driver reads (see [Status fields](#status-fields)) match real Panasonic module `/control` responses (firmware 3.4.1): one sent by ProtoART, and `json/pana.json` in the [Homey ClimateControl app](https://github.com/tammert/net.protoart.clima). The driver also logs the JSON's keys once at startup, so any difference on other firmware shows up in the hub log.

## Device

One device per module (one per indoor unit):

- **Switch:** power on/off.
- **Air Conditioner Mode:** Auto, Cool, Dry, Fan Only, Heat. Choosing a mode while the unit is off also switches it on (setting *Mode change turns the unit on*).
- **Fan Speed:** Auto, Quiet, Low, Medium, High, Turbo (the module's auto, silent, low, med, high, superhigh).
- **Set Temperature:** in 0.5 °C steps, within the range the module reports (`coolmin`–`coolmax`, 16–31 °C on the sample); 16–30 °C until it does.
- **Temperature:** the room temperature the module reports.
- **Preset:** Normal, Powerful, Quiet.
- **Vertical Vane:** Auto (swing), 1–5.
- **Horizontal Vane:** Swing, Far left, Left, Centre, Right, Far right (the module's `auto` shows as Swing).
- **Power:** watts, when the unit reports it.
- **Outdoor Unit** component: outdoor temperature, when the unit reports it.
- **Eco**, **Eco Navi**, **nanoe X** and **Mild Dry** components: one switch each. Which of these work depends on the indoor unit's features.
- **Wireless Thermometer** component: temperature, humidity and battery from ProtoART's wireless thermometer (see [Wireless thermometer](#wireless-thermometer)).
- **Module** component (the ClimateControl module itself):
  - **Indoor Unit Link:** whether the module can talk to the air conditioner over CN-CNT, and whether its EXT port is connected;
  - **Temperature Input:** which sensor the air conditioner is using (wireless thermometer, remote temperature, or its own);
  - **Wifi Signal** (dBm and a rating), **Ip Address**, **Mac Address**;
  - **Firmware**, with the latest version when an update is available;
  - **Uptime** (to the hour) and **Module ID**;
  - **Restart module** button.

## Wireless thermometer

ProtoART's optional wireless thermometer (round or E-Ink) pairs with the module by radio. With the CN-TH cable fitted, the air conditioner uses its reading in place of its own sensor.

The Wireless Thermometer component appears only when the module reports the thermometer as its temperature input (`heatpump.tinp` = `wireless`) and the thermometer is reporting. The driver then moves the device to the `climacontrol-panasonic-thermometer.v1` profile (the same as the standard one plus that component). The component stays while a thermometer remains paired, even if the module falls back to another input (for example on a flat battery, which then shows). It is removed after 3 polls in a row with no thermometer paired.

The Air Conditioner's own Temperature tile stays the temperature the air conditioner works from (`heatpump.actual_temperature`).

Not included: the module's remote room-temperature input. It has to be resent every 5 seconds, and an Edge driver can't read other SmartThings sensors.

## Setup

1. Connect each module to your 2.4 GHz Wi-Fi (WPS, or its own access point at `http://10.0.0.1`; see the manual).
2. **Add Device → Scan Nearby.** One device appears per module that answers on the network, named after the name set in the module's web page, or "Panasonic AC" plus the last four characters of its MAC address when none is set. Rename each to its room.
3. If none is found (for example the hub is on another network segment), one "Panasonic AC" device appears: enter the module's IP address in its settings.

Settings:

- **IP Address (optional):** leave as `0.0.0.0` for automatic discovery. Set it if mDNS doesn't reach the hub. A DHCP reservation for each module is a good idea either way.
- **Poll Interval:** 15 s by default (5–300 s).
- **Mode change turns the unit on:** on by default.

## How it works

- **Discovery:** mDNS `_http._tcp` services whose name contains "heatpump", "hvac", "clima" or "factory" are checked with `GET /control`. A reply with a `heatpump` section is a module. Its MAC address becomes the device network id, so scanning again never duplicates a device, and a module that changes IP address is found again by MAC.
- **Status:** `GET /control` every poll. A value is sent to SmartThings only when it changes.
- **Commands:** `GET /control?cmd=heatpump&<key>=<value>`, then a status read 2 s later. Restart is `GET /control?cmd=restart`, with a status read 20 s later.
- **Offline:** after 3 failed polls in a row.
- No authentication: ProtoART designs the module for a trusted LAN.

## Status fields

| Reading | JSON path tried |
| --- | --- |
| Power | `heatpump.power` (`on`/`off`, `1`/`0`); `heatpump.mode` = `off` also means off |
| Mode | `heatpump.mode` (`auto`, `cool`, `fan`/`fan_only`, `dry`, `heat`, or `0`–`4`) |
| Fan | `heatpump.fan` (`auto`, `silent`, `low`, `med`, `high`, `superhigh`, or `0`–`5`) |
| Set temperature | `heatpump.set_temperature`; range `heatpump.coolmin`, `heatpump.coolmax` |
| Room temperature | `heatpump.actual_temperature`, else `room_temperature` / `roomtemperature` / `temperature` |
| Outdoor temperature | `heatpump.op.tout`, else `heatpump.tout` |
| Power (W) | `heatpump.op.pinp` |
| Preset | `heatpump.preset` (`normal`, `powerful`, `quiet`, or `1`–`3`) |
| Vertical vane | `heatpump.vane` (`1`–`5`; `swing`, `auto` or `6` show as Auto) |
| Horizontal vane | `heatpump.widevane` (`maxleft`, `left`, `middle`, `right`, `maxright`, `swing`, or `0`–`5`; `auto` shows as Swing) |
| Eco, Eco Navi, nanoe X, Mild Dry | `heatpump.eco`, `econavi`, `nanoex`, `milddry` (`on`/`off`, `1`/`0`, `true`/`false`) |
| Indoor Unit Link | `sys.conhp`, `sys.conext` (`True`/`False`) |
| Temperature Input | `heatpump.tinp` (`wireless`, `external`, `internal`) |
| Wifi Signal, Ip Address | `wifi.rssi`, `wifi.ip` |
| Firmware | `fw.curr`, `fw.last` |
| Uptime, Module ID | `sys.up` (seconds), `sys.id` |
| Mac Address (also the device network id) | `wifi.mac` |
| Device name at discovery | `sys.frname` |
| Wireless Thermometer | `sensor.thermometer.tact` (°C), `hact` (% humidity), `batt` (% battery); shown while `heatpump.tinp` is `wireless` |

If a reading stays blank on a real module, the hub log line `status JSON layout top: … | heatpump: …` shows which keys the module actually sends.

## Files

- `profiles/`: `climacontrol-panasonic.v3` (standard) and `climacontrol-panasonic-thermometer.v1` (with the Wireless Thermometer component).
- `capabilities/`: the custom capability definitions and presentations (namespace `aboutisland47519`): Preset, Vertical Vane, Horizontal Vane, Indoor Unit Link, Temperature Input, Firmware, Uptime, Module ID, Restart Module. Wifi Signal, Ip Address and Mac Address are shared with the Big Ass Fans driver.

- `src/init.lua`: device lifecycle, polling, commands.
- `src/status.lua`: translation between module and SmartThings values (plain Lua, testable without a hub).
- `src/api.lua`: HTTP client.
- `src/discovery.lua`: mDNS discovery.
