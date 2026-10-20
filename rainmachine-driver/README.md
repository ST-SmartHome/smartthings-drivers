# rainmachine-lan

SmartThings Edge driver for RainMachine irrigation controllers (Mini-8, Touch HD-12/16, Pro-8/16). It uses the controller's local HTTP API, with no cloud. The controller is found by mDNS, so the only setting you have to enter is its password.

Community thread: https://community.smartthings.com/t/st-edge-rainmachine-lan-driver-local-control-no-cloud-or-subscription-rainmachine-lan/311412

## Devices

- **RainMachine** (controller):
  - Irrigation Status. While a program runs it shows the program, the running zone and when everything finishes (e.g. "Evening: Zone 1 5 min, done 20:30"). Otherwise e.g. "Watering Zone 1, 4 min left", "2 zones queued", "Paused: rain delay", "Stopped by user";
  - Next Watering, with RainMachine's own calculated run time, or the reason when it will skip (e.g. "Skipped: Rain");
  - Weather Forecast for today and tomorrow;
  - Weather Today;
  - Rain Delay (0–14 days);
  - **Pause Watering** (15 min, 30 min, 1 h or 2 h, or Not paused to resume). Like Pause in the RainMachine app: running zones wait and carry on where they stopped. A pause started in the RainMachine app shows here too, as "Paused until 16:45";
  - Stop All Watering.
- **Zone N: <name>**, one per active zone. The switch waters for the zone's **Watering Time** (1–120 min). Changing it while the zone runs changes that run in place, like the zone's slider in the RainMachine app.
  - Watering Time follows the zone's weather-adjusted time for its next scheduled run. A time you set yourself is kept until that zone's next run ends.
  - Tiles:
    - Time Remaining;
    - **Last Watered** (when and how long);
    - **Next Watering** (when and how long, or why it will skip);
    - **Last Seven Days** (total watering time).
  - Read-only zone settings from the RainMachine app: **Soil Type**, **Vegetation Type**, **Sprinkler Heads**, **Slope**, **Exposure**.
- **Program: <name>**, one per active program. The switch starts or stops it, exactly like Run in the RainMachine app (RainMachine runs a manual start at the program's set times). Next Run is shown.
  - One tile per zone in run order, with today's weather-adjusted minutes and start time.
  - While it runs: 💦 watering, ⏳ queued with its start time, ✅ done.

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
It is also left out of the controller's Irrigation Status, so the status shows the zone that is actually watering.

- **Pro-8/16:** the master valve has its own terminal (valve 1), and zones are numbered from valve 2.
- **Mini-8 and HD:** a zone set as the master valve is left out.

## Notes

- Schedules, zone durations and restrictions are set in the RainMachine app. The driver shows them and controls watering, but doesn't edit programs.
- **Stop All** stops what's running and clears the queue. **Pause Watering** holds it and carries on afterwards. Neither cancels future schedules; use Rain Delay for that.
- Every command is the same API call RainMachine's own app makes, so starting, stopping, pausing and changing times behave as they do in the app.
- The SmartThings app may show the values from your last visit when you open the page, and update them slowly. Pull down to refresh.
- After a driver update that adds tiles, open each zone and program device once (or pull down to refresh) so the app shows them.
- **Tested** on a Pro-8; an HD-12 has been confirmed by a community user. Reports from Mini-8, HD-16, Pro-16 and 1st-generation Touch owners are welcome.
- **One controller per hub** for now.

## Source

- `src/rm_api.lua`: local API client (login, token renewal; URLs are never logged because the token is a query parameter).
- `src/init.lua`: polling, child devices, status, weather and forecast, commands, connection health.
- `src/display.lua`: the text for the program zone tiles, Irrigation Status while a program runs, and the zone history tiles (no SmartThings modules, so it can be tested off the hub).
- `src/discovery.lua`: mDNS lookup (`_http._tcp` / `_hap._tcp`, instance name containing "rainmachine") and creation of the first controller.
- `capabilities/`: the custom capability definitions and presentations (namespace `aboutisland47519`).

API reference: [RainMachine API v4](https://github.com/nicupavel/rainmachine-api); request bodies were checked against RainMachine's own [web UI](https://github.com/sprinkler/rainmachine-web-ui).
