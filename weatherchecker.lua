--[[
* WeatherChecker - Ashita v4 addon
*
* Shows upcoming zone weather for LSB-based FFXI servers, and lets you set
* reminders that count down to a specific upcoming weather window.
*
* Vana'diel time reading is ported from clockvana.lua (atom0s, modified by
* Almavivaconte: https://github.com/ConteAlmaviva/clockvana), itself based on
* the Ashita v3 `vanatime` lib. Credit to atom0s / Almavivaconte for the
* memory signature and timestamp math 
*
* Weather table data is sourced from LandSandBoat's `base` branch
* (sql/zone_weather.sql + sql/zone_settings.sql), pre-decoded into
* data/weather_data.lua by gen_weather_data.py
--]]

addon.name    = 'weatherchecker';
addon.author  = 'Monti';
addon.version = '1.0';
addon.desc    = 'Weather look-up and reminders for LSB-based servers.';
addon.link    = '';

require('common');
local chat = require('chat');

--------------------------------------------------------------------------------------------------
-- Vana'diel time
--
-- The game client keeps its own Vana'diel clock in memory. Reading it directly
-- which means this addon is always exactly in sync with the server, with no risk of
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

-- Current absolute Vana'diel day count (a day is 86400 vana-seconds).
local function get_vana_day()
    return math.floor(get_vana_seconds() / 86400);
end

local CYCLE_LENGTH_DAYS = 2160; -- the zone weather tables repeat on this cycle
local DAYTYPE_NAMES = { 'Firesday', 'Earthsday', 'Watersday', 'Windsday', 'Iceday', 'Lightningday', 'Lightsday', 'Darksday' };

-- Converts an absolute Vana'diel day into a calendar date, matching what
-- /clock shows in-game: 12 months of 30 days, 360-day years, epoch year 886.
-- (Lua's % is floor-mod, so this works correctly for any sign of `day`.)
local function day_to_calendar(day)
    local dayOfYear = day % 360;
    local year = 886 + math.floor(day / 360);
    local month = math.floor(dayOfYear / 30) + 1;
    local dayOfMonth = (dayOfYear % 30) + 1;
    local weekday = DAYTYPE_NAMES[(day % 8) + 1];
    return year, month, dayOfMonth, weekday;
end

-- Real-world hours remaining until a target Vana'diel day boundary, computed
-- directly against the live vana-seconds clock.
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
local MAX_ZONES_SHOWN = 10;                       -- cap for "all zones" searches, so results stay readable
local ROWS_PER_LOOKUP = 3;                        -- fixed number of upcoming entries any lookup shows

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

-- Returns up to `rowsCap` upcoming change-point rows for a single zone. If
-- `weatherFilter` isn't 'all', only rows where the filter matches at least
-- one of the three slots are included -- but all three slot values are still
-- returned, so the caller can show full context around the match.
local function find_zone_rows(zid, weatherFilter, nowDay, rowsCap)
    local zone = ZONES[zid];
    if (zone == nil or #zone.cps == 0) then return {}; end
    local changePoints = zone.cps;
    local pointCount = #changePoints;

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

        if (absoluteDay >= nowDay) then
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
                    zoneName = zone.name, startDay = absoluteDay, endDay = nextAbsoluteDay,
                    normal = normalW, common = commonW, rare = rareW,
                    matchNormal = matchNormal, matchCommon = matchCommon, matchRare = matchRare,
                };
            end
        end
        i = i + 1;
        steps = steps + 1;
    end
    return rows;
end

-- Searches every zone for matches, sorted so the soonest-occurring zone comes
-- first, capped to MAX_ZONES_SHOWN zones so a common weather type doesn't
-- flood the chat log.
local function find_all_zones(weatherFilter, nowDay, rowsPerZone)
    local candidates = {};
    for zid, _ in pairs(ZONES) do
        local rows = find_zone_rows(zid, weatherFilter, nowDay, rowsPerZone);
        if (#rows > 0) then
            candidates[#candidates + 1] = { zid = zid, rows = rows };
        end
    end
    table.sort(candidates, function (a, b) return a.rows[1].startDay < b.rows[1].startDay; end);

    local results = {};
    for i = 1, math.min(MAX_ZONES_SHOWN, #candidates) do
        results[i] = candidates[i];
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

-- Elemental weather always renders in the highlighted color so it
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
local function print_row(r, idx)
    local year, month, dayOfMonth, weekday = day_to_calendar(r.startDay);
    local whenText;
    if (r.startDay <= get_vana_day()) then
        whenText = 'Today';
    else
        whenText = 'in ' .. format_hours(hours_until(r.startDay, get_vana_seconds()));
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
    local minsUntil = minutes_until(row.startDay, get_vana_seconds());
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
        local timeLeft = format_hours(hours_until(rem.targetDay, get_vana_seconds()));
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
            say('Cancelled reminder (' .. id .. ').');
            return;
        end
    end
    say_err('No reminder (' .. id .. ') -- see /w remind for your current list.');
end

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
local function handle_lookup(zoneQuery, weatherFilter)
    if (weatherFilter == 'id:3') then
        say(FOG_EXPLANATION);
        return;
    end

    local nowDay = get_vana_day();
    local rows;
    local header;

    if (zoneQuery == '') then
        -- No zone given -- search every zone for the soonest matches.
        local groups = find_all_zones(weatherFilter, nowDay, ROWS_PER_LOOKUP);
        if (#groups == 0) then
            say_err('No zones found with that weather in the searchable horizon.');
            return;
        end
        rows = {};
        for _, group in ipairs(groups) do
            for _, r in ipairs(group.rows) do rows[#rows + 1] = r; end
        end
        header = 'Soonest matches, across zones:';
    else
        local zid, zoneName = find_zone(zoneQuery);
        if (zid == nil) then
            say_err('Unknown zone: "' .. zoneQuery .. '"');
            return;
        end
        rows = find_zone_rows(zid, weatherFilter, nowDay, ROWS_PER_LOOKUP);
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
    say('/w                    - current zones next 3 days of weather.');
    say('/w <zone>             - specified zones next 3 days of weather.');
    say('/w <zone> <weather>   - specified zones next 3 instances of a specified weather type.');
    say('/w <weather>          - soonest match for that weather, per zone, across all zones.');
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
    say('re-rolls between those 3 options every 3-30 real-world minutes');
    say('so a listed window being active means that weather CAN show up, not that it definitely');
    say('will on any single day.');
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
        handle_lookup(zoneName, 'all');
        return;
    end

    local rest = {};
    for i = 2, #args do rest[#rest + 1] = args[i]:lower(); end

    if (rest[1] == 'help') then print_help(); return; end
    if (rest[1] == 'remind') then handle_remind(rest[2]); return; end
    if (rest[1] == 'cancel') then cancel_reminder(rest[2]); return; end

    -- Anything else is a lookup: some combination of zone name and/or weather
    -- keyword. parse_args sorts out which tokens are which.
    local weatherFilter, zoneQuery = parse_args(rest);
    handle_lookup(zoneQuery, weatherFilter);
end);

--------------------------------------------------------------------------------------------------
-- Reminder polling
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
    local nowSeconds = get_vana_seconds();
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
        else
            i = i + 1;
        end
    end
end);
