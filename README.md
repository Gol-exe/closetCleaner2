addon: closetCleaner2

A Windower 4 addon that scans your GearSwap lua files and compares the gear
they reference against your current inventory, producing a clean report that
shows which pieces are unused, which are in active use (and by which jobs),
and which are referenced in your luas but missing from your bags.

## Files

- `closetCleaner2.lua` - Addon entry point (commands, inventory reading, report generation)
- `luaParser.lua` - Text-based parser that extracts gear names from GearSwap lua files
- `data/settings.xml` - User configuration (per-character job lists, ignore patterns, etc.)

## Setup

1. Place the `closetCleaner2` folder in your `Windower4/addons/` directory.
2. Load the addon: `//lua l closetCleaner2`
3. Add your character's jobs: `//cc add YourName BLM WHM RDM`
4. Your GearSwap lua files should be in the standard location: `gearswap/data/`.

The addon ships with a default `data/settings.xml` containing standard ignore
patterns and skip bags. Job lists are configured per-character using commands.

## Usage

```
//lua l closetCleaner2                       -- Load the addon
//cc add <charname> <job1> [job2] ...        -- Add jobs for a character
//cc remove <charname> <job1> [job2] ...     -- Remove jobs from a character
//cc report                                  -- Generate report for current character
//cc report <charname>                       -- Generate report as another character
//cc addpattern <pattern>                    -- Add a custom file pattern
//cc removepattern <pattern>                 -- Remove a custom file pattern
//cc listpatterns                            -- Show all file patterns (built-in + custom)
//cc help                                    -- Show available commands
```

### Examples

```
//cc add <characterName> DRG WHM NIN        -- <characterName> now scans DRG, WHM, NIN
//cc add <characterName> BLM                -- Adds BLM to <characterName>'s existing list
//cc remove <characterName> NIN             -- Removes NIN from <characterName>'s list
//cc report                                 -- Report for whoever is logged in
//cc report <characterName>                 -- Report using <characterName>'s jobs & lua files
//cc addpattern {name}/{job}_custom.lua     -- Add a custom file pattern
//cc listpatterns                           -- See all patterns being searched
```

The report is saved to: `closetCleaner2/report/<charname>_report.txt`

## Settings

Configuration lives in `data/settings.xml`. Job lists are managed per-character
via `//cc add` and `//cc remove`.
Global options can be edited directly in the XML:

- **ignore_patterns** - Lua patterns for items to exclude (furniture, food, tools, etc.)
- **skip_bags** - Bag names to skip when reading inventory (e.g. `Storage`, `Temporary`)
- **max_use_count** - Only show items used by at most this many jobs (empty = no limit)
- **debug** - Set to `true` to write extra `_inventory.txt` and `_sets.txt` debug files
- **file_patterns** - Custom file patterns for locating job lua files (see below)

## Report Sections

1. **UNUSED GEAR** - Items in your inventory that appear in zero lua files
2. **GEAR IN USE** - Items found in your lua files, sorted by how many jobs use them
3. **MISSING GEAR** - Items referenced in lua files but not found in your inventory
4. **POSSIBLE MISSPELLINGS** - Item names in your lua files that don't match any known item in the game's resource database. Each entry shows the name as written, which jobs reference it, and a "Did you mean?" suggestion based on the closest matching real item name (using Levenshtein distance). This helps catch typos in your GearSwap sets that would silently fail to equip.

## How It Works

v2 uses text-based pattern matching to extract gear names from your lua files
rather than executing them. This means:

- No GearSwap runtime dependencies (no more crashes from bad includes)
- Safe to run alongside GearSwap without conflicts
- No need to unload after running
- Handles `include` directives by following them and parsing those files too
- Works with any GearSwap style (Mote, Sel, custom, etc.)

The trade-off is that dynamically constructed gear names (e.g. built via string
concatenation or function calls) won't be detected. In practice this affects
very few items since the vast majority of gear is defined as string literals.

## File Naming

closetCleaner2 searches for job lua files using pattern templates with two
placeholders: `{name}` (character name) and `{job}` (job abbreviation like
`BLM`). All patterns are relative to the GearSwap `data/` directory.

### Built-in patterns (always searched first)

| Pattern | Example path |
|---|---|
| `{name}_{job}_Gear.lua` | `data/Ragnar_BLM_Gear.lua` |
| `{name}_{job}_gear.lua` | `data/Ragnar_BLM_gear.lua` |
| `{name}_{job}_items.lua` | `data/Ragnar_BLM_items.lua` |
| `{name}_{job}.lua` | `data/Ragnar_BLM.lua` |
| `{name}_items.lua` | `data/Ragnar_items.lua` |
| `{name}/{name}_{job}_Gear.lua` | `data/Ragnar/Ragnar_BLM_Gear.lua` |
| `{name}/{name}_{job}_gear.lua` | `data/Ragnar/Ragnar_BLM_gear.lua` |
| `{name}/{name}_{job}_items.lua` | `data/Ragnar/Ragnar_BLM_items.lua` |
| `{name}/{name}_{job}.lua` | `data/Ragnar/Ragnar_BLM.lua` |
| `{name}/{name}_items.lua` | `data/Ragnar/Ragnar_items.lua` |
| `{job}_Gear.lua` | `data/BLM_Gear.lua` |
| `{job}_gear.lua` | `data/BLM_gear.lua` |
| `{job}_items.lua` | `data/BLM_items.lua` |
| `{job}.lua` | `data/BLM.lua` |

### Custom patterns

If you use a non-standard file naming convention, add custom patterns via
commands or directly in `data/settings.xml` under `<file_patterns>`:

```
//cc addpattern {name}/{job}_custom.lua
//cc addpattern sets/{job}_sets.lua
```

Custom patterns are tried after the built-in ones. The first file that exists
wins, so order matters. Use `//cc listpatterns` to see all active patterns.
