local fs = require "luacheck.fs"
local utils = require "luacheck.utils"
local parser = require "luacheck.parser"
local decoder = require "luacheck.decoder"
local globbing = require "luacheck.globbing"
local check_state = require "luacheck.check_state"

local project_global = {}
local project_files = {}
local project_exist_files = {}
local project_global_cache_filename = ".luacheckpg"

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

    if global_define and exist_project_global.custom_global == nil then return true end

    return exist_project_global.modify_time < modify_time
end

local function try_parse_source(filepath)
    local source = utils.read_file(filepath)
    if source == nil then return end

   local chstate = check_state.new(source)
   chstate.source = decoder.decode(chstate.source_bytes)
   chstate.line_offsets = {}
   chstate.line_lengths = {}
   local ast, comments, code_lines, line_endings, useless_semicolons = parser.parse(
      chstate.source, chstate.line_offsets, chstate.line_lengths)
   chstate.ast = ast
   chstate.comments = comments
   chstate.code_lines = code_lines
   chstate.line_endings = line_endings
   chstate.useless_semicolons = useless_semicolons

   return chstate
end

local function add_global(global, global_name, global_type)
    if global[global_name] == nil then
        global[global_name] = global_type
    end
end

local global_parse_handles = {}

global_parse_handles["Local"] = function(local_block, is_local_env, normal_global, custom_global, global_define)
    if global_define == nil then return end
    local value_node = local_block[2]
    if value_node == nil then return end

    for block_index, block in ipairs(value_node) do
        if block.tag == "Call" or block.tag == "Table" then
            global_parse_handles[block.tag](block, true, normal_global, custom_global, global_define)
        end
    end
end

global_parse_handles["Call"] = function(call_block, is_local_env, normal_global, custom_global, global_define)
    if global_define == nil then return end
    local function_name_node = call_block[1]
    if function_name_node == nil or function_name_node.tag ~= "Id" then return end

    local function_name = function_name_node[1]
    local arg_index = global_define[function_name]
    if arg_index == nil then return end

    local arg_node = call_block[arg_index + 1]
    if arg_node == nil or arg_node.tag ~= "String" then return end
    add_global(custom_global, arg_node[1], function_name)
end

global_parse_handles["Return"] = function(return_block, is_local_env, normal_global, custom_global, global_define)
    if global_define == nil then return end
    for block_index, block in ipairs(return_block) do
        if block.tag == "Call" or block.tag == "Table" then
            global_parse_handles[block.tag](block, true, normal_global, custom_global, global_define)
        end
    end
end

local global_types = { ["_G"] = true, ["_ENV"] = true, }

local function try_parse_normal_global_index_data(set_block, normal_global)
    local var_define_block = set_block[1]
    if #var_define_block ~= 1 then return false end

    var_define_block = var_define_block[1]
    if var_define_block.tag ~= "Index" or #var_define_block ~= 2 then return false end

    local global_type_node = var_define_block[1]
    local global_type = global_type_node[1]
    if global_type_node.tag ~= "Id" and global_types[global_type] == nil then return false end

    add_global(normal_global, var_define_block[2][1], global_type)

    local value_block = set_block[2]
    if value_block ~= nil then
        for _, block in ipairs(value_block) do
            if block.tag == "Function" or block.tag == "Table" then
                global_parse_handles[block.tag](block, true, normal_global, custom_global, global_define)
            end
        end
    end
    
    return true
end

local function try_parse_normal_global_data(var_block, value_block, is_local_env, normal_global, custom_global, global_define)
    if value_block == nil or value_block.tag == "Nil" then return end

    if not is_local_env then
        add_global(normal_global, var_block[1], "_ENV")
    end

    if value_block.tag == "Function" or value_block.tag == "Table" then
        global_parse_handles[value_block.tag](value_block, true, normal_global, custom_global, global_define)
        return
    end
end

global_parse_handles["Set"] = function(set_block, is_local_env, normal_global, custom_global, global_define)
    -- check function _G.xxx() end / function _ENV.xxx() end
    if try_parse_normal_global_index_data(set_block, normal_global) then
        return
    end

    local var_define_block = set_block[1]
    local value_block = set_block[2]
    for index, var_node in ipairs(var_define_block) do
        try_parse_normal_global_data(var_node, value_block[index], is_local_env, normal_global, custom_global, global_define)
    end
end

global_parse_handles["Function"] = function(function_block, is_local_env, normal_global, custom_global, global_define)
    local function_body_block = function_block[2]
    for _, block in ipairs(function_body_block) do
        local global_parse_handle = global_parse_handles[block.tag]
        if global_parse_handle ~= nil then
            global_parse_handle(block, true, normal_global, custom_global, global_define)
        end
    end
end

global_parse_handles["Table"] = function(table_block, is_local_env, normal_global, custom_global, global_define)
    for _, item_block in ipairs(table_block) do
        local global_parse_handle = global_parse_handles[item_block.tag]
        if global_parse_handle ~= nil then
            global_parse_handle(item_block, true, normal_global, custom_global, global_define)
        end
    end
end

global_parse_handles["Pair"] = function(pair_block, is_local_env, normal_global, custom_global, global_define)
    local key_block = pair_block[1]
    local global_parse_handle = global_parse_handles[key_block.tag]
    if global_parse_handle ~= nil then
        global_parse_handle(key_block, true, normal_global, custom_global, global_define)
    end

    local value_block = pair_block[2]
    global_parse_handle = global_parse_handles[value_block.tag]
    if global_parse_handle ~= nil then
        global_parse_handle(value_block, true, normal_global, custom_global, global_define)
    end
end

global_parse_handles["Localrec"] = function(localrec_block, is_local_env, normal_global, custom_global, global_define)
    local value_block = localrec_block[2]
    if value_block == nil then return end

    for _, block in ipairs(value_block) do
        local global_parse_handle = global_parse_handles[block.tag]
        if global_parse_handle ~= nil then
            global_parse_handle(block, true, normal_global, custom_global, global_define)
        end
    end
end

local function check_is_local_env(block)
    if block.tag ~= "Local" then return false end
    local var_name_node = block[1]
    if #var_name_node ~= 1 then return false end

    var_name_node = var_name_node[1]
    if var_name_node.tag ~= "Id" then return false end

    local var_name = var_name_node[1]

    return var_name == "_ENV" or var_name == "_G"
end

local function try_match_project_file_global(filepath, global_define)
    local modify_time = fs.get_mtime(filepath)
    project_exist_files[filepath] = modify_time
    local exist_project_global = project_files[filepath]
    if not need_do_match(exist_project_global, modify_time, global_define) then return end

    exist_project_global = exist_project_global or {}
    exist_project_global.modify_time = modify_time
    project_files[filepath] = exist_project_global

    local ok, chstate = utils.try(try_parse_source, filepath)
    if not ok or chstate == nil then return end

    local normal_global = {}
    local custom_global = {}

    local is_local_env = false

    for block_index, block in ipairs(chstate.ast) do
        if not is_local_env then
            is_local_env = check_is_local_env(block)
        end
        local global_parse_handle = global_parse_handles[block.tag]
        if global_parse_handle ~= nil then
            global_parse_handle(block, is_local_env, normal_global, custom_global, global_define)
        end
    end

    if not next(normal_global) then
        normal_global = nil
    end

    if not next(custom_global) then
        custom_global = nil
    end

    exist_project_global.normal_global = normal_global
    exist_project_global.custom_global = custom_global
end

local function merge_and_clean_project_global()
    for filepath, global_data in pairs(project_files) do
        if project_exist_files[filepath] == nil then
            project_files[filepath] = nil
        else
            if global_data.normal_global then
                for global_name, type in pairs(global_data.normal_global) do
                    if project_global[global_name] == nil then
                        project_global[global_name] = type
                    end
                end
            end

            if global_data.custom_global then
                for global_name, type in pairs(global_data.custom_global) do
                    if project_global[global_name] == nil then
                        project_global[global_name] = type
                    end
                end
            end
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

local function scan_project_global(abs_project_dir, top_opts)
    local lua_files = fs.extract_files(abs_project_dir, ".*%.lua$")
    local global_define = top_opts.global_define
    for _, lua_filepath in ipairs(lua_files) do
        if is_filename_included(top_opts, lua_filepath) then
            try_match_project_file_global(lua_filepath, global_define)
        end
    end

    merge_and_clean_project_global()
end

local function clear_table(t)
    if t == nil or not next(t) then return t end

    for k in pairs(t) do
        t[k] = nil
    end
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

local function table2string(t)
    if t == nil or not next(t) then return "{}" end

    local global_contents = {}
    local custom_global_contents = {}

    for filepath, global_data in utils.sorted_pairs(project_files) do
        local global_content = string.format("    [\"%s\"] = {\n", filepath)
        global_content = global_content .. string.format("        modify_time = %d,\n", global_data.modify_time)
        
        local normal_global = globals2string(global_data, "normal_global", custom_global_contents)
        if normal_global then
            global_content = global_content .. normal_global
        end
        
        local custom_global = globals2string(global_data, "custom_global", custom_global_contents)
        if custom_global then
            global_content = global_content .. custom_global
        end

        global_content = global_content .. "    },\n"
        table.insert(global_contents, global_content)
    end

    if not next(global_contents) then return "{}" end

    return string.format("{\n%s}", table.concat(global_contents, ""))
end

local function save_project_global_cache(cache_filepath)
    local file_handle = io.open(cache_filepath, "w")
    if file_handle == nil then return end

    file_handle:write("return " .. table2string(project_files))
    file_handle:close()
end

function project.init(project_dir, top_opts)
    local abs_project_dir = fs.normalize(fs.join(fs.get_current_dir(), project_dir))
    local cache_filepath = fs.join(abs_project_dir, project_global_cache_filename)
    try_init_project_files(cache_filepath)
    scan_project_global(abs_project_dir, top_opts)
    save_project_global_cache(cache_filepath)
end

function project.get_global_data(global_name)
    return project_global[global_name]
end

return project