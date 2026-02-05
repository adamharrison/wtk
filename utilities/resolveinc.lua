#!/usr/bin/env lua5.4
-- Use on onelua.c to compile it into a single file.
-- Primarily used to for wtk itself.

local verboten = { ["lua.h"] = 1, ["lualib.h"] = 1, ["lauxlib.h"] = 1 }
local processed = {}

local file = assert(..., "requires a file to be specified")

local function process_file(file, depth)
  local open = false
  local dir = file:match("^(.+)/")
  for line in io.lines(file) do
    line = line:gsub("/%*.-%*/", "")
    if open and line:find("^.-%*/") then
      line = line:gsub("^.-%*/", "")
      open = false
    end
    if not open and line:find("/%*") then 
      open = true
      line = line:gsub("/%*.*$", "")
      if line:find("%S") then print(line .. "\n") end
    end
    if not open then
      local include = line:match("^%s*#include%s+\"(%S+)\"")
      if not open and (include and not verboten[include]) and io.open(dir .. "/" .. include) then 
        if not processed[include] then
          processed[include] = true
          process_file(dir .. "/" .. include, depth + 1)
        end
      elseif line:find("%S") then
        print(line)
      end
    end
  end
end

if file:match("onelua%.c") then
  print("#define MAKE_LIB")
elseif file:match("lua%.h") then
  print("#define LUA_CORE\n#define LUA_LIB\n#define ltable_c\n#define lvm_c\n#define WTK_BUNDLED_LUA")
end
process_file(file, 0);
