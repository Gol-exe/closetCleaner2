_addon.name = 'closetCleaner2'
_addon.version = '2.1'
_addon.author = 'Gol-Exe'
_addon.commands = {'cc', 'closetCleaner2'}

require 'strings'
require 'tables'
require 'logger'
error = _raw.error
res = require 'resources'

local parser = require 'luaParser'

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function normalize_slashes(p)
    return p:gsub('\\', '/'):gsub('/+', '/')
end

local function ensure_trailing_slash(p)
    if p:sub(-1) ~= '/' then p = p .. '/' end
    return p
end

local function file_exists(path)
    return windower.file_exists(path)
end

local function ucfirst(s)
    return s:sub(1,1):upper() .. s:sub(2):lower()
end

local ALL_JOBS = {
    'BLM','BLU','BRD','BST','COR','DNC','DRG','DRK','GEO','MNK','NIN',
    'PLD','PUP','RDM','RNG','RUN','SAM','SCH','SMN','THF','WAR','WHM',
}

----------------------------------------------------------------------
-- XML settings (data/settings.xml)
----------------------------------------------------------------------

local function xml_escape(s)
    return s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
end

local function xml_unescape(s)
    return s:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&apos;', "'")
             :gsub('&quot;', '"'):gsub('&amp;', '&')
end

local function xml_escape_attr(s)
    return s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;')
end

local function settings_path()
    return windower.addon_path .. 'data/settings.xml'
end

local function serialize_settings(cfg)
    local lines = {}
    lines[#lines + 1] = '<?xml version="1.0" encoding="UTF-8"?>'
    lines[#lines + 1] = '<settings>'
    lines[#lines + 1] = '    <global>'

    lines[#lines + 1] = '        <skip_bags>'
    for _, bag in ipairs(cfg.global.skip_bags or {}) do
        lines[#lines + 1] = '            <bag>' .. xml_escape(bag) .. '</bag>'
    end
    lines[#lines + 1] = '        </skip_bags>'

    local muc = cfg.global.max_use_count
    lines[#lines + 1] = '        <max_use_count>' .. (muc and tostring(muc) or '') .. '</max_use_count>'
    lines[#lines + 1] = '        <debug>' .. tostring(cfg.global.debug or false) .. '</debug>'
    lines[#lines + 1] = '        <report_mode>' .. xml_escape(cfg.global.report_mode or 'default') .. '</report_mode>'

    lines[#lines + 1] = '        <ignore_patterns>'
    for _, pat in ipairs(cfg.global.ignore_patterns or {}) do
        lines[#lines + 1] = '            <pattern>' .. xml_escape(pat) .. '</pattern>'
    end
    lines[#lines + 1] = '        </ignore_patterns>'

    lines[#lines + 1] = '        <file_patterns>'
    for _, pat in ipairs(cfg.global.file_patterns or {}) do
        lines[#lines + 1] = '            <pattern>' .. xml_escape(pat) .. '</pattern>'
    end
    lines[#lines + 1] = '        </file_patterns>'

    lines[#lines + 1] = '    </global>'
    lines[#lines + 1] = '    <characters>'

    local char_names = {}
    for name in pairs(cfg.characters or {}) do
        char_names[#char_names + 1] = name
    end
    table.sort(char_names)

    for _, name in ipairs(char_names) do
        local jobs = cfg.characters[name]
        lines[#lines + 1] = '        <character name="' .. xml_escape_attr(name) .. '">'
        for _, job in ipairs(jobs) do
            lines[#lines + 1] = '            <job>' .. xml_escape(job) .. '</job>'
        end
        lines[#lines + 1] = '        </character>'
    end

    lines[#lines + 1] = '    </characters>'
    lines[#lines + 1] = '</settings>'
    return table.concat(lines, '\n') .. '\n'
end

local function parse_settings(text)
    local cfg = { global = {}, characters = {} }

    local global_block = text:match('<global>(.-)</global>')
    if global_block then
        local bags_block = global_block:match('<skip_bags>(.-)</skip_bags>')
        if bags_block then
            local skip_bags = {}
            for bag in bags_block:gmatch('<bag>(.-)</bag>') do
                skip_bags[#skip_bags + 1] = xml_unescape(bag)
            end
            cfg.global.skip_bags = skip_bags
        end

        local muc = global_block:match('<max_use_count>(.-)</max_use_count>')
        if muc then
            cfg.global.max_use_count = tonumber(muc:match('^%s*(.-)%s*$'))
        end

        local dbg = global_block:match('<debug>(.-)</debug>')
        if dbg then
            cfg.global.debug = dbg:match('^%s*(.-)%s*$') == 'true'
        end

        local rm = global_block:match('<report_mode>(.-)</report_mode>')
        if rm then
            local mode = xml_unescape(rm:match('^%s*(.-)%s*$')):lower()
            if mode == 'csv' then
                cfg.global.report_mode = 'csv'
            else
                cfg.global.report_mode = 'default'
            end
        end

        local patterns_block = global_block:match('<ignore_patterns>(.-)</ignore_patterns>')
        if patterns_block then
            local patterns = {}
            for pat in patterns_block:gmatch('<pattern>(.-)</pattern>') do
                patterns[#patterns + 1] = xml_unescape(pat)
            end
            cfg.global.ignore_patterns = patterns
        end

        local fp_block = global_block:match('<file_patterns>(.-)</file_patterns>')
        if fp_block then
            local fp = {}
            for pat in fp_block:gmatch('<pattern>(.-)</pattern>') do
                fp[#fp + 1] = xml_unescape(pat)
            end
            cfg.global.file_patterns = fp
        end
    end

    local chars_block = text:match('<characters>(.-)</characters>')
    if chars_block then
        for attr, char_body in chars_block:gmatch('<character%s+name="([^"]+)">(.-)</character>') do
            local jobs = {}
            for job in char_body:gmatch('<job>(.-)</job>') do
                jobs[#jobs + 1] = xml_unescape(job):upper()
            end
            cfg.characters[xml_unescape(attr)] = jobs
        end
    end

    return cfg
end

local function save_settings(cfg)
    local dir = windower.addon_path .. 'data'
    if not windower.dir_exists(dir) then
        windower.create_dir(dir)
    end
    local f = io.open(settings_path(), 'w')
    if not f then
        windower.add_to_chat(123, 'closetCleaner2: could not write ' .. settings_path())
        return false
    end
    f:write(serialize_settings(cfg))
    f:close()
    return true
end

local function load_settings()
    local f = io.open(settings_path(), 'r')
    if not f then
        windower.add_to_chat(123, 'closetCleaner2: data/settings.xml not found. '
            .. 'Copy the default from the addon folder or reload the addon.')
        return nil
    end
    local text = f:read('*a')
    f:close()
    return parse_settings(text)
end

local function get_character_jobs(cfg, char_name)
    if not cfg or not cfg.characters then return nil end
    return cfg.characters[char_name]
end

local function add_character_jobs(cfg, char_name, jobs)
    if not cfg.characters then cfg.characters = {} end
    if not cfg.characters[char_name] then
        cfg.characters[char_name] = {}
    end

    local existing = {}
    for _, j in ipairs(cfg.characters[char_name]) do
        existing[j] = true
    end

    local added = {}
    for _, j in ipairs(jobs) do
        local upper = j:upper()
        if not existing[upper] then
            existing[upper] = true
            cfg.characters[char_name][#cfg.characters[char_name] + 1] = upper
            added[#added + 1] = upper
        end
    end

    table.sort(cfg.characters[char_name])
    save_settings(cfg)
    return added
end

local function remove_character_jobs(cfg, char_name, jobs)
    if not cfg.characters or not cfg.characters[char_name] then
        return {}
    end

    local to_remove = {}
    for _, j in ipairs(jobs) do
        to_remove[j:upper()] = true
    end

    local removed = {}
    local kept = {}
    for _, j in ipairs(cfg.characters[char_name]) do
        if to_remove[j] then
            removed[#removed + 1] = j
        else
            kept[#kept + 1] = j
        end
    end

    cfg.characters[char_name] = kept
    save_settings(cfg)
    return removed
end

----------------------------------------------------------------------
-- Equipment check
----------------------------------------------------------------------

local function is_equippable(item_entry)
    if not item_entry or not item_entry.slots then
        return false
    end
    if type(item_entry.slots) == 'table' then
        return next(item_entry.slots) ~= nil
    end
    return item_entry.slots ~= 0
end

local function get_equippable_jobs_str(entry)
    if not entry or not entry.jobs or type(entry.jobs) ~= 'table' then
        return ''
    end
    local abbrs = {}
    for job_id in pairs(entry.jobs) do
        local job_res = res.jobs[job_id]
        if job_res and job_res.ens then
            abbrs[#abbrs + 1] = job_res.ens
        end
    end
    if #abbrs == 0 then return '' end
    if #abbrs >= 22 then return 'All Jobs' end
    table.sort(abbrs)
    return table.concat(abbrs, ',')
end

----------------------------------------------------------------------
-- Resource index  (built once, reused across reports)
-- Maps each lowered name to an array of item IDs so that multi-stage
-- items (same name, different IDs) all resolve correctly.
-- Only equippable items are indexed.
----------------------------------------------------------------------

local items_by_name     -- res short name (lower) -> {id, ...}
local items_by_longname -- res long name  (lower) -> {id, ...}

local function build_resource_index()
    if items_by_name then return end
    items_by_name = {}
    items_by_longname = {}
    for id, entry in pairs(res.items) do
        if is_equippable(entry) then
            if entry.en then
                local key = entry.en:lower()
                if not items_by_name[key] then
                    items_by_name[key] = {}
                end
                items_by_name[key][#items_by_name[key] + 1] = id
            end
            if entry.enl then
                local key = entry.enl:lower()
                if not items_by_longname[key] then
                    items_by_longname[key] = {}
                end
                items_by_longname[key][#items_by_longname[key] + 1] = id
            end
        end
    end
end

local function resolve_item_ids(name_lower)
    return items_by_name[name_lower] or items_by_longname[name_lower]
end

----------------------------------------------------------------------
-- Closest-match suggestion for misspelled item names
----------------------------------------------------------------------

local function levenshtein(a, b)
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    -- Cap at short strings to avoid huge allocations on very long names
    if la > 60 or lb > 60 then return math.abs(la - lb) end
    local prev, curr = {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        curr[0] = i
        for j = 1, lb do
            local cost = (a:sub(i,i) == b:sub(j,j)) and 0 or 1
            curr[j] = math.min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
        end
        prev, curr = curr, prev
    end
    return prev[lb]
end

local function find_closest_item(name_lower, max_distance)
    max_distance = max_distance or 3
    local best_name, best_dist = nil, max_distance + 1
    for known_name in pairs(items_by_name) do
        local dist = levenshtein(name_lower, known_name)
        if dist < best_dist then
            best_dist = dist
            best_name = known_name
        end
        if dist == 1 then break end
    end
    if best_dist <= max_distance then
        local ids = items_by_name[best_name]
        local entry = ids and ids[1] and res.items[ids[1]]
        if entry then return entry.en, best_dist end
    end
    return nil
end

----------------------------------------------------------------------
-- GearSwap data path resolution
----------------------------------------------------------------------

-- Base file patterns for locating job lua files.  Placeholders:
--   {name} = character name,  {job} = job abbreviation (e.g. BLM)
-- Paths are relative to the GearSwap data/ directory.
local BASE_FILE_PATTERNS = {
    '{name}_{job}_Gear.lua',
    '{name}_{job}_gear.lua',
    '{name}_{job}_items.lua',
    '{name}_{job}.lua',
    '{name}_items.lua',
    '{name}/{name}_{job}_Gear.lua',
    '{name}/{name}_{job}_gear.lua',
    '{name}/{name}_{job}_items.lua',
    '{name}/{name}_{job}.lua',
    '{name}/{name}_items.lua',
    '{job}_Gear.lua',
    '{job}_gear.lua',
    '{job}_items.lua',
    '{job}.lua',
}

local function gearswap_base_path()
    local addon = ensure_trailing_slash(normalize_slashes(windower.addon_path))
    local parent = addon:match('^(.*/).-/$') or addon
    local variants = { 'GearSwap/', 'gearswap/', 'Gearswap/', 'GEARSWAP/' }
    for _, name in ipairs(variants) do
        local path = parent .. name
        if windower.dir_exists(path) then
            return ensure_trailing_slash(path)
        end
    end
    return ensure_trailing_slash(parent .. 'GearSwap/')
end

local function build_search_dirs(gs_path, char_name)
    local dirs = {}
    local data = gs_path .. 'data/'
    local name = char_name or windower.ffxi.get_player().name
    dirs[#dirs + 1] = ensure_trailing_slash(data .. name)
    dirs[#dirs + 1] = ensure_trailing_slash(data .. 'common')
    dirs[#dirs + 1] = data
    dirs[#dirs + 1] = ensure_trailing_slash(gs_path .. 'libs-dev')
    dirs[#dirs + 1] = ensure_trailing_slash(gs_path .. 'libs')
    dirs[#dirs + 1] = ensure_trailing_slash(normalize_slashes(windower.addon_path) .. 'libs')

    local appdata = os.getenv('APPDATA')
    if appdata then
        local gs_appdata = ensure_trailing_slash(normalize_slashes(appdata) .. '/Windower/GearSwap/')
        dirs[#dirs + 1] = ensure_trailing_slash(gs_appdata .. name)
        dirs[#dirs + 1] = ensure_trailing_slash(gs_appdata .. 'common')
        dirs[#dirs + 1] = gs_appdata
    end

    dirs[#dirs + 1] = ensure_trailing_slash(normalize_slashes(windower.windower_path) .. 'addons/libs')
    return dirs
end

local function expand_file_pattern(pattern, name, job)
    return (pattern:gsub('{name}', name):gsub('{job}', job))
end

local function resolve_job_lua(gs_path, job, char_name, extra_patterns)
    local data = ensure_trailing_slash(gs_path .. 'data/')
    local name = char_name or windower.ffxi.get_player().name

    local all_patterns = {}
    for _, p in ipairs(BASE_FILE_PATTERNS) do
        all_patterns[#all_patterns + 1] = p
    end
    for _, p in ipairs(extra_patterns or {}) do
        all_patterns[#all_patterns + 1] = p
    end

    for _, pattern in ipairs(all_patterns) do
        local path = data .. expand_file_pattern(pattern, name, job)
        if file_exists(path) then return path end
    end
    return nil
end

----------------------------------------------------------------------
-- Inventory reading
----------------------------------------------------------------------

local function read_inventory(skip_bags_set)
    local inv = {}          -- id -> { bags = {bag1, bag2, ...} }
    local all_items = windower.ffxi.get_items()
    for bag_id, bag_info in pairs(res.bags) do
        local bag_name = bag_info.english
        if not skip_bags_set[bag_name] then
            local bag_key = bag_name:gsub(' ', ''):lower()
            local bag_data = all_items[bag_key]
            if bag_data then
                for _, slot in ipairs(bag_data) do
                    if type(slot) == 'table' and slot.id and slot.id ~= 0 then
                        local item_entry = res.items[slot.id]
                        if item_entry then
                            if not inv[slot.id] then
                                inv[slot.id] = { bags = {} }
                            end
                            local bags = inv[slot.id].bags
                            local already = false
                            for _, b in ipairs(bags) do
                                if b == bag_name then already = true; break end
                            end
                            if not already then
                                bags[#bags + 1] = bag_name
                            end
                        end
                    end
                end
            end
        end
    end
    return inv
end

----------------------------------------------------------------------
-- Ignore-pattern matching
----------------------------------------------------------------------

local function is_ignored(name, patterns)
    for _, pat in ipairs(patterns) do
        local ok, matched = pcall(string.match, name, pat)
        if ok and matched then
            return true
        end
    end
    return false
end

----------------------------------------------------------------------
-- Report writing
----------------------------------------------------------------------

local NAME_W  = 30
local JOBS_W  = 40
local LOC_W   = 24

local function pad(s, w)
    if #s >= w then return s end
    return s .. string.rep(' ', w - #s)
end

local function write_divider(f, widths)
    local parts = {}
    for i, w in ipairs(widths) do
        parts[i] = string.rep('-', w)
    end
    f:write('  ' .. table.concat(parts, '-+-') .. '\n')
end

local function write_row(f, cols, widths)
    local parts = {}
    for i, w in ipairs(widths) do
        parts[i] = pad(cols[i] or '', w)
    end
    f:write('  ' .. table.concat(parts, ' | ') .. '\n')
end

local function sorted_keys_alpha(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

local function run_report(cfg, char_name)
    build_resource_index()

    local player_name = char_name or windower.ffxi.get_player().name
    local gs_path = gearswap_base_path()
    local search_dirs = build_search_dirs(gs_path, player_name)

    -- Build skip-bags lookup
    local skip_bags_set = {}
    for _, b in ipairs(cfg.skip_bags or {}) do
        skip_bags_set[b] = true
    end

    ----------------------------------------------------------------
    -- Phase 1: Read inventory
    ----------------------------------------------------------------
    windower.add_to_chat(207, 'closetCleaner2: reading inventory...')
    local inventory = read_inventory(skip_bags_set)

    ----------------------------------------------------------------
    -- Phase 2: Parse gear from lua files
    ----------------------------------------------------------------
    windower.add_to_chat(207, 'closetCleaner2: parsing lua files...')

    -- gear_items[item_id] = { jobs = {JOB=true, ...} }
    local gear_items = {}
    -- unresolved[name_lower] = { original = first_seen_casing, jobs = {JOB=true, ...} }
    local unresolved = {}

    for _, job in ipairs(cfg.jobs) do
        local lua_path = resolve_job_lua(gs_path, job, player_name, cfg.file_patterns)
        if not lua_path then
            windower.add_to_chat(8, 'closetCleaner2: no lua file found for ' .. job)
        else
            windower.add_to_chat(207, 'closetCleaner2: parsing ' .. job)
            local ok, names = pcall(parser.parse_file_recursive, lua_path, search_dirs)
            if not ok then
                windower.add_to_chat(123, 'closetCleaner2: error parsing ' .. job .. ': ' .. tostring(names))
            else
                for name_lower in pairs(names) do
                    local ids = resolve_item_ids(name_lower)
                    if ids then
                        for _, id in ipairs(ids) do
                            if not gear_items[id] then
                                gear_items[id] = { jobs = {} }
                            end
                            gear_items[id].jobs[job] = true
                        end
                    else
                        if not unresolved[name_lower] then
                            unresolved[name_lower] = { original = name_lower, jobs = {} }
                        end
                        unresolved[name_lower].jobs[job] = true
                    end
                end
            end
        end
    end

    ----------------------------------------------------------------
    -- Phase 3: Build report sections
    ----------------------------------------------------------------
    local ignore_patterns = cfg.ignore_patterns or {}

    -- Section 1: UNUSED  (in inventory, not in any lua)
    local unused = {}   -- { {id=, name=, loc=}, ... }
    -- Section 2: IN USE  (in lua, also in inventory)
    local in_use = {}   -- { {id=, name=, jobs_str=, job_count=, loc=}, ... }
    -- Section 3: MISSING (in lua, not in inventory)
    local missing = {}  -- { {id=, name=, jobs_str=}, ... }

    -- Classify inventory items
    for id, inv_info in pairs(inventory) do
        local entry = res.items[id]
        if entry then
            local name = entry.en
            if not is_ignored(name, ignore_patterns) then
                local loc = table.concat(inv_info.bags, ', ')
                if gear_items[id] then
                    local job_list = sorted_keys_alpha(gear_items[id].jobs)
                    local job_count = #job_list
                    if not cfg.max_use_count or job_count <= cfg.max_use_count then
                        in_use[#in_use + 1] = {
                            id = id, name = name,
                            jobs_str = table.concat(job_list, ','),
                            job_count = job_count, loc = loc,
                            equip_jobs = get_equippable_jobs_str(entry),
                        }
                    end
                elseif is_equippable(entry) then
                    unused[#unused + 1] = {
                        id = id, name = name, loc = loc,
                        equip_jobs = get_equippable_jobs_str(entry),
                    }
                end
            end
        end
    end

    -- Classify lua-only items (not in inventory).
    -- Multi-stage items share a name across several IDs; skip an ID if
    -- any sibling ID for the same name IS in inventory, and deduplicate
    -- so each name appears at most once in the missing list.
    local seen_missing = {}
    for id, info in pairs(gear_items) do
        if not inventory[id] then
            local entry = res.items[id]
            if entry then
                local name = entry.en
                local name_lower = name:lower()
                if not seen_missing[name_lower] then
                    local sibling_in_inv = false
                    local all_ids = items_by_name[name_lower] or items_by_longname[name_lower]
                    if all_ids then
                        for _, alt_id in ipairs(all_ids) do
                            if inventory[alt_id] then
                                sibling_in_inv = true
                                break
                            end
                        end
                    end
                    if not sibling_in_inv and not is_ignored(name, ignore_patterns) then
                        local job_list = sorted_keys_alpha(info.jobs)
                        if not cfg.max_use_count or #job_list <= cfg.max_use_count then
                            missing[#missing + 1] = {
                                id = id, name = name,
                                jobs_str = table.concat(job_list, ','),
                            }
                        end
                    end
                    seen_missing[name_lower] = true
                end
            end
        end
    end

    -- Sort sections
    table.sort(unused, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(in_use, function(a, b)
        if a.job_count ~= b.job_count then return a.job_count > b.job_count end
        return a.name:lower() < b.name:lower()
    end)
    table.sort(missing, function(a, b) return a.name:lower() < b.name:lower() end)

    ----------------------------------------------------------------
    -- Phase 4: Build misspelled list and write report file
    ----------------------------------------------------------------
    local misspelled = {}
    for name_lower, info in pairs(unresolved) do
        local suggestion = find_closest_item(name_lower)
        local job_list = sorted_keys_alpha(info.jobs)
        misspelled[#misspelled + 1] = {
            name = name_lower,
            jobs_str = table.concat(job_list, ','),
            suggestion = suggestion,
        }
    end
    table.sort(misspelled, function(a, b) return a.name < b.name end)

    if not windower.dir_exists(windower.addon_path .. 'report') then
        windower.create_dir(windower.addon_path .. 'report')
    end

    local report_mode = cfg.report_mode or 'default'

    if report_mode == 'csv' then
        local report_path = windower.addon_path .. 'report/' .. player_name .. '_report.csv'
        local f = io.open(report_path, 'w+')
        if not f then
            windower.add_to_chat(123, 'closetCleaner2: could not open report file for writing')
            return
        end

        local function csv_escape(val)
            val = val or ''
            if val:find('[,"\n]') then
                return '"' .. val:gsub('"', '""') .. '"'
            end
            return val
        end

        local function csv_row(fields)
            local escaped = {}
            for i, v in ipairs(fields) do
                escaped[i] = csv_escape(v)
            end
            f:write(table.concat(escaped, ',') .. '\n')
        end

        csv_row({'Section', 'Name', 'Jobs', 'Location', 'Suggestion', 'Equip Jobs'})

        for _, item in ipairs(unused) do
            csv_row({'Unused', item.name, '', item.loc, '', item.equip_jobs or ''})
        end
        for _, item in ipairs(in_use) do
            csv_row({'In Use', item.name, item.jobs_str, item.loc, '', item.equip_jobs or ''})
        end
        for _, item in ipairs(missing) do
            csv_row({'Missing', item.name, item.jobs_str, '', '', ''})
        end
        for _, item in ipairs(misspelled) do
            csv_row({'Misspelled', item.name, item.jobs_str, '', item.suggestion or '', ''})
        end

        f:close()
        windower.add_to_chat(207, 'closetCleaner2: report saved to ' .. report_path)
    else
        local report_path = windower.addon_path .. 'report/' .. player_name .. '_report.txt'
        local f = io.open(report_path, 'w+')
        if not f then
            windower.add_to_chat(123, 'closetCleaner2: could not open report file for writing')
            return
        end

        local banner = string.rep('=', NAME_W + JOBS_W + LOC_W + 12)
        f:write(banner .. '\n')
        f:write('  ClosetCleaner2 Report  --  ' .. player_name .. '  --  ' .. os.date('%Y-%m-%d %H:%M') .. '\n')
        f:write(banner .. '\n\n')

        -- Section 1
        f:write('Section 1: UNUSED GEAR (in inventory, not in any lua file)   [' .. #unused .. ' items]\n')
        local w2 = {NAME_W, LOC_W}
        write_divider(f, w2)
        write_row(f, {'Name', 'Location'}, w2)
        write_divider(f, w2)
        if #unused == 0 then
            f:write('  (none)\n')
        else
            for _, item in ipairs(unused) do
                write_row(f, {item.name, item.loc}, w2)
            end
        end
        f:write('\n')

        -- Section 2
        f:write('Section 2: GEAR IN USE (sorted by job count descending)   [' .. #in_use .. ' items]\n')
        local w3 = {NAME_W, JOBS_W, LOC_W}
        write_divider(f, w3)
        write_row(f, {'Name', 'Jobs', 'Location'}, w3)
        write_divider(f, w3)
        if #in_use == 0 then
            f:write('  (none)\n')
        else
            for _, item in ipairs(in_use) do
                write_row(f, {item.name, item.jobs_str, item.loc}, w3)
            end
        end
        f:write('\n')

        -- Section 3
        f:write('Section 3: MISSING GEAR (in lua files, not in inventory, items stored on slips will also be marked as missing)   [' .. #missing .. ' items]\n')
        local w2m = {NAME_W, JOBS_W}
        write_divider(f, w2m)
        write_row(f, {'Name', 'Jobs'}, w2m)
        write_divider(f, w2m)
        if #missing == 0 then
            f:write('  (none)\n')
        else
            for _, item in ipairs(missing) do
                write_row(f, {item.name, item.jobs_str}, w2m)
            end
        end
        f:write('\n')

        -- Section 4
        f:write('Section 4: POSSIBLE MISSPELLINGS (in lua files, not found in resources)   [' .. #misspelled .. ' items]\n')
        local SUGGEST_W = 30
        local w4 = {NAME_W, JOBS_W, SUGGEST_W}
        write_divider(f, w4)
        write_row(f, {'Name (as written)', 'Jobs', 'Did you mean?'}, w4)
        write_divider(f, w4)
        if #misspelled == 0 then
            f:write('  (none)\n')
        else
            for _, item in ipairs(misspelled) do
                write_row(f, {item.name, item.jobs_str, item.suggestion or '(no match found)'}, w4)
            end
        end
        f:write('\n')

        -- Summary
        f:write(banner .. '\n')
        f:write('  Totals:  ' .. #unused .. ' unused  |  ' .. #in_use .. ' in use  |  ' .. #missing .. ' missing  |  ' .. #misspelled .. ' misspelled\n')
        f:write(banner .. '\n')

        f:close()
        windower.add_to_chat(207, 'closetCleaner2: report saved to ' .. report_path)
    end

    ----------------------------------------------------------------
    -- Optional debug files
    ----------------------------------------------------------------
    if cfg.debug then
        local dbg_inv_path = windower.addon_path .. 'report/' .. player_name .. '_inventory.txt'
        local fi = io.open(dbg_inv_path, 'w+')
        if fi then
            fi:write('closetCleaner2 Inventory Debug:\n')
            fi:write(string.rep('=', 60) .. '\n\n')
            for id, inv_info in pairs(inventory) do
                local entry = res.items[id]
                local name = entry and entry.en or ('ID:' .. tostring(id))
                fi:write(name .. '  ->  ' .. table.concat(inv_info.bags, ', ') .. '\n')
            end
            fi:close()
            windower.add_to_chat(207, 'closetCleaner2: debug inventory saved to ' .. dbg_inv_path)
        end

        local dbg_sets_path = windower.addon_path .. 'report/' .. player_name .. '_sets.txt'
        local fs = io.open(dbg_sets_path, 'w+')
        if fs then
            fs:write('closetCleaner2 Sets Debug:\n')
            fs:write(string.rep('=', 60) .. '\n\n')
            for id, info in pairs(gear_items) do
                local entry = res.items[id]
                local name = entry and entry.en or ('ID:' .. tostring(id))
                local job_list = sorted_keys_alpha(info.jobs)
                fs:write(name .. '  ->  ' .. table.concat(job_list, ', ') .. '\n')
            end
            fs:close()
            windower.add_to_chat(207, 'closetCleaner2: debug sets saved to ' .. dbg_sets_path)
        end
    end
end

----------------------------------------------------------------------
-- Addon commands
----------------------------------------------------------------------

windower.register_event('addon command', function(...)
    local args = {...}
    if not args[1] then return end
    local cmd = args[1]:lower():gsub('^%s+', ''):gsub('%s+$', '')

    if cmd == 'report' then
        local cfg = load_settings()
        if not cfg then return end
        local char_name = args[2] and ucfirst(args[2]) or windower.ffxi.get_player().name
        local jobs = get_character_jobs(cfg, char_name)
        if not jobs or #jobs == 0 then
            windower.add_to_chat(207, 'closetCleaner: no jobs configured for ' .. char_name
                .. ', scanning all jobs. Use  //cc add ' .. char_name .. ' <jobs>  to customize.')
            jobs = ALL_JOBS
        end
        local report_cfg = {
            jobs             = jobs,
            ignore_patterns  = cfg.global.ignore_patterns,
            skip_bags        = cfg.global.skip_bags,
            max_use_count    = cfg.global.max_use_count,
            debug            = cfg.global.debug,
            file_patterns    = cfg.global.file_patterns,
            report_mode      = cfg.global.report_mode or 'default',
        }
        local ok, err = pcall(run_report, report_cfg, char_name)
        if not ok then
            windower.add_to_chat(123, 'closetCleaner2: report failed: ' .. tostring(err))
        end

    elseif cmd == 'add' then
        if not args[2] then
            windower.add_to_chat(123, 'closetCleaner2: usage:  //cc add <character> <job1> [job2] ...')
            return
        end
        local char_name = ucfirst(args[2])
        local jobs = {}
        for i = 3, #args do
            jobs[#jobs + 1] = args[i]
        end
        if #jobs == 0 then
            windower.add_to_chat(123, 'closetCleaner2: provide at least one job.  //cc add ' .. char_name .. ' DRG WHM ...')
            return
        end
        local cfg = load_settings()
        if not cfg then return end
        local added = add_character_jobs(cfg, char_name, jobs)
        if #added > 0 then
            windower.add_to_chat(207, 'closetCleaner2: added ' .. table.concat(added, ', ') .. ' for ' .. char_name)
        else
            windower.add_to_chat(207, 'closetCleaner2: ' .. char_name .. ' already has those jobs')
        end
        local current = get_character_jobs(cfg, char_name)
        windower.add_to_chat(207, 'closetCleaner2: ' .. char_name .. ' jobs: ' .. table.concat(current, ', '))

    elseif cmd == 'remove' then
        if not args[2] then
            windower.add_to_chat(123, 'closetCleaner2: usage:  //cc remove <character> <job1> [job2] ...')
            return
        end
        local char_name = ucfirst(args[2])
        local jobs = {}
        for i = 3, #args do
            jobs[#jobs + 1] = args[i]
        end
        if #jobs == 0 then
            windower.add_to_chat(123, 'closetCleaner2: provide at least one job.  //cc remove ' .. char_name .. ' DRG WHM ...')
            return
        end
        local cfg = load_settings()
        if not cfg then return end
        local removed = remove_character_jobs(cfg, char_name, jobs)
        if #removed > 0 then
            windower.add_to_chat(207, 'closetCleaner2: removed ' .. table.concat(removed, ', ') .. ' from ' .. char_name)
        else
            windower.add_to_chat(207, 'closetCleaner2: none of those jobs were configured for ' .. char_name)
        end
        local current = get_character_jobs(cfg, char_name) or {}
        if #current > 0 then
            windower.add_to_chat(207, 'closetCleaner2: ' .. char_name .. ' jobs: ' .. table.concat(current, ', '))
        else
            windower.add_to_chat(207, 'closetCleaner2: ' .. char_name .. ' has no jobs configured')
        end

    elseif cmd == 'addpattern' then
        if not args[2] then
            windower.add_to_chat(123, 'closetCleaner2: usage:  //cc addpattern <pattern>')
            windower.add_to_chat(123, '  Use {name} for character name, {job} for job abbreviation.')
            windower.add_to_chat(123, '  Pattern is relative to GearSwap data/ dir.')
            windower.add_to_chat(123, '  Example:  //cc addpattern {name}/{job}_custom.lua')
            return
        end
        local pattern = table.concat({unpack(args, 2)}, ' ')
        local cfg = load_settings()
        if not cfg then return end
        if not cfg.global.file_patterns then cfg.global.file_patterns = {} end

        for _, existing in ipairs(cfg.global.file_patterns) do
            if existing == pattern then
                windower.add_to_chat(207, 'closetCleaner2: pattern already exists: ' .. pattern)
                return
            end
        end

        cfg.global.file_patterns[#cfg.global.file_patterns + 1] = pattern
        save_settings(cfg)
        windower.add_to_chat(207, 'closetCleaner2: added file pattern: ' .. pattern)

    elseif cmd == 'removepattern' then
        if not args[2] then
            windower.add_to_chat(123, 'closetCleaner2: usage:  //cc removepattern <pattern>')
            return
        end
        local pattern = table.concat({unpack(args, 2)}, ' ')
        local cfg = load_settings()
        if not cfg then return end
        if not cfg.global.file_patterns then
            windower.add_to_chat(207, 'closetCleaner2: no custom file patterns configured')
            return
        end

        local found = false
        local kept = {}
        for _, existing in ipairs(cfg.global.file_patterns) do
            if existing == pattern then
                found = true
            else
                kept[#kept + 1] = existing
            end
        end

        if found then
            cfg.global.file_patterns = kept
            save_settings(cfg)
            windower.add_to_chat(207, 'closetCleaner2: removed file pattern: ' .. pattern)
        else
            windower.add_to_chat(207, 'closetCleaner2: pattern not found: ' .. pattern)
        end

    elseif cmd == 'listpatterns' then
        windower.add_to_chat(207, 'closetCleaner2: base file patterns (built-in):')
        for _, p in ipairs(BASE_FILE_PATTERNS) do
            windower.add_to_chat(207, '  ' .. p)
        end
        local cfg = load_settings()
        if cfg and cfg.global.file_patterns and #cfg.global.file_patterns > 0 then
            windower.add_to_chat(207, 'closetCleaner2: custom file patterns (from settings):')
            for _, p in ipairs(cfg.global.file_patterns) do
                windower.add_to_chat(207, '  ' .. p)
            end
        else
            windower.add_to_chat(207, 'closetCleaner2: no custom file patterns configured')
        end

    elseif cmd == 'reportmode' then
        local cfg = load_settings()
        if not cfg then return end
        local mode = args[2] and args[2]:lower() or nil
        if not mode then
            windower.add_to_chat(207, 'closetCleaner2: report_mode = ' .. (cfg.global.report_mode or 'default'))
            return
        end
        if mode ~= 'default' and mode ~= 'csv' then
            windower.add_to_chat(123, 'closetCleaner2: invalid mode "' .. mode .. '". Use "default" or "csv".')
            return
        end
        cfg.global.report_mode = mode
        save_settings(cfg)
        windower.add_to_chat(207, 'closetCleaner2: report_mode set to ' .. mode)

    elseif cmd == 'help' then
        windower.add_to_chat(207, 'closetCleaner2 commands:')
        windower.add_to_chat(207, '  //cc report [charname]                   - Generate gear report (default: current character)')
        windower.add_to_chat(207, '  //cc reportmode [default|csv]            - Get/set report output format')
        windower.add_to_chat(207, '  //cc add <charname> <job1> [job2] ...    - Add jobs for a character')
        windower.add_to_chat(207, '  //cc remove <charname> <job1> [job2] ... - Remove jobs from a character')
        windower.add_to_chat(207, '  //cc addpattern <pattern>                - Add a custom file pattern')
        windower.add_to_chat(207, '  //cc removepattern <pattern>             - Remove a custom file pattern')
        windower.add_to_chat(207, '  //cc listpatterns                        - Show all file patterns')
        windower.add_to_chat(207, '  //cc help                                - Show this help')
        windower.add_to_chat(207, 'File patterns use {name} and {job} placeholders, relative to GearSwap data/ dir.')
    else
        windower.add_to_chat(123, 'closetCleaner2: unknown command "' .. cmd .. '". Try //cc help')
    end
end)

windower.register_event('load', function()
    windower.add_to_chat(207, 'closetCleaner2 loaded. Type //cc help for commands.')
end)
