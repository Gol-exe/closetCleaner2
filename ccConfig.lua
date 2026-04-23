-- ClosetCleaner v2 Configuration
-- Edit this file then reload: //lua r closetCleaner

return {
    -- Jobs to scan. closetCleaner looks for <PlayerName>_<JOB>.lua, <JOB>.lua, etc.
    jobs = {
        'BLM','BLU','BRD','BST','COR','DRG','GEO','MNK','NIN',
        'PLD','PUP','RDM','RNG','RUN','SAM','SMN','SCH','THF','WAR','WHM',
    },

    -- Lua pattern list: any item whose name matches is excluded from the report.
    -- See https://www.lua.org/pil/20.2.html for pattern syntax.
    ignore_patterns = {
        "Rem's Tale.*",   "Storage Slip %d+", "Deed of.*",      "%a+ Virtue",
        "Dragua's Scale",  "Glittering Yarn",  "Dim%. Ring.*",   "Cupboard",
        ".*VCS.*",         ".*Abjuration.*",   "%a+ Organ",      "Mecisto%. Mantle",
        "Homing Ring",     "%a+ Plans",        "Orblight",       "Yellow 3D Almirah",
        "%a+ Statue",      "Luminion Chip",    ".* Mannequin",   "R%. Bamboo Grass",
        "Coiled Yarn",     "Stationery Set",   "%a+ Flag",       "Bonbori",
        "Imperial Standard", "%a+ Bed",        "Adamant%. Statue","Festival Dolls",
        "Taru Tot Toyset", "Bookshelf",        "Guild Flyers",   "San d'Orian Tree",
        ".*Signet Staff",  "Capacity Ring",    "Facility Ring",  "Trizek Ring",
        "Bam%. Grass Basket","Portafurnace",   "%a+'s Sign",     "%a+'s Apron",
        "Toolbag .*",      "%a+ Crepe",        "%a+ Sushi.*",    ".* Stable Collar",
        "Plovid Effluvium","Gem of the %a+",   "Inoshishinofuda","Ichigohitofuri",
        "Chonofuda",       "Shikanofuda",      "Shihei",         "Midras%.s Helm .1",
        "Cobra Staff",     "Ram Staff",        "Fourth Staff",   "Warp Ring",
        "Chocobo Whistle", "Warp Cudgel",      "%a+ Broth",      "Tavnazian Ring",
        "Official Reflector","Pashhow Ring",   "Dredger Hose",   "Trench Tunic",
        "Sanjaku%.Tenugui","Katana%.kazari",   "Carver's Torque","Kabuto%.kazari",
        "Etched Memory",   "Trbl%. Hatchet",   "Maat's Cap",     "Trbl%. Pickaxe",
        "Olduum Ring",     "Linkpearl",        "Caliber Ring",   "Vana'clock",
        "Signal Pearl",    "Windy Greens",     "Nexus Cape",     "Wastebasket",
        "Sickle",          "Carpenter's Gloves","Shinobi%.Tabi", "Guardian Board",
        "%a+ Pie",         "Pet Food %a+",     "Reraise %a+",    "P%. %a+ Card",
    },

    -- Bags to skip when reading inventory.
    skip_bags = { 'Storage', 'Temporary' },

    -- Max usage count to include in the report (nil = unlimited).
    max_use_count = nil,

    -- Print extra debug files (_inventory.txt, _sets.txt).
    debug = false,
}
