# WeatherChecker

An Ashita v4 addon for LSB-based FFXI servers that shows the upcoming zone
weather and lets you set reminders that count down to it.

Weather in LandSandBoat is scheduled: each zone has a fixed 2160-Vana'diel-day
table of "on this day, the possible weather is A (50%), B (35%), or C (15%)".
This addon reads that table directly (baked into `data/weather_data.lua`
ahead of time) and cross-references it against the game's live Vana'diel
clock, so it can tell you exactly when a weather type becomes possible in any
zone it knows about — no guessing, no waiting around.

## Install

Copy the whole `weatherchecker` folder into your Ashita `addons` directory,
so you end up with:

```
addons/weatherchecker/weatherchecker.lua
addons/weatherchecker/data/weather_data.lua
```

Then in-game: `/addon load weatherchecker`

## Commands

| Command | What it does |
|---|---|
| `/w` | Your current zone's next 3 days of weather. |
| `/w <zone>` | The specified zone's next 3 days of weather. |
| `/w <zone> <weather>` | That zone's next 3 instances of a specific weather type. |
| `/w <weather>` | Soonest match for that weather, per zone, across every zone this addon knows about. |
| `/w remind` | Shows your currently tracked reminders and time remaining on each. |
| `/w remind <#>` | Sets a reminder for the `(#)` row from your last lookup. |
| `/w cancel <#>` | Cancels the reminder numbered `(#)`. |
| `/w help` | Prints the command list and a short explanation of how weather actually works. |

Every lookup result is printed with a `(#)` in front of each line — that
number is what you pass to `/w remind` to track that specific entry.

```
/w qufim light
(1) Qufim Island -- 1508/6/22 (Windsday) -- in 1d 12h  Common: None  Normal: Thunder  Rare: Light
(2) Qufim Island -- 1508/6/23 (Iceday)   -- in 1d 13h  Common: Thunder  Normal: None  Rare: Light
(3) Qufim Island -- 1508/7/1  (Iceday)   -- in 1d 20h  Common: Light  Normal: Thunder  Rare: Light

/w remind 1
Reminder (1) set: Qufim Island -- None/Thunder/Light -- in 1d 12h
```

### Zone names

Fuzzy-matched, so partial names work — `qufim` resolves to `Qufim Island`.
If your query matches more than one zone name, the shortest matching name
wins (so a short, specific query doesn't accidentally land on some unrelated
longer name that happens to contain the same letters).

### Weather vocabulary

Weather is specified by **element**, not by the specific weather name:

```
light  dark  fire  water  earth  wind  ice  thunder
```

Typing an element name alone matches **both tiers** of it — `/w earth`
matches Dust Storm *and* Sandstorm. To narrow to one tier only, append `1`
(tier I) or `2` (tier II):

```
/w earth1     -- Dust Storm only
/w earth2     -- Sandstorm only
```

Non-elemental weather still has plain names: `sunshine`, `clouds`, `fog`,
along with a couple of aliases (`sunny`, `clear`, `cloudy`, `foggy`).

**Fog is a special case.** It isn't part of the day-by-day weather table at
all — see [Known limitations](#known-limitations) below. `/w fog` (or any
zone + fog combination) explains this instead of returning an empty result.

### Reminders

- Each active reminder gets a single-digit id, 1 through 9. When a reminder
  is cancelled or finishes counting down, its id frees up for the next one
  you set — ids are never left to climb indefinitely.
- Warnings fire at **60, 30, 5, and 0 minutes** before the weather window
  starts, e.g.:
  ```
  30 Minutes until None/Water/Light weather in Qufim Island.
  ...
  None/Water/Light weather has started in Qufim Island.
  ```
  If you arm a reminder when less than 60 minutes remain, whichever earlier
  thresholds have already effectively passed are skipped rather than firing
  immediately.
- Up to 9 reminders can be tracked at once. `/w remind` with no number always
  shows what's currently tracked and how long is left on each.

## Regenerating the weather data

`data/weather_data.lua` is generated from LandSandBoat's own SQL dumps by
`gen_weather_data.py`. **If your server customizes its zone weather tables,
regenerate this file from your own server's database** — the data shipped
here comes from LSB's public `base` branch and will only be exactly right if
your server hasn't changed it.

```
python3 gen_weather_data.py path/to/lsb/sql
```

That path should point at a folder containing `zone_settings.sql` and
`zone_weather.sql` — either LandSandBoat's own `sql/` folder, or a fresh dump
from your live server database in the same format. To pull straight from a
live database instead of using checked-in SQL files:

```sql
SELECT * FROM zone_settings;
SELECT zoneid, HEX(weather) FROM zone_weather;
```

Save those results in the same `INSERT INTO ... VALUES (...)` style the LSB
`sql/` files use, point the script at the folder containing them, and it'll
regenerate `data/weather_data.lua` in place.

### Trimming which zones are included

The script only includes zones listed in the `KEEP_IDS` set near the top of
`gen_weather_data.py`. Add or remove zone ids there to change what the addon
knows about — everything else in the script stays the same.

## Known limitations

**Fog is not schedule-based.** Per LandSandBoat's own `src/map/zone.cpp`,
Fog is a runtime override applied *after* the normal weather roll: if the
current Vana'diel time is 2:00–7:00 AM, the zone isn't a city, and the roll
came up None/Sunshine/Clouds, the server swaps the result to Fog on the
spot. It was never written into any zone's day-by-day table, so there is no
schedule for this addon (or anything like it) to predict. `/w fog` explains
this instead of pretending to search for something that isn't there.

**Data accuracy depends on your source.** This addon's predictions are only
as good as `data/weather_data.lua`. It was generated from LandSandBoat's
public `base` branch — if the server you're playing on has modified its
`zone_weather` table (intentionally or as part of a fork), regenerate the
data file from that server's actual database rather than trusting the
version shipped here. One data point in this addon's favor: the underlying
decode logic was cross-checked byte-for-byte against a live server's actual
`/clock` output and a widely-used community weather tracker during
development, and matched exactly — the algorithm is sound, it's specifically
*whose database* the table came from that matters.

**Only tracks zones in `KEEP_IDS`.** By design, not every zone in the game
is included — see "Trimming which zones are included" above if you want to
add more.

## Credits

- Vana'diel time reading is ported from
  [clockvana](https://github.com/ConteAlmaviva/clockvana) (atom0s, modified
  by Almavivaconte), itself based on Ashita v3's `vanatime` library. The
  memory signature and timestamp math are theirs — this addon adds the
  weather-table lookups and reminder system on top.
- Weather table data and the day-resolution algorithm come from
  [LandSandBoat](https://github.com/LandSandBoat/server)'s `base` branch.
