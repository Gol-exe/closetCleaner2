-- luaParser.lua  --  Text-based gear extraction for ClosetCleaner v2
-- Reads GearSwap Lua files as plain text and extracts gear item names
-- from known equipment slot assignments using pattern matching.

local parser = {}

local gear_slots = {
    main=true, sub=true, range=true, ranged=true, ammo=true,
    head=true, neck=true, body=true, hands=true,
    back=true, waist=true, legs=true, feet=true,
    left_ear=true, right_ear=true, ear1=true, ear2=true, lear=true, rear=true,
    left_ring=true, right_ring=true, ring1=true, ring2=true, lring=true, rring=true,
}

-- Strip single-line comments (--) while preserving strings.
-- Handles the common case; does not attempt full Lua lexing.
local function strip_comments(text)
    local lines = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do
        local stripped = line
        local i = 1
        while i <= #stripped do
            local c = stripped:sub(i, i)
            if c == '"' or c == "'" then
                local close = stripped:find(c, i + 1, true)
                if close then
                    i = close + 1
                else
                    break
                end
            elseif c == '-' and stripped:sub(i + 1, i + 1) == '-' then
                stripped = stripped:sub(1, i - 1)
                break
            else
                i = i + 1
            end
        end
        lines[#lines + 1] = stripped
    end
    return table.concat(lines, '\n')
end

-- Strip block comments  --[[ ... ]]  or  --[[ ... ]]--
-- Lua's . doesn't match newlines, so we search with string.find instead.
local function strip_block_comments(text)
    local result = text
    while true do
        local open = result:find('%-%-%[%[', 1, false)
        if not open then break end
        local close = result:find('%]%]', open + 4, false)
        if not close then
            result = result:sub(1, open - 1)
            break
        end
        local end_pos = close + 1
        if result:sub(end_pos + 1, end_pos + 2) == '--' then
            end_pos = end_pos + 2
        end
        result = result:sub(1, open - 1) .. result:sub(end_pos + 1)
    end
    return result
end

-- Collect variable-to-string assignments for resolution of indirect gear
-- references like  head = EMPY.Head  where EMPY.Head was set to a string.
-- Returns { ["VAR.field"] = "value", ["simple_var"] = "value", ... }
local function collect_variables(clean)
    local vars = {}

    -- TABLE.field = "string"  /  TABLE.field = 'string'
    for tbl, field, val in clean:gmatch('(%a[%w_]*)%.(%a[%w_]*)%s*=%s*"([^"]+)"') do
        vars[tbl .. '.' .. field] = val:match('^%s*(.-)%s*$')
    end
    for tbl, field, val in clean:gmatch("(%a[%w_]*)%.(%a[%w_]*)%s*=%s*'([^']+)'") do
        vars[tbl .. '.' .. field] = val:match('^%s*(.-)%s*$')
    end

    -- TABLE = { field = "string", ... }  (table constructors via balanced braces)
    for tbl_name, body in clean:gmatch('(%a[%w_]*)%s*=%s*(%b{})') do
        for field, val in body:gmatch('(%a[%w_]*)%s*=%s*"([^"]+)"') do
            local key = tbl_name .. '.' .. field
            if not vars[key] then
                vars[key] = val:match('^%s*(.-)%s*$')
            end
        end
        for field, val in body:gmatch("(%a[%w_]*)%s*=%s*'([^']+)'") do
            local key = tbl_name .. '.' .. field
            if not vars[key] then
                vars[key] = val:match('^%s*(.-)%s*$')
            end
        end
    end

    -- simple_var = "string"  (not a gear slot or 'name', to avoid duplicating
    -- direct slot matches handled by extract_gear_names)
    for key, val in clean:gmatch('(%a[%w_]*)%s*=%s*"([^"]+)"') do
        if not gear_slots[key:lower()] and key ~= 'name' then
            vars[key] = val:match('^%s*(.-)%s*$')
        end
    end
    for key, val in clean:gmatch("(%a[%w_]*)%s*=%s*'([^']+)'") do
        if not gear_slots[key:lower()] and key ~= 'name' then
            vars[key] = val:match('^%s*(.-)%s*$')
        end
    end

    return vars
end

-- Extract all gear item names from a single Lua source string.
-- Returns a table  { ["item name lowercase"] = true, ... }
function parser.extract_gear_names(source)
    local items = {}
    local clean = strip_comments(strip_block_comments(source))

    local vars = collect_variables(clean)

    -- Pattern 1: slot_key = "Item Name"  or  slot_key = 'Item Name'
    -- We match  word = "string"  then check if word is a known slot.
    -- Slot check is case-insensitive so that  TABLE.Head = "Item"  is also
    -- recognised (the gmatch captures "Head" as the key after the dot).
    for key, val in clean:gmatch('(%a[%w_]*)%s*=%s*"([^"]+)"') do
        if gear_slots[key:lower()] then
            local name = val:match('^%s*(.-)%s*$')
            if name ~= '' and name ~= 'empty' then
                items[name:lower()] = true
            end
        end
    end
    for key, val in clean:gmatch("(%a[%w_]*)%s*=%s*'([^']+)'") do
        if gear_slots[key:lower()] then
            local name = val:match('^%s*(.-)%s*$')
            if name ~= '' and name ~= 'empty' then
                items[name:lower()] = true
            end
        end
    end

    -- Pattern 2: name = "Item Name" inside augmented gear tables.
    for val in clean:gmatch('name%s*=%s*"([^"]+)"') do
        local name = val:match('^%s*(.-)%s*$')
        if name ~= '' and name ~= 'empty' then
            items[name:lower()] = true
        end
    end
    for val in clean:gmatch("name%s*=%s*'([^']+)'") do
        local name = val:match('^%s*(.-)%s*$')
        if name ~= '' and name ~= 'empty' then
            items[name:lower()] = true
        end
    end

    -- Pattern 3: slot_key = { "Item Name", augments={...} }
    -- Augmented gear from //gs export uses the item name as the first
    -- positional element in the table, with no name= key.
    for key, val in clean:gmatch('(%a[%w_]*)%s*=%s*{%s*"([^"]+)"') do
        if gear_slots[key:lower()] then
            local name = val:match('^%s*(.-)%s*$')
            if name ~= '' and name ~= 'empty' then
                items[name:lower()] = true
            end
        end
    end
    for key, val in clean:gmatch("(%a[%w_]*)%s*=%s*{%s*'([^']+)'") do
        if gear_slots[key:lower()] then
            local name = val:match('^%s*(.-)%s*$')
            if name ~= '' and name ~= 'empty' then
                items[name:lower()] = true
            end
        end
    end

    -- Pattern 4: slot_key = TABLE.field  (variable reference to a table field)
    for key, tbl, field in clean:gmatch('(%a[%w_]*)%s*=%s*(%a[%w_]*)%.(%a[%w_]*)') do
        if gear_slots[key:lower()] then
            local val = vars[tbl .. '.' .. field]
            if val and val ~= '' and val:lower() ~= 'empty' then
                items[val:lower()] = true
            end
        end
    end

    -- Pattern 5: slot_key = simple_var  (reference to a plain string variable)
    for key, var_ref in clean:gmatch('(%a[%w_]*)%s*=%s*(%a[%w_]*)') do
        if gear_slots[key:lower()] and vars[var_ref] then
            local val = vars[var_ref]
            if val ~= '' and val:lower() ~= 'empty' then
                items[val:lower()] = true
            end
        end
    end

    return items
end

-- Extract include directives from source text.
-- Matches:  include('Filename')  include("Filename")  include 'Filename'  include "Filename"
-- Returns a list of raw include strings (e.g. "Mote-Include").
function parser.extract_includes(source)
    local includes = {}
    local seen = {}
    local clean = strip_comments(strip_block_comments(source))

    for name in clean:gmatch("include%s*%(?%s*['\"]([^'\"]+)['\"]") do
        local key = name:lower()
        if not seen[key] then
            seen[key] = true
            includes[#includes + 1] = name
        end
    end
    return includes
end

-- Read a file's full contents. Returns the string, or nil on failure.
function parser.read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
end

-- Parse a Lua file and all its includes recursively.
-- search_dirs: ordered list of directories to search for includes.
-- Returns  { ["item name lowercase"] = true, ... }  (merged from file + includes).
function parser.parse_file_recursive(filepath, search_dirs)
    local visited = {}
    local all_items = {}

    local function process(path)
        local norm = path:lower():gsub('\\', '/')
        if visited[norm] then return end
        visited[norm] = true

        local source = parser.read_file(path)
        if not source then return end

        local items = parser.extract_gear_names(source)
        for k in pairs(items) do
            all_items[k] = true
        end

        local includes = parser.extract_includes(source)
        for _, inc_name in ipairs(includes) do
            local inc_file = inc_name
            if not inc_file:match('%.lua$') then
                inc_file = inc_file .. '.lua'
            end
            for _, dir in ipairs(search_dirs) do
                local try_path = dir .. inc_file
                if windower and windower.file_exists and windower.file_exists(try_path) then
                    process(try_path)
                    break
                elseif not windower then
                    local f = io.open(try_path, 'r')
                    if f then
                        f:close()
                        process(try_path)
                        break
                    end
                end
            end
        end
    end

    process(filepath)
    return all_items
end

return parser
