local fs = require "luacheck.fs"
local utils = require "luacheck.utils"
local parse = require "luacheck.stages.parse"
local globbing = require "luacheck.globbing"
local check_state = require "luacheck.check_state"

local project_global = {}
local project_files = {}
local project_exist_files = {}
local project_global_cache_filename = ".luacheckpg"

local function clear_table(t)
    if t == nil or not next(t) then return t end

    for k in pairs(t) do
        t[k] = nil
    end
end



local project = {}

local function try_init_project_files(cache_filepath)
    local content = utils.read_file(cache_filepath)
    if content == nil then return end

    local load_func = utils.load(content, nil, "load project cache file")
    if load_func ~= nil then
        project_files = load_func() or {}
    end
end

local function need_do_match(exist_project_global, modify_time, global_define)
    if exist_project_global == nil then return true end
    return exist_project_global.modify_time < modify_time
end

local function try_parse_source(filepath)
    local source = utils.read_file(filepath)
    if source == nil then return end

   local chstate = check_state.new(source, filepath)
   parse.run(chstate)
   return chstate
end

local function add_global(global, global_name, global_type, local_var_define)
    if global_name == "_" then return end

    if local_var_define ~= nil and local_var_define[global_name] then return end

    if global[global_name] == nil then
        global[global_name] = global_type
    end
end

local global_parse_handles = {}

local function try_parse_block(block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    local global_parse_handle = global_parse_handles[block.tag]
    if global_parse_handle == nil then return end
    global_parse_handle(block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
end

local function try_parse_block_local_var(sub_block, block_local_var_define)
    if block_local_var_define == nil then return end

    local tag = sub_block.tag
    if tag == "Local" or tag == "Localrec" then
        for _, var_name_node in ipairs(sub_block[1]) do
            if var_name_node.tag == "Id" then
                block_local_var_define[var_name_node[1]] = var_name_node.line
            end
        end
    end
end

local function for_each_block(block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define, block_local_var_define)
    if block == nil then return end
    for _, sub_block in ipairs(block) do
        local tag = sub_block.tag
        if tag == "Local" then
            try_parse_block_local_var(sub_block, block_local_var_define)
        end

        try_parse_block(sub_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)

        if tag == "Localrec" then
            try_parse_block_local_var(sub_block, block_local_var_define)
        end
    end
end

global_parse_handles["Local"] = function(local_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    if global_define == nil then return end
    local value_node = local_block[2]
    if value_node == nil then return end

    for block_index, block in ipairs(value_node) do
        if block.tag == "Call" or block.tag == "Table" then
            global_parse_handles[block.tag](block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
        end
    end
end

global_parse_handles["Call"] = function(call_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    if global_define == nil then return end
    local function_name_node = call_block[1]
    if function_name_node == nil or function_name_node.tag ~= "Id" then return end

    local function_name = function_name_node[1]
    local global_define_data = global_define[function_name]
    if global_define_data == nil then return end

    local module_name_arg_index = global_define_data[1]
    if module_name_arg_index == nil then return end

    local module_name_arg_node = call_block[module_name_arg_index + 1]
    if module_name_arg_node == nil or module_name_arg_node.tag ~= "String" then return end
    add_global(custom_global, module_name_arg_node[1], function_name)

    local module_var_define_arg_index = global_define_data[2]
    if module_var_define_arg_index == nil then return end

    -- add module var define
    local module_var_arg_node = call_block[module_var_define_arg_index + 1]
    if module_var_arg_node == nil or module_var_arg_node.tag ~= "Table" then return end
    for _, pair_block in ipairs(module_var_arg_node) do
        if pair_block.tag == "Pair" then
            local key_node = pair_block[1]
            if key_node.tag == "String" then
                module_var_define[key_node[1]] = key_node.line
            end
        end
    end
end

global_parse_handles["Return"] = function(return_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    if global_define == nil then return end
    for block_index, block in ipairs(return_block) do
        if block.tag == "Call" or block.tag == "Table" then
            global_parse_handles[block.tag](block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
        end
    end
end

local global_types = { ["_G"] = true, ["_ENV"] = true, }

local function try_parse_normal_global_index_data(var_block, normal_global)
    if var_block.tag ~= "Index" then return false end

    local global_type_node = var_block[1]
    local global_type = global_type_node[1]
    if global_type_node.tag ~= "Id" or global_types[global_type] == nil then return true end

    local global_name_node = var_block[2]
    if global_name_node.tag ~= "String" then return true end

    add_global(normal_global, global_name_node[1], global_type)

    return true
end

local function try_find_block_var_define(block_local_var_define_stack, var_name)
    for index = #block_local_var_define_stack, 1, -1 do
        local block_local_var_define = block_local_var_define_stack[index]
        if block_local_var_define[var_name] then
            return true
        end
    end
end

local function try_parse_normal_global_data(var_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    if var_block.tag ~= "Id" then return end
    local module_var_name = var_block[1]
    if not is_local_env then
        if not try_find_block_var_define(block_local_var_define_stack, module_var_name) then
            add_global(normal_global, module_var_name, "non-standard", local_var_define)
        end
        return
    end

    if module_var_name == "_ENV" then return end
    module_var_define[module_var_name] = var_block.line
end

global_parse_handles["Set"] = function(set_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    local var_define_block = set_block[1]
    local value_define_block = set_block[2]
    
    for var_index, var_block in ipairs(var_define_block) do
        local value_block = value_define_block[var_index]
        if value_block ~= nil then
            if value_block.tag == "Function" or value_block.tag == "Table" or value_block.tag == "Op" then
                try_parse_block(value_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
            end
        end

        -- check function _G.xxx() end / function _ENV.xxx() end
        if not try_parse_normal_global_index_data(var_block, normal_global) then
            try_parse_normal_global_data(var_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
        end
    end
end

global_parse_handles["Function"] = function(function_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    local block_local_var_define = {}
    table.insert(block_local_var_define_stack, block_local_var_define)
    -- add function arg name
    for _, arg_node in ipairs(function_block[1]) do
        if arg_node.tag == "Id" then
            block_local_var_define[arg_node[1]] = arg_node.line
        end
    end

    for_each_block(function_block[2], is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define, block_local_var_define)

    table.remove(block_local_var_define_stack, #block_local_var_define_stack)
end

global_parse_handles["Table"] = function(table_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    for_each_block(table_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
end

global_parse_handles["Pair"] = function(pair_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    local key_block = pair_block[1]
    try_parse_block(key_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)

    local value_block = pair_block[2]
    try_parse_block(value_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
end

global_parse_handles["Localrec"] = function(localrec_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    for_each_block(localrec_block[2], is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
end

global_parse_handles["If"] = function(if_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    for _, block in ipairs(if_block) do
        if block.tag == nil then
            local block_local_var_define = {}
            table.insert(block_local_var_define_stack, block_local_var_define)

            for_each_block(block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define, block_local_var_define)

            table.remove(block_local_var_define_stack, #block_local_var_define_stack)
        end
    end
end

global_parse_handles["While"] = function(while_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    local block_local_var_define = {}
    table.insert(block_local_var_define_stack, block_local_var_define)

    for_each_block(while_block[2], is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define, block_local_var_define)

    table.remove(block_local_var_define_stack, #block_local_var_define_stack)
end

global_parse_handles["Fornum"] = function(for_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    for _, block in ipairs(for_block) do
        if block.tag == nil then
            local block_local_var_define = {}
            table.insert(block_local_var_define_stack, block_local_var_define)

            for_each_block(block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define, block_local_var_define)

            table.remove(block_local_var_define_stack, #block_local_var_define_stack)
        end
    end
end

global_parse_handles["Forin"] = global_parse_handles["Fornum"]

global_parse_handles["Repeat"] = function(repeat_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    local block_local_var_define = {}
    table.insert(block_local_var_define_stack, block_local_var_define)

    for_each_block(repeat_block[1], is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define, block_local_var_define)

    table.remove(block_local_var_define_stack, #block_local_var_define_stack)
end

global_parse_handles["Op"] = function(op_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    for block_index, block in ipairs(op_block) do
        if block_index ~= 1 then
            try_parse_block(block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
        end
    end
end

global_parse_handles["Do"] = function(do_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
    local block_local_var_define = {}
    table.insert(block_local_var_define_stack, block_local_var_define)

    for_each_block(do_block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define, block_local_var_define)

    table.remove(block_local_var_define_stack, #block_local_var_define_stack)
end

local function check_is_local_env(block)
    if block.tag ~= "Local" then return false end
    local var_name_block = block[1]

    for _, var_name_node in ipairs(var_name_block) do
        if var_name_node.tag == "Id" and var_name_node[1] == "_ENV" then return true end
    end

    return false
end

local function check_module_metatable_by_call(call_block, custom_global)
    local call_function_node = call_block[1]
    if call_function_node.tag ~= "Id" or call_function_node[1] ~= "setmetatable" then return end

    local table_name_node = call_block[2]
    if table_name_node == nil or table_name_node.tag ~= "Id" then return end
    local table_name = table_name_node[1]
    if not (table_name == "_ENV" or custom_global[table_name] ~= nil) then return end

    local metatable_node = call_block[3]
    if metatable_node == nil or metatable_node.tag ~= "Table" then return end

    for _, pair_block in ipairs(metatable_node) do
        if pair_block.tag == "Pair" then
            local key_node = pair_block[1]
            if key_node.tag == "String" and key_node[1] == "__index" then
                local value_node = pair_block[2]
                if value_node.tag == "Id" then
                    return value_node[1]
                end
            end
        end
    end
end

local function check_module_metatable_by_set(block, custom_global)
    local value_block = block[2]
    if value_block == nil then return end
    for _, value_node in ipairs(value_block) do
        if value_node.tag == "Call" then
            local metatable_name = check_module_metatable_by_call(value_node, custom_global)
            if metatable_name ~= nil then
                return metatable_name
            end
        end
    end
end

local function check_module_metatable(block, custom_global)
    if block.tag == "Call" then
        return check_module_metatable_by_call(block, custom_global)
    end

    if block.tag == "Local" or block.tag == "Set" then
        return check_module_metatable_by_set(block, custom_global)
    end
end

local function check_local_var_define(root_local_block, local_var_define)
    if root_local_block.tag ~= "Local" then return end
    local var_name_block = root_local_block[1]
    for _, var_name_node in ipairs(var_name_block) do
        if var_name_node.tag == "Id" and var_name_node[1] ~= "_" then
            local_var_define[var_name_node[1]] = var_name_node.line
        end
    end
end

local function check_is_nil(tabA, tabB)
    return (tabA ~= nil and tabB == nil) or (tabA == nil and tabB ~= nil)
end

local function check_table(tabA, tabB)
    if tabA == nil and tabB == nil then return false end

    for k, v in pairs(tabA) do
        if tabB[k] ~= v then
            return true
        end
    end

    return false
end

local function compareDifferences(exist_project_global, normal_global, custom_global, module_var_define, local_var_define)
    local old_normal_global = exist_project_global.normal_global
    if check_is_nil(old_normal_global, normal_global) or check_table(old_normal_global, normal_global) then
        return true
    end

    local old_custom_global = exist_project_global.custom_global
    if check_is_nil(old_custom_global, custom_global) or check_table(old_custom_global, custom_global) then
        return true
    end

    local old_module_var_define = exist_project_global.module_var_define
    if check_is_nil(old_module_var_define, module_var_define) or check_table(old_module_var_define, module_var_define) then
        return true
    end

    local old_local_var_define = exist_project_global.local_var_define
    if check_is_nil(old_local_var_define, local_var_define) or check_table(old_local_var_define, local_var_define) then
        return true
    end

    return false
end

local function try_match_project_file_global(filepath, global_define, check_different, skip_merge)
    local modify_time = fs.get_mtime(filepath)
    project_exist_files[filepath] = modify_time
    local exist_project_global = project_files[filepath]
    if not need_do_match(exist_project_global, modify_time, global_define) then return false end

    exist_project_global = exist_project_global or {}
    exist_project_global.modify_time = modify_time
    project_files[filepath] = exist_project_global

    local ok, chstate = utils.try(try_parse_source, filepath)
    if not ok or chstate == nil then return false end

    local normal_global = {}
    local custom_global = {}
    local module_var_define = {}
    local local_var_define = {}

    local block_local_var_define_stack = {}

    local module_metatable = nil
    local is_local_env = false

    for block_index, block in ipairs(chstate.ast) do
        if not is_local_env then
            is_local_env = check_is_local_env(block)
        elseif module_metatable == nil then
            module_metatable = check_module_metatable(block, custom_global)
        end
        check_local_var_define(block, local_var_define)

        clear_table(block_local_var_define_stack)

        local global_parse_handle = global_parse_handles[block.tag]
        if global_parse_handle ~= nil then
            global_parse_handle(block, is_local_env, local_var_define, block_local_var_define_stack, normal_global, custom_global, module_var_define, global_define)
        end
    end

    if not next(normal_global) then
        normal_global = nil
    end

    if not next(custom_global) then
        custom_global = nil
    end

    if not next(module_var_define) then
        module_var_define = nil
    end

    local need_save = false
    if not skip_merge then
        compareDifferences(exist_project_global, normal_global, custom_global, module_var_define, local_var_define)
    end

    exist_project_global.normal_global = normal_global
    exist_project_global.custom_global = custom_global
    exist_project_global.module_var_define = module_var_define
    exist_project_global.module_metatable = module_metatable

    return need_save
end

local function add_project_global(filepath, globals)
    if globals == nil then return end
    for global_name, type in pairs(globals) do
        local global_data = project_global[global_name] or {}
        global_data[filepath] = type
        project_global[global_name] = global_data
    end
end

local function merge_and_clean_project_global(skip_merge)
    for filepath, global_data in pairs(project_files) do
        if project_exist_files[filepath] == nil then
            project_files[filepath] = nil
        elseif not skip_merge then
            add_project_global(filepath, global_data.normal_global)
            add_project_global(filepath, global_data.custom_global)
        end
    end
end

local function matches_any(globs, filename)
    for _, glob in ipairs(globs) do
        if globbing.match(glob, filename) then
            return true
        end
    end

    return false
end

local function is_filename_included(top_opts, abs_filename)
    return not matches_any(top_opts.exclude_files, abs_filename) and (
       #top_opts.include_files == 0 or matches_any(top_opts.include_files, abs_filename))
end

local function scan_project_global(abs_project_dir, top_opts, skip_merge)
    local lua_files = fs.extract_files(abs_project_dir, ".*%.lua$")
    local global_define = top_opts.global_define

    local need_save = false

    for _, lua_filepath in ipairs(lua_files) do
        lua_filepath = fs.fix_filepath(lua_filepath)
        if is_filename_included(top_opts, lua_filepath) then
            local check_save = try_match_project_file_global(lua_filepath, global_define, skip_merge)
            if not need_save then
                need_save = check_save
            end
        end
    end

    merge_and_clean_project_global(skip_merge)

    return need_save
end

local function globals2string(global_data, global_type_name, global_contents)
    local globals = global_data[global_type_name]
    if globals == nil then return end
    clear_table(global_contents)
    for global_name, type in utils.sorted_pairs(globals) do
        table.insert(global_contents, string.format("[\"%s\"] = \"%s\"", global_name, type))
    end
    return string.format("        %s = { %s, },\n", global_type_name, table.concat(global_contents, ", "))
end

local function module2string(global_data, module_contents)
    local module_var_define = global_data.module_var_define
    if module_var_define == nil then return end
    clear_table(module_contents)

    for module_var_name, line in utils.sorted_pairs(module_var_define) do
        table.insert(module_contents, string.format("[\"%s\"] = %d", module_var_name, line))
    end
    return string.format("        module_var_define = { %s, },\n", table.concat(module_contents, ", "))
end

local function table2string(t)
    if t == nil or not next(t) then return "{}" end

    local global_contents = {}
    local temp_contents = {}

    for filepath, global_data in utils.sorted_pairs(project_files) do
        local global_content = string.format("    [\"%s\"] = {\n", string.gsub(filepath, "\\", "\\\\"))
        global_content = global_content .. string.format("        modify_time = %d,\n", global_data.modify_time)

        if global_data.module_metatable ~= nil then
            global_content = global_content .. string.format("        module_metatable = \"%s\",\n", global_data.module_metatable)
        end

        local normal_global = globals2string(global_data, "normal_global", temp_contents)
        if normal_global then
            global_content = global_content .. normal_global
        end
        
        local custom_global = globals2string(global_data, "custom_global", temp_contents)
        if custom_global then
            global_content = global_content .. custom_global
        end

        local module_var_define = module2string(global_data, temp_contents)
        if module_var_define then
            global_content = global_content .. module_var_define
        end

        global_content = global_content .. "    },\n"
        table.insert(global_contents, global_content)
    end

    if not next(global_contents) then return "{}" end

    return string.format("{\n%s}", table.concat(global_contents, ""))
end

local function save_project_global_cache(cache_filepath, need_save)
    if not need_save then return end

    local file_handle = io.open(cache_filepath, "w")
    if file_handle == nil then return end

    file_handle:write("return " .. table2string(project_files))
    file_handle:close()
end

function project.init(project_dir, top_opts)
    local abs_project_dir = fs.normalize(fs.join(fs.get_current_dir(), project_dir))
    local cache_filepath = fs.join(abs_project_dir, project_global_cache_filename)
    try_init_project_files(cache_filepath)
    local need_save = scan_project_global(abs_project_dir, top_opts)
    save_project_global_cache(cache_filepath, need_save)
end

function project.init_project(project_dir, top_opts)
    local abs_project_dir = fs.normalize(fs.join(fs.get_current_dir(), project_dir))
    local cache_filepath = fs.join(abs_project_dir, project_global_cache_filename)
    scan_project_global(abs_project_dir, top_opts, true)
    save_project_global_cache(cache_filepath, true)
    print("init project global cache file done!")
end

function project.get_module_define_line(filepath, var_name)
    if filepath == nil then return end
    local project_data = project_files[filepath]
    if project_data == nil then return end
    local module_var_define = project_data.module_var_define
    if module_var_define == nil then return end

    return module_var_define[var_name]
end

function project.get_self_global_data(filepath)
    return project_files[filepath]
end

function project.get_global_data(global_name)
    return project_global[global_name]
end

return project
