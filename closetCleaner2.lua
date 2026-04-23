_addon.name = 'closetCleaner2'
_addon.version = '2.0'
_addon.author = 'Brimstone, Gol-Exe'
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

local function load_config()
    local cfg_path = windower.addon_path .. 'ccConfig.lua'
    local chunk, err = loadfile(cfg_path)
    if not chunk then
        windower.add_to_chat(123, 'closetCleaner2: failed to load ccConfig.lua: ' .. tostring(err))
        return nil
    end
    local ok, cfg = pcall(chunk)
    if not ok or type(cfg) ~= 'table' then
        windower.add_to_chat(123, 'closetCleaner2: ccConfig.lua must return a table')
        return nil
    end
    return cfg
end

----------------------------------------------------------------------
-- Resource index  (built once, reused across reports)
----------------------------------------------------------------------

local items_by_name     -- res short name (lower) -> id
local items_by_longname -- res long name  (lower) -> id

local function build_resource_index()
    if items_by_name then return end
    items_by_name = {}
    items_by_longname = {}
    for id, entry in pairs(res.items) do
        if entry.en then
            items_by_name[entry.en:lower()] = id
        end
        if entry.enl then
            items_by_longname[entry.enl:lower()] = id
        end
    end
end

local function resolve_item_id(name_lower)
    return items_by_name[name_lower] or items_by_longname[name_lower]
end

local function is_equippable(item_entry)
    if not item_entry or not item_entry.slots then
        return false
    end
    if type(item_entry.slots) == 'table' then
        return next(item_entry.slots) ~= nil
    end
    return item_entry.slots ~= 0
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
        local id = items_by_name[best_name]
        local entry = id and res.items[id]
        if entry then return entry.en, best_dist end
    end
    return nil
end

----------------------------------------------------------------------
-- GearSwap data path resolution
----------------------------------------------------------------------

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

local function build_search_dirs(gs_path)
    local dirs = {}
    local data = gs_path .. 'data/'
    local name = windower.ffxi.get_player().name
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

local function resolve_job_lua(gs_path, job)
    local data = gs_path .. 'data/'
    local name = windower.ffxi.get_player().name
    local sub = data .. name .. '/'
    local candidates = {
        data .. name .. '_' .. job .. '_Gear.lua',
        data .. name .. '_' .. job .. '_gear.lua',
        data .. name .. '_' .. job .. '.lua',
        sub  .. name .. '_' .. job .. '_Gear.lua',
        sub  .. name .. '_' .. job .. '_gear.lua',
        sub  .. name .. '_' .. job .. '.lua',
        data .. job  .. '_Gear.lua',
        data .. job  .. '_gear.lua',
        data .. job  .. '.lua',
    }
    for _, p in ipairs(candidates) do
        if file_exists(p) then return p end
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

local function run_report(cfg)
    build_resource_index()

    local player_name = windower.ffxi.get_player().name
    local gs_path = gearswap_base_path()
    local search_dirs = build_search_dirs(gs_path)

    -- Build skip-bags lookup
    local skip_bags_set = {}
    for _, b in ipairs(cfg.skip_bags or {}) do
        skip_bags_set[b] = true
    end

    ----------------------------------------------------------------
    -- Phase 1: Read inventory
    ----------------------------------------------------------------
    windower.add_to_chat(207, 'closetCleaner: reading inventory...')
    local inventory = read_inventory(skip_bags_set)

    ----------------------------------------------------------------
    -- Phase 2: Parse gear from lua files
    ----------------------------------------------------------------
    windower.add_to_chat(207, 'closetCleaner: parsing lua files...')

    -- gear_items[item_id] = { jobs = {JOB=true, ...} }
    local gear_items = {}
    -- unresolved[name_lower] = { original = first_seen_casing, jobs = {JOB=true, ...} }
    local unresolved = {}

    for _, job in ipairs(cfg.jobs) do
        local lua_path = resolve_job_lua(gs_path, job)
        if not lua_path then
            windower.add_to_chat(8, 'closetCleaner: no lua file found for ' .. job)
        else
            windower.add_to_chat(207, 'closetCleaner: parsing ' .. job)
            local ok, names = pcall(parser.parse_file_recursive, lua_path, search_dirs)
            if not ok then
                windower.add_to_chat(123, 'closetCleaner: error parsing ' .. job .. ': ' .. tostring(names))
            else
                for name_lower in pairs(names) do
                    local id = resolve_item_id(name_lower)
                    if id then
                        if not gear_items[id] then
                            gear_items[id] = { jobs = {} }
                        end
                        gear_items[id].jobs[job] = true
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
                        }
                    end
                elseif is_equippable(entry) then
                    unused[#unused + 1] = { id = id, name = name, loc = loc }
                end
            end
        end
    end

    -- Classify lua-only items (not in inventory)
    for id, info in pairs(gear_items) do
        if not inventory[id] then
            local entry = res.items[id]
            if entry then
                local name = entry.en
                if not is_ignored(name, ignore_patterns) then
                    local job_list = sorted_keys_alpha(info.jobs)
                    if not cfg.max_use_count or #job_list <= cfg.max_use_count then
                        missing[#missing + 1] = {
                            id = id, name = name,
                            jobs_str = table.concat(job_list, ','),
                        }
                    end
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
    -- Phase 4: Write report file
    ----------------------------------------------------------------
    if not windower.dir_exists(windower.addon_path .. 'report') then
        windower.create_dir(windower.addon_path .. 'report')
    end
    local report_path = windower.addon_path .. 'report/' .. player_name .. '_report.txt'
    local f = io.open(report_path, 'w+')
    if not f then
        windower.add_to_chat(123, 'closetCleaner: could not open report file for writing')
        return
    end

    local banner = string.rep('=', NAME_W + JOBS_W + LOC_W + 12)
    f:write(banner .. '\n')
    f:write('  ClosetCleaner Report  --  ' .. player_name .. '  --  ' .. os.date('%Y-%m-%d %H:%M') .. '\n')
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
    f:write('Section 3: MISSING GEAR (in lua files, not in inventory)   [' .. #missing .. ' items]\n')
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

    -- Section 4: Possible misspellings
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
    windower.add_to_chat(207, 'closetCleaner: report saved to ' .. report_path)

    ----------------------------------------------------------------
    -- Optional debug files
    ----------------------------------------------------------------
    if cfg.debug then
        local dbg_inv_path = windower.addon_path .. 'report/' .. player_name .. '_inventory.txt'
        local fi = io.open(dbg_inv_path, 'w+')
        if fi then
            fi:write('closetCleaner Inventory Debug:\n')
            fi:write(string.rep('=', 60) .. '\n\n')
            for id, inv_info in pairs(inventory) do
                local entry = res.items[id]
                local name = entry and entry.en or ('ID:' .. tostring(id))
                fi:write(name .. '  ->  ' .. table.concat(inv_info.bags, ', ') .. '\n')
            end
            fi:close()
            windower.add_to_chat(207, 'closetCleaner: debug inventory saved to ' .. dbg_inv_path)
        end

        local dbg_sets_path = windower.addon_path .. 'report/' .. player_name .. '_sets.txt'
        local fs = io.open(dbg_sets_path, 'w+')
        if fs then
            fs:write('closetCleaner Sets Debug:\n')
            fs:write(string.rep('=', 60) .. '\n\n')
            for id, info in pairs(gear_items) do
                local entry = res.items[id]
                local name = entry and entry.en or ('ID:' .. tostring(id))
                local job_list = sorted_keys_alpha(info.jobs)
                fs:write(name .. '  ->  ' .. table.concat(job_list, ', ') .. '\n')
            end
            fs:close()
            windower.add_to_chat(207, 'closetCleaner: debug sets saved to ' .. dbg_sets_path)
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
        local cfg = load_config()
        if not cfg then return end
        local ok, err = pcall(run_report, cfg)
        if not ok then
            windower.add_to_chat(123, 'closetCleaner: report failed: ' .. tostring(err))
        end
    elseif cmd == 'help' then
        windower.add_to_chat(207, 'closetCleaner v2 commands:')
        windower.add_to_chat(207, '  //cc report  - Generate gear usage report')
        windower.add_to_chat(207, '  //cc help    - Show this help')
    else
        windower.add_to_chat(123, 'closetCleaner: unknown command "' .. cmd .. '". Try //cc help')
    end
end)

windower.register_event('load', function()
    windower.add_to_chat(207, 'closetCleaner v2 loaded. Type //cc report to generate a report.')
end)
