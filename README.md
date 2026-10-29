# DPS Meter for ArcheAge Classic

A stats meter that splits combat into fights. See damage, DPS, healing, HPS, damage taken and damage absorbed for you, your group, every player around you or everyone, in the pull you just finished, the ones before it, or the whole session. Click anyone to see their skills with hits, crit rate, average and biggest hit, and who they hit.

## Install

With [AAC Addon Manager](https://github.com/Z-arium/AAC-ADDON_MANAGER):

```bash
aacam install --repo Z-arium/aac-dps-meter
```

By hand: download the latest release, unzip it into your `Addon` folder (on Linux usually `~/Documents/AAClassic/Addon`) and rename the folder to `dps_meter`, so the files sit at `Addon/dps_meter/main.lua`. Then add a line `dps_meter` to `Addon/addons.txt`.

The folder must be called `dps_meter`, because the addon loads its files from there.

## Use

- Click **DPS** in the title to cycle what is shown: DPS, Damage, HPS, Healing, Damage Taken, Absorbed (damage your armour and resistances took off).
- Click **Current** to step back through earlier fights (Previous 1, 2, ...) and then **Overall**.
- Click **Group** to cycle who is listed: your party or raid, every player your client has identified (including hostile ones), or All (NPCs too).
- Click a name for their breakdown: totals, crit rate and how often they missed, then each skill's amount, share, hits, crit rate, average and biggest hit, and the targets they damaged.
- Scroll with the mouse wheel to see past the top 10. If you are out of view you stay pinned to the last row with your real rank.
- The bottom line always shows your own number and rank, and the fight timer.
- **_** minimizes the meter to a small bar that still shows your number; **+** brings it back.
- The reset button saves everything so far to `Addon/dps_meter/logs/` and clears the meter.
- Hold **Shift** and drag the title to move the meter. Position, view, scope and minimized state are saved.

Bar colours: teal is you, blue your group, green other players, red hostile players, dark red hostile NPCs, orange friendly NPCs, grey anyone the game hasn't told us about yet.

## How fights work

A fight starts when you or a group member deal, take or heal damage, and ends after 6 seconds with none of that. Fighting nearby doesn't start or stretch your fight, but while your fight is on, everyone's numbers are recorded so the other scopes work. DPS is total damage divided by the fight's length; Overall counts only time spent in fights, so running between packs doesn't drag your DPS down. The last 10 fights are kept, so there is no need to reset between dungeon pulls.

Damage and healing over time are credited to whoever cast them, matched through the combat text the game sends with each tick.

## Limits

- The game only reports combat your client can see, so people far away are missing.
- The addon API only describes you, your target and your party or raid, so other players only count as players (and get a colour) once you have targeted them; until then they appear under All in grey.
- Pets show under their own names.
- Fights are kept until you reload or log out; the logs folder has what you reset.

## Development

The fight logic in `fights.lua` uses no game API, and the tests run it, and a smoke test of the whole addon against a stand-in game API, under Lua 5.1:

```bash
pip install lupa
python3 -m unittest discover -s tests
```

Releases: bump `version` in `main.lua`, then push a tag like `v0.1.0`, or run the ci workflow by hand with that tag as its input. CI runs the tests and publishes the GitHub release.
