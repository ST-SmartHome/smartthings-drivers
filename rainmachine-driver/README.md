# rainmachine-lan

SmartThings Edge driver for RainMachine irrigation controllers (Mini-8, Touch HD-12/16, Pro-8/16). It uses the controller's local HTTP API, with no cloud. The controller is found by mDNS, so the only setting you have to enter is its password.

Community thread: https://community.smartthings.com/t/title-st-edge-rainmachine-lan-driver-local-control-no-cloud-or-subscription-rainmachine-lan/311412

## Devices

- **RainMachine** (controller):
  - Irrigation Status (e.g. "Watering Zone 1, 4 min left", "2 zones queued", "Paused: rain delay", "Stopped by user");
  - Next Watering, with RainMachine's own calculated run time, or the reason when it will skip (e.g. "Skipped: Rain");
  - Weather Forecast for today and tomorrow;
  - Weather Today;
  - Rain Delay (0–14 days);
  - Stop All Watering.
- **Zone N: <name>**, one per active zone. The switch waters for the zone's **Watering Time** (1–120 min, adjustable while running). Time Remaining is shown.
- **Program: <name>**, one per active program. The switch starts or stops it. Next Run is shown.

Zone and program devices are created once the driver has logged in and read them. They are never deleted automatically: an inactive or removed zone shows offline. A device you delete stays deleted until you run **Scan Nearby** again.

## Setup

1. **Add Device → Scan Nearby.** A "RainMachine" device appears.
2. In its settings, enter the **Password**: the one you use for the RainMachine app or web page. No email address is needed, because the local API takes only the password.
3. Zone and program devices appear within a few seconds.

Settings:

- **IP Address (optional):** leave as `0.0.0.0` for automatic discovery. Set it if mDNS doesn't reach the hub.
- **HTTP Port:** 8081, RainMachine's plain-HTTP API. It's on by default.
- **Poll Interval:** 30 s by default; every 10 s while watering.

A wrong password or IP shows the controller offline, with the reason in Irrigation Status.

## Weather

- **Weather Forecast:** RainMachine's combined forecast. It shows each day's condition, min–max temperature, and rain amount and chance when rain is forecast.
- **Weather Today:** the latest actual reading when one of your weather sources reports observations (e.g. a personal weather station or a national weather service). Otherwise it shows RainMachine's combined figure for the day.
- **Units:** follow the RainMachine app's setting (metric or imperial).

## Master valve

The master valve never gets a device. RainMachine opens it automatically whenever a zone runs, and switching it on alone could run a pump against closed zones.

- **Pro-8/16:** the master valve has its own terminal (valve 1), and zones are numbered from valve 2.
- **Mini-8 and HD:** a zone set as the master valve is left out.

## Notes

- Schedules, zone durations and restrictions are set in the RainMachine app. The driver shows them and controls watering, but doesn't edit programs.
- **Stop All** stops what's running and clears the queue. It doesn't cancel future schedules; use Rain Delay for that.
- The SmartThings app may not refresh text tiles on an open page. Pull down to refresh.

## Source

- `src/rm_api.lua`: local API client (login, token renewal; URLs are never logged because the token is a query parameter).
- `src/init.lua`: polling, child devices, status, weather and forecast, commands, connection health.
- `src/discovery.lua`: mDNS lookup (`_http._tcp` / `_hap._tcp`, instance name containing "rainmachine") and creation of the first controller.
- `capabilities/`: the custom capability definitions and presentations (namespace `aboutisland47519`).

API reference: [RainMachine API v4](https://github.com/nicupavel/rainmachine-api); request bodies were checked against RainMachine's own [web UI](https://github.com/sprinkler/rainmachine-web-ui).
