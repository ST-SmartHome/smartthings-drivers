#!/usr/bin/env python3
"""Generate the Panasonic air conditioner profile variants.

profiles/climacontrol-panasonic.yml (all extras, no sensors) is the template:
edit components or preferences there, then run this script to rewrite the
variants. Each variant leaves out the extras its "Unit features" setting says
the unit lacks, and adds the Wireless Thermometer and/or Windows/Doors
components when sensors are paired. Run from the driver folder:

    python3 tools/make_profiles.py
"""
import json
import os
import re

import yaml

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILES = os.path.join(HERE, "profiles")
TEMPLATE = os.path.join(PROFILES, "climacontrol-panasonic.yml")

# What each feature set's profile leaves out is read from HIDES in
# src/init.lua, the single definition the driver also uses. "widevane" there
# means the main component's left/right louvre (horizontalVane); the rest are
# whole components. "minimal" is not a setting: Basic without Eco, used when
# the unit rejects Eco.
def read_hides():
    src = open(os.path.join(HERE, "src", "init.lua")).read()
    block = re.search(r"(?m)^local HIDES = \{\n(.*?)\n\}", src, re.S).group(1)
    hides = {}
    for name, body in re.findall(r"(\w+) = \{([^}]*)\}", block):
        hides[name] = frozenset(re.findall(r"(\w+) = true", body))
    return hides


HIDES = read_hides()
DROP = {name: sorted(h - {"widevane"}) for name, h in HIDES.items()}

# Sensor batteries are a tile in their own section (the standard battery
# capability would be lifted to the single icon at the top of the page).
SENSORS = {
    "thermometer": '''  - id: thermometer
    label: "Wireless Thermometer"
    capabilities:
      - id: temperatureMeasurement
        version: 1
      - id: relativeHumidityMeasurement
        version: 1
      - id: aboutisland47519.sensorBattery
        version: 1
''',
    "window": '''  - id: window
    label: "Windows/Doors"
    capabilities:
      - id: contactSensor
        version: 1
      - id: aboutisland47519.sensorBattery
        version: 1
''',
}

# Names kept from before this script existed (devices already use them).
LEGACY = {("all", False, False): "climacontrol-panasonic.v3",
          ("all", True, False): "climacontrol-panasonic-thermometer.v1"}


def split(text):
    """Header line, component blocks (id -> text, in order), the rest."""
    head, rest = text.split("components:\n", 1)
    comps, tail = rest.split("preferences:\n", 1)
    blocks = re.split(r"(?m)^(?=  - id: )", comps)
    order = []
    for b in blocks:
        if b.strip():
            order.append((re.match(r"  - id: (\w+)", b).group(1), b))
    return head, order, "preferences:\n" + tail


# Every combination of hidden extras gets a profile, so the driver can hide
# exactly what a unit rejected. Combinations matching a "Unit features" choice
# keep that choice's name; the others are named by code letters:
# e = Eco, v = Eco Navi, n = nanoe X, d = Mild Dry, w = left/right louvre.
EXTRAS = ["eco", "econavi", "nanoex", "milddry", "widevane"]
CODE = {"eco": "e", "econavi": "v", "nanoex": "n", "milddry": "d", "widevane": "w"}


def hidden_of(features):
    return HIDES[features]


NAMED = {hidden_of(f): f for f in DROP}


def profile_name(hidden, thermometer, window):
    features = NAMED.get(frozenset(hidden))
    if features is not None and LEGACY.get((features, thermometer, window)):
        return LEGACY[(features, thermometer, window)]
    suffix = ("" if features == "all" else "-" + features) if features is not None \
        else "-x" + "".join(CODE[k] for k in EXTRAS if k in hidden)
    return ("climacontrol-panasonic" + ("-thermometer" if thermometer else "")
            + ("-window" if window else "") + suffix + ".v1")


def build(hidden, thermometer, window):
    head, comps, prefs = split(open(TEMPLATE).read())
    out = []
    for cid, block in comps:
        if cid in hidden:
            continue
        if cid == "main" and "widevane" in hidden:
            block = block.replace("      - id: aboutisland47519.horizontalVane\n        version: 1\n", "")
        if cid == "module":
            if thermometer:
                out.append(SENSORS["thermometer"])
            if window:
                out.append(SENSORS["window"])
        out.append(block)
    name = profile_name(hidden, thermometer, window)
    head = re.sub(r"(?m)^name: .*$", "name: " + name, head)
    return name, head + "components:\n" + "".join(out) + prefs


def main():
    for mask in range(1 << len(EXTRAS)):
        hidden = frozenset(k for i, k in enumerate(EXTRAS) if mask >> i & 1)
        for thermometer in (False, True):
            for window in (False, True):
                if not hidden and not thermometer and not window:
                    continue   # the template itself
                name, text = build(hidden, thermometer, window)
                if not any(hidden_of(f) == hidden for f in DROP):
                    # Code-named profiles are written as compact JSON (valid
                    # YAML): the driver package is limited to 640 KB.
                    text = json.dumps(yaml.safe_load(text), ensure_ascii=False, separators=(",", ":")) + "\n"
                path = os.path.join(PROFILES, name.rsplit(".", 1)[0] + ".yml")
                with open(path, "w") as f:
                    f.write(text)


if __name__ == "__main__":
    main()
