std = "min"
cache = true
include_files = {"src", "spec/*.lua", "scripts/*.lua", "*.rockspec", "*.luacheckrc"}
exclude_files = {"src/luacheck/vendor"}

global_pattern = { 
    ["%s+classDef%(\"(%a+)\""] = "class",
    ["=%s*classDef%(\"(%a+)\""] = "class",
    ["^classDef%(\"(%a+)\""] = "class",
}

files["src/luacheck/unicode_printability_boundaries.lua"].max_line_length = false
