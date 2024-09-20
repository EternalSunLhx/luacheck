std = "min"
cache = true
include_files = {"src", "spec/*.lua", "scripts/*.lua", "*.rockspec", "*.luacheckrc"}
exclude_files = {"src/luacheck/vendor"}

-- { function_name = { args_index, module_var_define_table_index, } }
global_define = { 
    classDef = { 1, 2, },
    moduleDef = { 1, 2, },
}

files["src/luacheck/unicode_printability_boundaries.lua"].max_line_length = false
