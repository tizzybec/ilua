-- ILua
-- Copyright (C) 2018  guysv

-- This file is part of ILua which is released under GPLv2.
-- See file LICENSE or go to https://www.gnu.org/licenses/gpl-2.0.txt
-- for full license details.

local cmd_pipe_path = assert(os.getenv("ILUA_CMD_PATH"))
local ret_pipe_path = assert(os.getenv("ILUA_RET_PATH"))
local lib_path = assert(os.getenv("ILUA_LIB_PATH"))

-- Windows supports / as dirsep
local netstring = assert(dofile(lib_path .. "/netstring.lua/netstring.lua"))
local json = assert(dofile(lib_path .. "/json.lua/json.lua"))
local inspect = assert(dofile(lib_path .. "/inspect.lua/inspect.lua"))

-- Compatibility setup
table.pack = table.pack or function (...)
    return {n=select('#',...); ...}
end
table.unpack = table.unpack or unpack

local load_compat

if setfenv then
    function load_compat(code, env)
        loaded, err = loadstring(code, "=(ilua)")
        if not loaded then
            return nil, err
        end
        setfenv(loaded, env)
        return loaded, err
    end
else
    function load_compat(code, env)
        return load(code, "=(ilua)", "t", env)
    end
end

-- shell environment setup
local dynamic_env = {}
local global_env
if getfenv then
    global_env = getfenv(0)    
else
    global_env = _ENV
end
for key, val in pairs(global_env) do
    dynamic_env[key] = val
end

-- shell logic
local function load_chunk(code, env)
    local loaded, err = load_compat("return " .. code, env)
    if not loaded then
        loaded, err = load_compat(code, env)
        if not loaded then
            return nil, err
        end
    end
    return loaded, err
end

local function handle_execute(code)
    local loaded, err = load_chunk(code, dynamic_env)
    if not loaded then
        return nil, err
    end
    outcome = table.pack(xpcall(loaded, debug.traceback))
    success = outcome[1]
    if not success then
        return nil, outcome[2]
    end
    local returned = table.pack(select(2, table.unpack(outcome, 1, outcome.n)))
    if returned.n > 0 then
        dynamic_env['_'] = function()
            return table.unpack(returned, 1, returned.n)
        end
    else
        dynamic_env['_'] = function()
            return nil
        end
    end
    return success, returned
end

local function handle_is_complete(code)
    local loaded, err = load_chunk(code, dynamic_env)
    if loaded then
        return 'complete'
    elseif string.sub(err, -#("<eof>")) == "<eof>" then
        return 'incomplete'
    else
        return 'invalid'
    end
end

local function get_metatable_matches(obj, matches, methods_only)
    local mt = getmetatable(obj)
    if not mt or not mt.__index or type(mt.__index) == "function" then
        return
    end
    for key, value in pairs(mt.__index) do
        if type(key) == 'string' and
                key:match("^[_a-zA-Z][_a-zA-Z0-9]*$") and
                (not methods_only or type(value) == 'function') then
            matches[#matches+1] = key
        end
    end
    get_metatable_matches(mt, matches, methods_only)
end

local function handle_complete(subject, methods_only)
    local matches = {}
    local subject_obj = nil
    if subject == "" then
        subject_obj = dynamic_env
    else
        subject_obj = dynamic_env[subject]
    end
    if subject_obj == nil then
        return matches
    end
    if type(subject_obj) == 'table' then
        for key, value in pairs(subject_obj) do
            if type(key) == 'string' and
                    key:match("^[_a-zA-Z][_a-zA-Z0-9]*$") and
                    (not methods_only or type(value) == 'function') then
                matches[#matches+1] = key
            end
        end
    end
    get_metatable_matches(subject_obj, matches, methods_only)
    return matches
end

local cmd_pipe = assert(io.open(cmd_pipe_path, "rb"))
local ret_pipe = assert(io.open(ret_pipe_path, "wb"))

while true do
    local message = json.decode(netstring.read(cmd_pipe))
    if message.type == "echo" then
        netstring.write(ret_pipe, json.encode(message))
    elseif message.type == "execute" then
        local success, ret_val = handle_execute(message.payload)
        if not success then
            success = false
        end
        if success then
            local tmp = {}
            for i=1, ret_val.n do
                tmp[i] = inspect(ret_val[i], {newline="", indent=""})
            end
            ret_val = table.concat(tmp, "\t")
        end
        netstring.write(ret_pipe, json.encode({
            type = "execute",
            payload = {
                success = success,
                returned = ret_val
            }
        }))
    elseif message.type == "is_complete" then
        local status = handle_is_complete(message.payload)
        netstring.write(ret_pipe, json.encode({
            type = "is_complete",
            payload = status
        }))
    elseif message.type == 'complete' then
        local matches = handle_complete(message.payload.subject,
                                        message.payload.methods)
        netstring.write(ret_pipe, json.encode({
            type = "complete",
            payload = matches
        }))
    else
        error("Unknown message type")
    end
    ret_pipe:flush()
end

cmd_pipe:close()
ret_pipe:close()
