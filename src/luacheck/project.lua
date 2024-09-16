local fs = require "luacheck.fs"
local utils = require "luacheck.utils"

local project_global = {}
local project_files = {}
local project_exist_files = {}
local default_global_pattern = { ["%s+_G%.([_%w]+)%s*"] = "_G", ["^_G%.([_%w]+)%s*"] = "_G", ["%s+_ENV%.([_%w]+)%s*"] = "_ENV", ["^_ENV%.([_%w]+)%s*"] = "_ENV", }
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

local function need_do_match(exist_project_global, modify_time, global_pattern)
    if exist_project_global == nil then return true end

    if global_pattern and exist_project_global.custom_global == nil then return true end

    return exist_project_global.modify_time < modify_time
end

local function try_match_project_file_global(filepath, global_pattern)
    local modify_time = fs.get_mtime(filepath)
    project_exist_files[filepath] = modify_time
    local exist_project_global = project_files[filepath]
    if not need_do_match(exist_project_global, modify_time, global_pattern) then return end

    exist_project_global = exist_project_global or {}
    exist_project_global.modify_time = modify_time
    project_files[filepath] = exist_project_global

    local file_handle = io.open(filepath, "r")
    if file_handle == nil then return end

    local normal_global = {}
    local custom_global = {}

    for line in file_handle:lines() do
        for normal_pattern, type in pairs(default_global_pattern) do
            local match_global = string.match(line, normal_pattern)
            if match_global ~= nil and normal_global[match_global] == nil then
                normal_global[match_global] = type
            end
        end

        if global_pattern then
            for custom_pattern, type in pairs(global_pattern) do
                local match_global = string.match(line, custom_pattern)
                if match_global ~= nil and custom_global[match_global] == nil then
                    custom_global[match_global] = type
                end
            end
        end
    end
    file_handle:close()

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

local function scan_project_global(abs_project_dir, global_pattern)
    local lua_files = fs.extract_files(abs_project_dir, ".*%.lua$")
    for _, lua_filepath in ipairs(lua_files) do
        try_match_project_file_global(lua_filepath, global_pattern)
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

function project.init(project_dir, global_pattern)
    local abs_project_dir = fs.normalize(fs.join(fs.get_current_dir(), project_dir))
    local cache_filepath = fs.join(abs_project_dir, project_global_cache_filename)
    try_init_project_files(cache_filepath)
    scan_project_global(abs_project_dir, global_pattern)
    save_project_global_cache(cache_filepath)
end

function project.get_global_data(global_name)
    return project_global[global_name]
end

return project