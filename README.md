# DPS Meter for ArcheAge Classic

A small damage meter that splits combat into fights, so you can see what you and your group did in the pull you just finished, the ones before it, and the whole session.

## Install

With [AAC Addon Manager](https://github.com/Z-arium/AAC-ADDON_MANAGER):

```bash
aacam install --repo Z-arium/aac-dps-meter
```

By hand: download the latest release, unzip it into your `Addon` folder (on Linux usually `~/Documents/AAClassic/Addon`) and rename the folder to `dps_meter`, so the files sit at `Addon/dps_meter/main.lua`. Then add a line `dps_meter` to `Addon/addons.txt`.

The folder must be called `dps_meter`, because the addon loads its files from there.

## Use

- Click **DPS** in the title to cycle what is shown: DPS, Damage, HPS, Healing, Damage Taken.
- Click **Current** to step back through earlier fights (Previous 1, 2, ...) and then **Overall**.
- Click **Group** to switch between you and your party/raid, and everyone your client sees fighting.
- Click a row to see that person's skills, with amounts and shares.
- The reset button clears every fight.
- Hold **Shift** and drag the title to move the meter. Its position, view and scope are saved.

The bottom line always shows your own number and rank, and the fight timer.

## How fights work

A fight starts when you or a group member deal, take or heal damage, and ends after 6 seconds with none of that. Fighting nearby doesn't start or stretch your fight, but while your fight is on, everyone's numbers are recorded so the Everyone view works. DPS is total damage divided by the fight's length; Overall counts only time spent in fights, so running between packs doesn't drag your DPS down. The last 10 fights are kept.

Bar colours: teal is you, blue is your group, grey is everyone else.

## Limits

- The game only reports combat your client can see, so people far away are missing.
- Pets show under their own names.
- Nothing is saved between sessions yet.

## Development

The fight logic in `fights.lua` uses no game API, and the tests run it, and a smoke test of the whole addon against a stand-in game API, under Lua 5.1:

```bash
pip install lupa
python3 -m unittest discover -s tests
```

Releases: bump `version` in `main.lua`, then push a tag like `v0.1.0`, or run the ci workflow by hand with that tag as its input. CI runs the tests and publishes the GitHub release.
