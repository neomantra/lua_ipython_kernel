--[[
  IPyLua
  
  Copyright (c) 2015 Francisco Zamora-Martinez.

  Released under the MIT License, see the LICENSE file.

  https://github.com/neomantra/lua_ipython_kernel

  usage: lua IPyLuaKernel.lua CONNECTION_FILENAME
--]]

-- This file is based on the work of Patrick Rapin, adapted by Reuben Thomas:
-- https://github.com/rrthomas/lua-rlcompleter/blob/master/rlcompleter.lua

local ok,lfs = pcall(require, "lfs") if not ok then lfs = nil end

local type = type

-- The list of Lua keywords
local keywords = {
  'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for',
  'function', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat',
  'return', 'then', 'true', 'until', 'while'
}

local word_break_chars_pattern = " \t\n\"\\'><=%;%:%+%-%*%/%%%^%~%#%{%}%(%)%[%]%.%,"
local last_word_pattern = ("[%s]?([^%s]*)$"):format(word_break_chars_pattern,
                                                    word_break_chars_pattern)
local endpos_pattern = ("(.*)[%s]?"):format(word_break_chars_pattern) 

-- Returns index_table field from a metatable, which is a copy of __index table
-- in APRIL-ANN
local function get_index(mt)
  if type(mt.__index) == "table" then return mt.__index end
  return mt.index_table -- only for APRIL-ANN
end

-- This function needs to be called to complete current input line
local function do_completion(line, cursor_pos, env_G, env)
  local line = line:match("([^\n]*)[\n]?$")
  -- Extract the last word.
  local word=line:match( last_word_pattern ) or ""
  local startpos,endpos=1,#(line:match(endpos_pattern) or "")
  
  -- Helper function registering possible completion words, verifying matches.
  local matches = {}
  local function add(value)
    value = tostring(value)
    if value:match("^" .. word) then
      matches[#matches + 1] = value
    end
  end
  
  -- This function does the same job as the default completion of readline,
  -- completing paths and filenames.
  local function filename_list(str)
    if lfs then
      local path, name = str:match("(.*)[\\/]+(.*)")
      path = (path or ".") .. "/"
      name = name or str
      for f in lfs.dir(path) do
        if (lfs.attributes(path .. f) or {}).mode == 'directory' then
          add(f .. "/")
        else
          add(f)
        end
      end
    end
  end
  
  -- This function is called in a context where a keyword or a global
  -- variable can be inserted. Local variables cannot be listed!
  local function add_globals()
    for _, k in ipairs(keywords) do
      add(k)
    end
    for k in pairs(env_G) do
      add(k)
    end
    for k in pairs(env) do
      add(k)
    end
  end

  -- Main completion function. It evaluates the current sub-expression
  -- to determine its type. Currently supports tables fields, global
  -- variables and function prototype completion.
  local function contextual_list(expr, sep, str)
    if str then
      return filename_list(str)
    end
    if expr and expr ~= "" then
      local v = load("return " .. expr, nil, nil, env)
      if v then
        v = v()
        local t = type(v)
        if sep == '.' or sep == ':' then
          if t == 'table' then
            for k, v in pairs(v) do
              if type(k) == 'string' and (sep ~= ':' or type(v) == "function") then
                add(k)
              end
            end
          end
          if (t == 'string' or t == 'table' or t == 'userdata') and getmetatable(v) then
            local aux = v
            repeat
              local mt = getmetatable(aux)
              local idx = get_index(mt)
              if idx and type(idx) == 'table' then
                for k,v in pairs(idx) do
                  add(k)
                end
              end
              if rawequal(aux,idx) then break end -- avoid infinite loops
              aux = idx
            until not aux or not getmetatable(aux)
          end
        elseif sep == '[' then
          if t == 'table' then
            for k in pairs(v) do
              if type(k) == 'number' then
                add(k .. "]")
              end
            end
            if word ~= "" then add_globals() end
          end
        end
      end
    end
    if #matches == 0 then
      add_globals()
    end
  end
  
  -- This complex function tries to simplify the input line, by removing
  -- literal strings, full table constructors and balanced groups of
  -- parentheses. Returns the sub-expression preceding the word, the
  -- separator item ( '.', ':', '[', '(' ) and the current string in case
  -- of an unfinished string literal.
  local function simplify_expression(expr)
    -- Replace annoying sequences \' and \" inside literal strings
    expr = expr:gsub("\\(['\"])", function (c)
                       return string.format("\\%03d", string.byte(c))
    end)
    local curstring
    -- Remove (finished and unfinished) literal strings
    while true do
      local idx1, _, equals = expr:find("%[(=*)%[")
      local idx2, _, sign = expr:find("(['\"])")
      if idx1 == nil and idx2 == nil then
        break
      end
      local idx, startpat, endpat
      if (idx1 or math.huge) < (idx2 or math.huge) then
        idx, startpat, endpat = idx1, "%[" .. equals .. "%[", "%]" .. equals .. "%]"
      else
        idx, startpat, endpat = idx2, sign, sign
      end
      if expr:sub(idx):find("^" .. startpat .. ".-" .. endpat) then
        expr = expr:gsub(startpat .. "(.-)" .. endpat, " STRING ")
      else
        expr = expr:gsub(startpat .. "(.*)", function (str)
                           curstring = str
                           return "(CURSTRING "
        end)
      end
    end
    expr = expr:gsub("%b()"," PAREN ") -- Remove groups of parentheses
    expr = expr:gsub("%b{}"," TABLE ") -- Remove table constructors
    -- Avoid two consecutive words without operator
    expr = expr:gsub("(%w)%s+(%w)","%1|%2")
    expr = expr:gsub("%s+", "") -- Remove now useless spaces
    -- This main regular expression looks for table indexes and function calls.
    return curstring, expr:match("([%.%w%[%]_]-)([:%.%[%(])" .. word .. "$")
  end

  -- Now call the processing functions and return the list of results.
  local str, expr, sep = simplify_expression(line:sub(1, endpos))
  contextual_list(expr, sep, str)
  table.sort(matches)
  return {
    status = "ok",
    matches = matches,
    cursor_start = 1,
    cursor_end = cursor_pos,
    matched_text = word,
    metadata = {},
  }
end

return {
  do_completion = do_completion,
}
