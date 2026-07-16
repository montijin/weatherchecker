--[[
* WeatherChecker - Ashita v4 addon
*
* Predicts upcoming zone weather for LSB-based FFXI servers, and lets you set
* reminders that count down to a specific upcoming weather window.
*
* Vana'diel time reading is ported from clockvana.lua (atom0s, modified by
* Almavivaconte: https://github.com/ConteAlmaviva/clockvana), itself based on
* the Ashita v3 `vanatime` lib. Credit to atom0s / Almavivaconte for the
* memory signature and timestamp math -- this addon adds the weather-table
* lookups and reminder system on top of it.
*
* Weather table data is sourced from LandSandBoat's `base` branch
* (sql/zone_weather.sql + sql/zone_settings.sql), pre-decoded into
* data/weather_data.lua by gen_weather_data.py. See README.md for how to
* regenerate that file from your own server's database if it customizes
* zone weather.
--]]

addon.name    = 'weatherchecker';
addon.author  = 'Monti';
addon.version = '1.2';
addon.desc    = 'Weather predictions and reminders for LSB-based servers.';
addon.link    = '';

require('common');
local chat = require('chat');
local settings = require('settings');

--------------------------------------------------------------------------------------------------
-- Vana'diel time
--
-- The game client keeps its own Vana'diel clock in memory. Reading it directly
-- (rather than reconstructing it from the real-world clock + an epoch guess)
-- means this addon is always exactly in sync with the server, with no risk of
-- drift or timezone mistakes.
--------------------------------------------------------------------------------------------------

-- Locates the FFXI client's internal Vana'diel timestamp pointer once at load time.
local vanatime_ptr = ashita.memory.find('FFXiMain.dll', 0, 'B0015EC390518B4C24088D4424005068', 0x34, 0);
if (vanatime_ptr == 0) then
    error('weatherchecker -- vanatime signature scan failed! (a client update may have broken this)');
end

-- Current Vana'diel time in "vana-seconds": a value that counts up 25x faster
-- than real time, matching the game's own clock exactly.
local function get_vana_seconds()
    local pointer = ashita.memory.read_uint32(vanatime_ptr);
    local raw = ashita.memory.read_uint32(pointer + 0x0C);
    return (raw + 92514960) * 25;
end

-- Current absolute Vana'diel day count (a day is 86400 vana-seconds), in the
-- CLIENT's calendar-display epoch -- this is the number that matches /clock's
-- displayed Y/M/D directly, with no offset needed.
local function get_vana_day()
    return math.floor(get_vana_seconds() / 86400);
end

local CYCLE_LENGTH_DAYS = 2160; -- the zone weather tables repeat on this cycle
local DAYTYPE_NAMES = { 'Firesday', 'Earthsday', 'Watersday', 'Windsday', 'Iceday', 'Lightningday', 'Lightsday', 'Darksday' };

-- IMPORTANT: the SERVER's weather table is NOT indexed using the calendar-
-- display day count above. Per src/common/vana_time.h, the server's raw
-- Vana'diel clock is zeroed at year 0, not year 886 (get_year() there is
-- explicitly commented "years since 886" and does NOT add 886 -- callers are
-- expected to). The zone weather system (src/map/zone.cpp, UpdateWeather())
-- indexes its table using that RAW, un-shifted day count directly. The
-- client's memory (what get_vana_day() above reads) is already in shifted,
-- calendar-ready space, so weather-table lookups need this offset backed out
-- first -- otherwise every lookup silently searches 886 years in the wrong
-- place in the table. (Found this the hard way: a live in-game weather
-- observation didn't match what this addon predicted, and it traced back to
-- exactly this 886-year/318960-day gap.)
local WEATHER_EPOCH_SHIFT_DAYS = 886 * 360;

-- The day count to use for ALL weather-table math (cycle indexing, row
-- start/end days, countdowns). Never use get_vana_day()/get_vana_seconds()
-- directly for weather lookups -- only for calendar display.
local function get_weather_day()
    return get_vana_day() - WEATHER_EPOCH_SHIFT_DAYS;
end
local function get_weather_seconds()
    return get_vana_seconds() - (WEATHER_EPOCH_SHIFT_DAYS * 86400);
end

-- Converts a day number FROM WEATHER-EPOCH SPACE (i.e. one of find_zone_rows'
-- row.startDay/endDay values) into the calendar date /clock would show for
-- that same moment: 12 months of 30 days, 360-day years, shifted back into
-- calendar-display space before the usual month/day/weekday math.
-- (Lua's % is floor-mod, so this works correctly for any sign of `day`.)
local function day_to_calendar(weatherDay)
    local day = weatherDay + WEATHER_EPOCH_SHIFT_DAYS;
    local dayOfYear = day % 360;
    local year = math.floor(day / 360);
    local month = math.floor(dayOfYear / 30) + 1;
    local dayOfMonth = (dayOfYear % 30) + 1;
    local weekday = DAYTYPE_NAMES[(day % 8) + 1];
    return year, month, dayOfMonth, weekday;
end

-- Real-world hours remaining until a target day boundary. `targetDay` and
-- `nowVanaSeconds` must be in the SAME day-space (both weather-epoch space,
-- in every actual call site below) -- the function itself is space-agnostic,
-- it just measures the gap between the two.
local function hours_until(targetDay, nowVanaSeconds)
    local deltaVanaSeconds = (targetDay * 86400) - nowVanaSeconds;
    return (deltaVanaSeconds / 25) / 3600; -- /25 converts vana-seconds back to real seconds
end

local function minutes_until(targetDay, nowVanaSeconds)
    return hours_until(targetDay, nowVanaSeconds) * 60;
end

-- Formats hours as "1d 2h", "2h 3m", or "3m" -- whichever units are relevant.
local function format_hours(h)
    if (h < 0) then h = 0; end
    local totalMinutes = math.floor((h * 60) + 0.5);
    local days = math.floor(totalMinutes / 1440);
    local hours = math.floor((totalMinutes % 1440) / 60);
    local minutes = totalMinutes % 60;
    if (days > 0) then return string.format('%dd %dh', days, hours); end
    if (hours > 0) then return string.format('%dh %dm', hours, minutes); end
    return string.format('%dm', minutes);
end

--------------------------------------------------------------------------------------------------
-- Weather metadata (data/enums/weather.yaml + element pairing, from LandSandBoat source)
--------------------------------------------------------------------------------------------------

local WEATHER_META = {
    [1]  = { name = 'Sunshine',        element = 'none' },
    [2]  = { name = 'Clouds',          element = 'none' },
    [3]  = { name = 'Fog',             element = 'none' },
    [4]  = { name = 'Hot Spell',       element = 'fire',    tier = 'I' },
    [5]  = { name = 'Heat Wave',       element = 'fire',    tier = 'II' },
    [6]  = { name = 'Rain',            element = 'water',   tier = 'I' },
    [7]  = { name = 'Squall',          element = 'water',   tier = 'II' },
    [8]  = { name = 'Dust Storm',      element = 'earth',   tier = 'I' },
    [9]  = { name = 'Sandstorm',       element = 'earth',   tier = 'II' },
    [10] = { name = 'Wind',            element = 'wind',    tier = 'I' },
    [11] = { name = 'Gales',           element = 'wind',    tier = 'II' },
    [12] = { name = 'Snow',            element = 'ice',     tier = 'I' },
    [13] = { name = 'Blizzards',       element = 'ice',     tier = 'II' },
    [14] = { name = 'Thunder',         element = 'thunder', tier = 'I' },
    [15] = { name = 'Thunderstorms',   element = 'thunder', tier = 'II' },
    [16] = { name = 'Auroras',         element = 'light',   tier = 'I' },
    [17] = { name = 'Stellar Glare',   element = 'light',   tier = 'II' },
    [18] = { name = 'Gloom',           element = 'dark',    tier = 'I' },
    [19] = { name = 'Darkness',        element = 'dark',    tier = 'II' },
};

local ELEMENT_LABEL = {
    light = 'Light', dark = 'Dark', fire = 'Fire', water = 'Water',
    earth = 'Earth', wind = 'Wind', ice = 'Ice', thunder = 'Thunder',
};

-- Displays weather by its element (e.g. "Water"), not its specific name (e.g.
-- "Rain") or tier -- matches the element-based input vocabulary below.
-- Non-elemental weather (sunshine/clouds/fog, or no weather at all in a slot)
-- collapses to a single "None", since none of them are useful to distinguish
-- for weather-hunting purposes.
local function weather_label(wid)
    local meta = WEATHER_META[wid];
    if (meta == nil or meta.element == 'none') then
        return 'None';
    end
    return ELEMENT_LABEL[meta.element];
end

-- Input keyword -> filter mapping. A filter is one of:
--   'all'        - match anything
--   'el:<name>'  - match either tier of that element (e.g. 'el:earth')
--   'id:<n>'     - match one specific weather id only (e.g. 'id:9' = Sandstorm)
local ALIAS_TO_FILTER = {};

-- Bare element name matches both tiers, e.g. typing "earth" matches both
-- Dust Storm and Sandstorm.
local ELEMENT_KEYWORDS = { 'light', 'dark', 'fire', 'water', 'earth', 'wind', 'ice', 'thunder' };
for _, el in ipairs(ELEMENT_KEYWORDS) do
    ALIAS_TO_FILTER[el] = 'el:' .. el;
end

-- Appending 1 or 2 to an element name narrows to that tier only, e.g. "earth2"
-- matches Sandstorm (tier II) only, not Dust Storm (tier I).
local ELEMENT_TIER_IDS = {
    fire = { 4, 5 }, water = { 6, 7 }, earth = { 8, 9 }, wind = { 10, 11 },
    ice = { 12, 13 }, thunder = { 14, 15 }, light = { 16, 17 }, dark = { 18, 19 },
};
for el, ids in pairs(ELEMENT_TIER_IDS) do
    ALIAS_TO_FILTER[el .. '1'] = 'id:' .. ids[1];
    ALIAS_TO_FILTER[el .. '2'] = 'id:' .. ids[2];
end

-- Non-elemental weather has no tier system, so it just gets plain-word aliases.
local ID_ALIASES = {
    [1] = { 'sunshine', 'sunny', 'clear' },
    [2] = { 'clouds', 'cloudy' },
    [3] = { 'fog', 'foggy' },
};
for wid, aliases in pairs(ID_ALIASES) do
    for _, alias in ipairs(aliases) do
        ALIAS_TO_FILTER[alias] = 'id:' .. wid;
    end
end

--------------------------------------------------------------------------------------------------
-- Zone weather data (generated -- see gen_weather_data.py and README.md)
--------------------------------------------------------------------------------------------------

-- Loaded via an explicit path anchored to this addon's own folder (addon.path)
-- rather than require(), since require()'s search-path resolution depends on
-- exactly how/where Ashita was launched, and was a real source of "module not
-- found" errors during development that had nothing to do with a missing file.
local dataPath = addon.path .. 'data\\weather_data.lua';
local dataChunk, dataLoadError = loadfile(dataPath);
if (dataChunk == nil) then
    error('weatherchecker -- could not load ' .. dataPath .. ' -- ' .. tostring(dataLoadError) ..
          ' -- make sure data\\weather_data.lua sits directly inside the weatherchecker addon folder.');
end
local ZONES = dataChunk(); -- { [zoneid] = { name = "...", cps = { {day,normal,common,rare}, ... } }, ... }

local function normalize(s)
    return (s:lower():gsub('[^%w]', ''));
end

-- Precomputed once at load time so zone lookups don't re-normalize every name
-- on every command.
local ZONE_INDEX = {};
for zid, zone in pairs(ZONES) do
    ZONE_INDEX[#ZONE_INDEX + 1] = { zid = zid, norm = normalize(zone.name), name = zone.name };
end

-- Fuzzy zone lookup: an exact normalized match wins outright; otherwise the
-- shortest zone name that CONTAINS the query wins (so "qufim" resolves to
-- "Qufim Island" rather than some unrelated longer name that also happens to
-- contain those letters).
local function find_zone(query)
    if (query == nil or query == '') then return nil, nil; end
    local normalizedQuery = normalize(query);
    local bestMatch = nil;
    for _, entry in ipairs(ZONE_INDEX) do
        if (entry.norm == normalizedQuery) then
            return entry.zid, entry.name; -- exact match, stop looking
        end
        if (entry.norm:find(normalizedQuery, 1, true) and
            (bestMatch == nil or #entry.norm < #bestMatch.norm)) then
            bestMatch = entry;
        end
    end
    if (bestMatch == nil) then return nil, nil; end
    return bestMatch.zid, bestMatch.name;
end

-- Some zones are manually merged into one named region for cross-zone
-- weather searches, so a search doesn't spam near-duplicate rows for zones
-- that happen to roll identically. This is a deliberate, curated list --
-- NOT automatic detection -- so add entries here by hand as needed; every
-- zone not listed just shows under its own name as normal.
local MANUAL_REGIONS = {
    { name = 'Qufim Region', zoneIds = { 126, 127, 157, 158, 184 } }, -- Qufim Island, Behemoth's Dominion, Lower/Middle/Upper Delkfutt's Tower
};

-- Builds ZONE_GROUPS: one entry per manual region above (using its first
-- listed zone's table -- the whole point of grouping them is that they're
-- identical), plus one singleton entry per zone that isn't part of any
-- manual region. Used only by "/w <weather>" (no zone given); looking up a
-- specific zone by name always shows just that zone under its own name.
local ZONE_GROUPS = (function()
    local groups = {};
    local grouped = {}; -- zoneId -> true, so singleton zones can skip anything already covered

    for _, region in ipairs(MANUAL_REGIONS) do
        local firstZone = ZONES[region.zoneIds[1]];
        if (firstZone ~= nil) then
            groups[#groups + 1] = { displayName = region.name, cps = firstZone.cps };
            for _, zid in ipairs(region.zoneIds) do grouped[zid] = true; end
        end
    end

    for zid, zone in pairs(ZONES) do
        if (not grouped[zid]) then
            groups[#groups + 1] = { displayName = zone.name, cps = zone.cps };
        end
    end

    return groups;
end)();

--------------------------------------------------------------------------------------------------
-- Prediction logic
--
-- Each zone's weather table is a sparse list of "change points": a day where
-- the Common/Normal/Rare options change. Whatever the most recent change
-- point set stays in effect until the next one, so most of the work here is
-- walking forward through that sparse list from "now" and figuring out which
-- absolute day each entry actually falls on (accounting for the table
-- repeating every 2160 days).
--------------------------------------------------------------------------------------------------

local MAX_STEPS_PER_ZONE = CYCLE_LENGTH_DAYS * 2; -- safety bound: never search more than 2 full cycles
local MAX_ROWS = 30;                              -- hard cap on rows per lookup, regardless of default or override

-- Persisted per-character: how many entries a lookup shows when no per-command
-- override is given. Defaults to 3, changeable with "/w default <#>".
local default_settings = T{ default_days = 3 };
local config = settings.load(default_settings);
settings.register('settings', 'weatherchecker_settings_update', function (s)
    if (s ~= nil) then config = s; end
end);

local function clamp_row_count(n)
    n = math.floor(n);
    if (n < 1) then n = 1; end
    if (n > MAX_ROWS) then n = MAX_ROWS; end
    return n;
end

-- Does weather id `wid` satisfy `filter`? (see ALIAS_TO_FILTER above for the
-- filter format.) An empty slot (wid == 0) never matches anything.
local function weather_matches(wid, filter)
    if (wid == 0) then return false; end -- an empty slot never matches anything
    if (filter == 'all') then return true; end
    local kind, value = filter:match('^(%a+):(.+)$');
    if (kind == 'el') then
        local meta = WEATHER_META[wid];
        return meta ~= nil and meta.element == value;
    end
    return tostring(wid) == value; -- kind == 'id'
end

-- Core walk: returns up to `rowsCap` upcoming change-point rows for a given
-- name + changepoint table. Used directly by both find_zone_rows (a single,
-- specifically-named zone) and find_all_zones (one call per zone GROUP, see
-- ZONE_GROUPS above). If `weatherFilter` isn't 'all', only rows where the
-- filter matches at least one of the three slots are included -- but all
-- three slot values are still returned, so the caller can show full context
-- around the match.
local function find_rows_for(displayName, changePoints, weatherFilter, nowDay, rowsCap)
    local pointCount = #changePoints;
    if (pointCount == 0) then return {}; end

    local cycleNumber = math.floor(nowDay / CYCLE_LENGTH_DAYS);
    local dayInCycle = nowDay % CYCLE_LENGTH_DAYS;

    -- Find the change point currently in effect (the last one at or before today).
    local startIndex = 1;
    for i = 1, pointCount do
        if (changePoints[i][1] <= dayInCycle) then startIndex = i; end
    end

    local rows = {};
    local i = startIndex;
    local steps = 0;
    while (#rows < rowsCap and steps < MAX_STEPS_PER_ZONE) do
        local pointIndex = ((i - 1) % pointCount) + 1;
        local point = changePoints[pointIndex];
        local cycleOffset = math.floor((i - 1) / pointCount);
        local absoluteDay = ((cycleNumber + cycleOffset) * CYCLE_LENGTH_DAYS) + point[1];

        -- The very first entry (i == startIndex) is "whatever's in effect right
        -- now" -- if today isn't itself a change-point day, this entry's OWN day
        -- is in the past (it carried forward from an earlier change-point), but
        -- its effect is still active today. Display it as today, not its
        -- original day. Every later entry in the walk is a real future
        -- change-point, so this never affects anything past the first row.
        local displayDay = math.max(absoluteDay, nowDay);

        local normalW, commonW, rareW = point[2], point[3], point[4];
        local matchNormal = weather_matches(normalW, weatherFilter);
        local matchCommon = weather_matches(commonW, weatherFilter);
        local matchRare = weather_matches(rareW, weatherFilter);

        if (weatherFilter == 'all' or matchNormal or matchCommon or matchRare) then
            local nextPointIndex = ((i) % pointCount) + 1;
            local nextPoint = changePoints[nextPointIndex];
            local nextCycleOffset = math.floor(i / pointCount);
            local nextAbsoluteDay = ((cycleNumber + nextCycleOffset) * CYCLE_LENGTH_DAYS) + nextPoint[1];

            rows[#rows + 1] = {
                zoneName = displayName, startDay = displayDay, endDay = nextAbsoluteDay,
                normal = normalW, common = commonW, rare = rareW,
                matchNormal = matchNormal, matchCommon = matchCommon, matchRare = matchRare,
            };
        end
        i = i + 1;
        steps = steps + 1;
    end
    return rows;
end

-- A single, specifically-named zone (e.g. from "/w qufim ..."), ungrouped --
-- always shows that exact zone's own name even if others share its table.
local function find_zone_rows(zid, weatherFilter, nowDay, rowsCap)
    local zone = ZONES[zid];
    if (zone == nil) then return {}; end
    return find_rows_for(zone.name, zone.cps, weatherFilter, nowDay, rowsCap);
end

-- "/w <weather>" with no zone given: searches every zone GROUP (see
-- ZONE_GROUPS -- zones sharing an identical table are merged into one entry
-- so they don't spam the results with duplicate-looking rows for the same
-- moment), then flattens everything into a single list sorted soonest-first
-- and truncated to `totalCap` -- e.g. "/w fire 5" means the next 5 actual
-- occurrences, not 5 per zone.
local function find_all_zones(weatherFilter, nowDay, totalCap)
    local pool = {};
    for _, group in ipairs(ZONE_GROUPS) do
        local rows = find_rows_for(group.displayName, group.cps, weatherFilter, nowDay, totalCap);
        for _, r in ipairs(rows) do pool[#pool + 1] = r; end
    end
    table.sort(pool, function (a, b) return a.startDay < b.startDay; end);

    local results = {};
    for i = 1, math.min(totalCap, #pool) do
        results[i] = pool[i];
    end
    return results;
end

--------------------------------------------------------------------------------------------------
-- Output formatting
--------------------------------------------------------------------------------------------------

local function say(msg)
    print(chat.header(addon.name):append(chat.message(msg)));
end
local function say_err(msg)
    print(chat.header(addon.name):append(chat.error(msg)));
end
local function say_ok(msg)
    print(chat.header(addon.name):append(chat.success(msg)));
end

-- Elemental weather always renders in the dark-green "success" color so it
-- stands out at a glance; non-elemental "None" stays plain, since it's never
-- what anyone's actually hunting for.
local function weather_cell(wid)
    if (wid == 0) then return chat.message('--'); end
    local meta = WEATHER_META[wid];
    if (meta.element == 'none') then
        return chat.message(weather_label(wid));
    end
    return chat.success(weather_label(wid));
end

-- "Common/Normal/Rare" formatted as element names, e.g. "None/Water/Light".
-- Used both for the reminder messages and the reminder list.
local function weather_triple_label(r)
    return weather_label(r.common) .. '/' .. weather_label(r.normal) .. '/' .. weather_label(r.rare);
end

-- Prints one lookup result row, numbered "(idx)" so it can be referenced later
-- with "/w remind <idx>".
--
-- NOTE: this is built as ONE continuous chained expression, not split across
-- separate statements. Ashita's chat message objects are immutable builders
-- -- :append() returns a NEW combined object rather than mutating the
-- receiver -- so `line:append(x); line:append(y)` on separate statements
-- silently discards everything after the first append. (This was a real bug
-- during development: chat output showed only the header and dropped all the
-- weather data.)
local function print_row(r, idx)
    local year, month, dayOfMonth, weekday = day_to_calendar(r.startDay);
    local whenText;
    if (r.startDay <= get_weather_day()) then
        whenText = 'Today';
    else
        whenText = 'in ' .. format_hours(hours_until(r.startDay, get_weather_seconds()));
    end
    local header = string.format('(%d) %s -- %d/%d/%d (%s) -- %s  ',
        idx, r.zoneName, year, month, dayOfMonth, weekday, whenText);

    print(
        chat.header(addon.name)
            :append(chat.message(header .. 'Common: '))
            :append(weather_cell(r.common))
            :append(chat.message('  Normal: '))
            :append(weather_cell(r.normal))
            :append(chat.message('  Rare: '))
            :append(weather_cell(r.rare))
    );
end

--------------------------------------------------------------------------------------------------
-- Reminders
--
-- Each active reminder gets a single-digit id (1-9). Ids are reused: when a
-- reminder is cancelled or finishes counting down, its id becomes available
-- again for the next one you set. Up to 9 reminders can be tracked at once.
--------------------------------------------------------------------------------------------------

local MAX_REMINDERS = 9;
local WARNING_THRESHOLDS = { 60, 30, 5, 0 }; -- minutes-until, largest first

local lastLookup = nil; -- { rows = {...} } from the most recent lookup, for "/w remind <#>"
local reminders = {};   -- { {id, zoneName, common, normal, rare, targetDay, pending}, ... }

-- Returns the lowest id (1..MAX_REMINDERS) not currently in use, or nil if
-- every slot is taken.
local function allocate_reminder_id()
    local used = {};
    for _, rem in ipairs(reminders) do used[rem.id] = true; end
    for id = 1, MAX_REMINDERS do
        if (not used[id]) then return id; end
    end
    return nil;
end

-- Persists the currently active reminders so they survive a relog, addon
-- reload, or client restart. `pending` (which thresholds are left to fire)
-- is deliberately NOT saved -- it's recomputed fresh from targetDay whenever
-- reminders are restored, so it's always correct for whatever time has
-- actually passed, rather than trusting stale state from before.
local function save_reminders()
    local saved = {};
    for _, rem in ipairs(reminders) do
        saved[#saved + 1] = {
            id = rem.id, zoneName = rem.zoneName,
            common = rem.common, normal = rem.normal, rare = rem.rare,
            targetDay = rem.targetDay,
        };
    end
    config.reminders = saved;
    settings.save();
end

-- Fog (id 3) is NOT part of the zone_weather table at all -- per LSB's
-- src/map/zone.cpp, it's a runtime override applied AFTER the normal roll:
-- if the current Vana'diel time is 2:00-7:00 AM, the zone isn't a city, and
-- the roll came up None/Sunshine/Clouds, the server swaps it to Fog on the
-- spot. There's no scheduled day to find, so searching the table for it can
-- never return anything meaningful -- this message explains why instead of
-- just silently finding nothing.
local FOG_EXPLANATION =
    'Fog isnt schedule-based, so theres no day to predict for it. Per the server code, ' ..
    'it can occur in any non-city outdoor zone during Vanadiel 2:00-7:00 AM, whenever ' ..
    'the normal roll would have come up None/Sunshine/Clouds. Just be in the zone during ' ..
    'that window and hope for a clear early morning.';

-- Arms a reminder for `row` (one of the rows returned by find_zone_rows /
-- find_all_zones). Only queues warning thresholds still ahead of "now" -- if
-- armed with e.g. 45 minutes left, the 60-minute warning has already
-- effectively passed, so it's skipped rather than firing an inaccurate
-- "60 minutes until" a moment after being set.
local function arm_reminder(row)
    local minsUntil = minutes_until(row.startDay, get_weather_seconds());
    local triple = weather_triple_label(row);

    if (minsUntil <= 0) then
        say_ok(triple .. ' weather has already started in ' .. row.zoneName .. '.');
        return;
    end

    local id = allocate_reminder_id();
    if (id == nil) then
        say_err('Your reminder list is full (' .. MAX_REMINDERS .. '/' .. MAX_REMINDERS ..
                 ') -- cancel one first with /w cancel <#>.');
        return;
    end

    local pending = {};
    for _, threshold in ipairs(WARNING_THRESHOLDS) do
        if (threshold < minsUntil) then pending[#pending + 1] = threshold; end
    end

    reminders[#reminders + 1] = {
        id = id, zoneName = row.zoneName,
        common = row.common, normal = row.normal, rare = row.rare,
        targetDay = row.startDay, pending = pending,
    };
    save_reminders();
    say_ok(string.format('Reminder (%d) set: %s -- %s -- in %s',
        id, row.zoneName, triple, format_hours(minsUntil / 60)));
end

-- "/w remind" with no number -- shows every currently tracked reminder and
-- its time remaining, sorted by id so the list reads in a stable order.
local function list_reminders()
    if (#reminders == 0) then
        say('No active reminders.');
        return;
    end
    local sorted = {};
    for _, rem in ipairs(reminders) do sorted[#sorted + 1] = rem; end
    table.sort(sorted, function (a, b) return a.id < b.id; end);

    for _, rem in ipairs(sorted) do
        local timeLeft = format_hours(hours_until(rem.targetDay, get_weather_seconds()));
        say(string.format('(%d) %s -- %s -- in %s', rem.id, rem.zoneName, weather_triple_label(rem), timeLeft));
    end
end

local function cancel_reminder(idText)
    local id = tonumber(idText);
    if (id == nil) then
        say_err('Usage: /w cancel <#>  (see /w remind for the list)');
        return;
    end
    for i, rem in ipairs(reminders) do
        if (rem.id == id) then
            table.remove(reminders, i);
            save_reminders();
            say('Cancelled reminder (' .. id .. ').');
            return;
        end
    end
    say_err('No reminder (' .. id .. ') -- see /w remind for your current list.');
end

-- Runs once when the addon loads: brings back whatever reminders were active
-- last time, recomputed against the LIVE clock rather than trusting
-- whatever was true when they were saved. Anything that would have already
-- started while you were offline just gets announced immediately instead of
-- silently vanishing; everything else comes back with correctly-adjusted
-- warning thresholds (so you don't get a "60 minutes until" for something
-- that's actually 10 minutes out because time passed while you were away).
local function restore_reminders()
    if (config.reminders == nil or #config.reminders == 0) then return; end
    local nowSeconds = get_weather_seconds();
    local restoredCount = 0;

    for _, saved in ipairs(config.reminders) do
        local minsUntil = minutes_until(saved.targetDay, nowSeconds);
        if (minsUntil <= 0) then
            say_ok(weather_triple_label(saved) .. ' weather has already started in ' ..
                   saved.zoneName .. ' (while you were away).');
        else
            local pending = {};
            for _, threshold in ipairs(WARNING_THRESHOLDS) do
                if (threshold < minsUntil) then pending[#pending + 1] = threshold; end
            end
            reminders[#reminders + 1] = {
                id = saved.id, zoneName = saved.zoneName,
                common = saved.common, normal = saved.normal, rare = saved.rare,
                targetDay = saved.targetDay, pending = pending,
            };
            restoredCount = restoredCount + 1;
        end
    end

    if (restoredCount > 0) then
        say('Restored ' .. restoredCount .. ' reminder' .. (restoredCount == 1 and '' or 's') .. ' from your last session.');
    end
    save_reminders(); -- drop anything that already fired from the saved list, so it isn't re-announced next time
end
restore_reminders();

--------------------------------------------------------------------------------------------------
-- Command handling
--------------------------------------------------------------------------------------------------

-- Splits already-lowercased command tokens into a weather filter
-- ('all' | 'el:x' | 'id:n') and whatever's left over (rejoined with spaces)
-- to fuzzy-match as a zone name.
local function parse_args(tokens)
    local weatherFilter = nil;
    local zoneTokens = {};
    for _, token in ipairs(tokens) do
        local key = token:gsub('[^%a%d]', ''); -- strip punctuation but keep the tier digit, e.g. "earth2"
        if (weatherFilter == nil and ALIAS_TO_FILTER[key] ~= nil) then
            weatherFilter = ALIAS_TO_FILTER[key];
        else
            zoneTokens[#zoneTokens + 1] = token;
        end
    end
    return weatherFilter or 'all', table.concat(zoneTokens, ' ');
end

local function current_zone_name()
    local zid = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    local zone = ZONES[zid];
    if (zone == nil) then return nil; end
    return zone.name;
end

-- Runs a lookup and prints numbered rows, remembering the result so
-- "/w remind <#>" can reference it afterward.
local function handle_lookup(zoneQuery, weatherFilter, rowsCap)
    if (weatherFilter == 'id:3') then
        say(FOG_EXPLANATION);
        return;
    end

    local nowDay = get_weather_day();
    local rows;
    local header;

    if (zoneQuery == '') then
        -- No zone given -- search every zone (grouped/deduplicated) for the
        -- soonest matches, already flattened and capped to rowsCap total.
        rows = find_all_zones(weatherFilter, nowDay, rowsCap);
        if (#rows == 0) then
            say_err('No zones found with that weather in the searchable horizon.');
            return;
        end
        header = 'Soonest matches, across zones:';
    else
        local zid, zoneName = find_zone(zoneQuery);
        if (zid == nil) then
            say_err('Unknown zone: "' .. zoneQuery .. '"');
            return;
        end
        rows = find_zone_rows(zid, weatherFilter, nowDay, rowsCap);
        if (#rows == 0) then
            say_err('No matching weather found for ' .. zoneName .. ' in the searchable horizon.');
            return;
        end
        header = zoneName .. ' -- upcoming weather:';
    end

    say(header);
    for idx, r in ipairs(rows) do print_row(r, idx); end
    lastLookup = { rows = rows };
end

-- "/w remind" (no number) lists active reminders; "/w remind <#>" arms one
-- for the matching (#) row from the last lookup you displayed.
local function handle_remind(numberText)
    if (numberText == nil) then
        list_reminders();
        return;
    end
    if (lastLookup == nil or #lastLookup.rows == 0) then
        say_err('Nothing to remind about yet -- look something up first.');
        return;
    end
    local n = tonumber(numberText);
    if (n == nil or n ~= math.floor(n)) then
        say_err('Usage: /w remind <#>  (use the (#) shown on a lookup line)');
        return;
    end
    local row = lastLookup.rows[n];
    if (row == nil) then
        say_err('No entry (' .. numberText .. ') in your last lookup -- it only had ' .. #lastLookup.rows .. '.');
        return;
    end
    arm_reminder(row);
end

local function print_help()
    say_ok('WeatherChecker commands:');
    say('/w                    - current zones next ' .. config.default_days .. ' days of weather.');
    say('/w <zone>             - specified zones next ' .. config.default_days .. ' days of weather.');
    say('/w <zone> <weather>   - specified zones next ' .. config.default_days .. ' instances of a specified weather type.');
    say('/w <weather>          - soonest match for that weather, per zone, across all zones.');
    say('/w ... <#>            - add a number (1-' .. MAX_ROWS .. ') at the end of any lookup above to show');
    say('                        that many instead, e.g. "/w qufim 5".');
    say('/w default <#>        - set your default entry count (currently ' .. config.default_days .. ') for future lookups.');
    say('/w remind             - gives a time remaining on your currently set reminders.');
    say('/w remind <#>         - sets a reminder for the (#) row from the last lookup.');
    say('/w cancel <#>         - cancels the reminder for the (#) in your reminder list.');
    say('/w help               - displays this list.');
    say(' ');
    say('Zone names are fuzzy-matched, so partial names work (e.g. "qufim" for Qufim Island).');
    say('Weather is specified by element: light, fire, water, earth, wind, ice, thunder, dark');
    say('(matches both tiers of that element). For a specific tier only, add 1 or 2, e.g.');
    say('"earth2" for Sandstorm only, "fire1" for Hot Spell only. Non-elemental weather:');
    say('sunshine, clouds, fog. Note: fog isnt schedule-based -- see "/w fog" for why.');
    say(' ');
    say_ok('How the weather itself actually works:');
    say('Each zone has 3 possible weather types lined up for any given Vanadiel day: a Common');
    say('one (35% chance), a Normal one (50% chance), and a Rare one (15% chance). The server');
    say('re-rolls between those 3 options every 3-30 real-world minutes while youre in the zone --');
    say('so a listed window being active means that weather CAN show up, not that it definitely');
    say('will on any single roll. The longer a window stays open, the more independent rolls you');
    say('get at it.');
end

-- If the last token is a plain integer, pop it off and return it (clamped to
-- 1..MAX_ROWS) plus the remaining tokens -- lets any lookup end with a number
-- to override the default row count just for that command, e.g. "/w qufim 5".
local function pop_trailing_count(tokens)
    local n = #tokens;
    if (n == 0) then return nil, tokens; end
    local last = tokens[n];
    if (last:match('^%d+$') ~= nil) then
        local remaining = {};
        for i = 1, n - 1 do remaining[i] = tokens[i]; end
        return clamp_row_count(tonumber(last)), remaining;
    end
    return nil, tokens;
end

ashita.events.register('command', 'weatherchecker_command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/w')) then
        return;
    end
    e.blocked = true;

    -- Bare "/w" -- current zone, everything else uses the shared lookup path below.
    if (#args == 1) then
        local zoneName = current_zone_name();
        if (zoneName == nil) then
            say_err('No weather data for your current zone.');
            return;
        end
        handle_lookup(zoneName, 'all', config.default_days);
        return;
    end

    local rest = {};
    for i = 2, #args do rest[#rest + 1] = args[i]:lower(); end

    if (rest[1] == 'help') then print_help(); return; end
    if (rest[1] == 'remind') then handle_remind(rest[2]); return; end
    if (rest[1] == 'cancel') then cancel_reminder(rest[2]); return; end

    if (rest[1] == 'default') then
        if (rest[2] == nil) then
            say('Current default entry count: ' .. config.default_days);
            return;
        end
        local n = tonumber(rest[2]);
        if (n == nil) then
            say_err('Usage: /w default <#>  (1-' .. MAX_ROWS .. ')');
            return;
        end
        config.default_days = clamp_row_count(n);
        settings.save();
        say_ok('Default entry count set to ' .. config.default_days .. '.');
        return;
    end

    -- Anything else is a lookup: some combination of zone name and/or weather
    -- keyword, optionally ending in a number to override the row count just
    -- for this one command. parse_args sorts out which remaining tokens are
    -- which.
    local count, trimmed = pop_trailing_count(rest);
    local rowsCap = count or config.default_days;
    local weatherFilter, zoneQuery = parse_args(trimmed);
    handle_lookup(zoneQuery, weatherFilter, rowsCap);
end);

--------------------------------------------------------------------------------------------------
-- Reminder polling
--
-- Throttled to once every 5 real-world seconds -- checking every frame would
-- be wasteful, and this is plenty precise for minute-granularity warnings.
--------------------------------------------------------------------------------------------------

local lastPollTime = 0;
ashita.events.register('d3d_present', 'weatherchecker_present_cb', function ()
    -- os.time() is real wall-clock time; os.clock() measures CPU time instead
    -- and would badly delay this (a frame burns almost no CPU time, so a
    -- CPU-time-based throttle could take far longer than 5 seconds to trip).
    local now = os.time();
    if ((now - lastPollTime) < 5) then return; end
    lastPollTime = now;

    if (#reminders == 0) then return; end
    local nowSeconds = get_weather_seconds();
    local i = 1;
    while (i <= #reminders) do
        local rem = reminders[i];
        local minsUntil = minutes_until(rem.targetDay, nowSeconds);

        -- `pending` is largest-threshold-first. Loop (not just peek) so that
        -- if a poll gets delayed past more than one threshold at once, every
        -- warning still fires instead of silently skipping.
        while (#rem.pending > 0 and minsUntil <= rem.pending[1]) do
            local threshold = table.remove(rem.pending, 1);
            local triple = weather_triple_label(rem);
            if (threshold == 0) then
                say_ok(triple .. ' weather has started in ' .. rem.zoneName .. '.');
            else
                say_ok(threshold .. ' Minutes until ' .. triple .. ' weather in ' .. rem.zoneName .. '.');
            end
        end

        if (#rem.pending == 0) then
            table.remove(reminders, i); -- done -- frees its id for reuse
            save_reminders();
        else
            i = i + 1;
        end
    end
end);
