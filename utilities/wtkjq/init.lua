local wtk = require "wtk"
local system = wtk.system
local json = require "wtk.json"



--[[
The following strings should be translated int he following actions

.products

  return deref(a, "products")

.products[]

  return deref(deref(a, "products"))

.products[1]

  return deref(deref(a, "products"), 1)

.products[1,2]

  return deref(deref(a, "products", {1,2}))

.products[1:10]

  return splat(deref(deref(a, "products"), range(1, 10)))

.products[1:-1]

  return splat(deref(deref(a, "products"), range(1, -1))

.products[].id

  return deref(deref(a, "products", true), "id")

.products:select(.id == 1234)

  return select(deref(a, "products"), function(a) return deref(a, "id") == 1234 end)


.products:select(.id == 1234):map([ .id, .handle ])

  return map(select(deref(a, "products"), function(a) return deref(a, "id") == 1234 end), function(a) return { a.id, a.handle } end)

.products:select(.id == 1234):map([ .id, .handle, .variants:select(.handle:find("wat")) ])

  return map(select(deref(a, "products"), function(a) return deref(a, "id") == 1234 end), function(a) return { a.id, a.handle, select(a.variants, function(a) return a.handle:find("wat") end) } end)

]]


local function find_next(str, offset, chr)
  local s = offset
  local open_quote = false
  local open_square_bracket = 0
  local open_parentheses = 0
  while offset <= #str do
    if open_quote then
      if str:sub(offset,offset) == open_quote then
        open_quote = false
      end
    elseif str:sub(offset,offset) == '"' or str:sub(offset,offset) == "'" then
      open_quote = str[offset]
    elseif str:sub(offset, offset) == "(" then
      open_parentheses = open_parentheses + 1
    elseif str:sub(offset, offset) == ")" then
      open_parentheses = open_parentheses - 1
    elseif str:sub(offset, offset) == "[" then
      open_square_bracket = open_square_bracket + 1
    elseif str:sub(offset, offset) == "]" then
      open_square_bracket = open_square_bracket - 1
    end
    if open_square_bracket == 0 and not open_quote and open_parentheses == 0 then
      local s, e = str:find("^" .. chr, offset)
      if s then
        return offset, e
      end
    end
    offset = offset + 1
  end
  return nil
end

local function contextual_split(str, delimiter)
  local t = {}
  local i = 1
  while i < #str do
    local s, e = find_next(str, i, delimiter)
    if s then
      table.insert(t, str:sub(i, s - 1))
      i = e + 1
    else
      table.insert(t, str:sub(i))
      break
    end
  end
  return t
end

local function translate_function(str, wrap)
  
  local s, e, arrow = str:find("^%((.-)%)%s*=>%s*")
  local chunk
  local op = nil
  if arrow then
    return "function (" .. arrow .. ") return " .. str:sub(e + 1) .. " end"
  elseif str:find("^function") then
    return str
  else
    local i, s, e = 1
    i = str:find("%S") or 1
    local final_function = nil
    while i <= #str do
      if str:sub(i, i) == "." then
        local ns, ne, word, range = str:find("([%w_]+)", i + 1)
        if not ns then 
          return final_function or "a"
        end
        if word then
          final_function = "deref(" .. json.encode(word) .. ", " .. (final_function or "a") .. ")"
          i = ne + 1
        end
      elseif str:sub(i, i) == ":" then
        local ns, ne, word = str:find("(%w+)%(", i + 1)
        local lambda_end = find_next(str, ne, "%)")
        local func = str:sub(ne + 1, lambda_end - 1)
        if func:find("%S") then
          final_function = word .. "(" .. (final_function or "a") .. ", " .. translate_function(func, true) .. ")"
        else
          final_function = word .. "(" .. (final_function or "a") .. ")"
        end
        i = lambda_end + 1
      elseif str:sub(i, i) == "[" then
        local square_end = find_next(str, i, "%]")
        if i == 1 then
          local parts = {}
          local elements = contextual_split(str:sub(i + 1, square_end - 1), ",")
          for i,v in ipairs(elements) do
            table.insert(parts, translate_function(v))
          end
          final_function = "{" .. table.concat(parts, ", ") .. "}"
        else
          local range_contents = str:sub(i + 1, square_end - 1)
          if #range_contents > 0 then
            final_function = "splat(" .. (final_function or "a") .. ", " ..  range_contents .. ")"
          else
            final_function = "splat(" .. (final_function or "a") .. ")"
          end
        end
        i = square_end + 1
      else
        final_function = (final_function or "") .. str:sub(i,i)
        i = i + 1
      end
    end
    if wrap then
      return "function(a) return " .. (final_function or "a") .. " end"
    end
    return final_function
  end
end

local function is_array(a)
  return type(a) == 'table' and (#a > 0 or (next(a) == nil and a ~= json.empty_object))
end

function deref(key, ...)  
  local t = {}
  for i, a in ipairs({ ... }) do
    if not a then return nil end
    if is_array(a) then
      table.insert(t, map(a, function(e) return e[key] end))
    else
      table.insert(t, a[key])
    end
  end
  return table.unpack(t)
end

function splat(a, range)
  if type(range) == 'number' then
    return a[range + 1]
  end
  return table.unpack(a)
end

function sort(a, callback_function)
  table.sort(a, callback_function)
  return a
end

function select(a, callback_function)
  local t = {}
  for i, v in ipairs(a) do
    if callback_function(v) then 
      table.insert(t, v) 
    end
  end
  return t
end

function map(a, callback_function)
  local t = {}
  for i, v in ipairs(a) do
    table.insert(t, callback_function(v))
  end
  return t
end

local args = wtk.pargs({ ... }, { 
  compressed = "flag", 
  canonical = "flag",
  C = "compressed",
  S = "canonical", 
  ["no-color"] = "flag" 
})
local target = "return function(a) return " .. translate_function((args[1] or '.')) .. " end"
print("TARGET", target)
local filter_function = assert(load(target))()
local t = json.decode(io.stdin:read("*all"))
t = { filter_function(t) }

local colorize
local output_stream = io.stdout
if system.isatty(1) and not args['no-color'] and (os.getenv("TERM") and os.getenv("TERM") ~= "dumb") then
  local last_color = nil
  local colors = {
    green = 32,
    blue = 94,
    normal = 0,
    white = 97,
    grey = 90
  }
  colorize = function(color)
    if last_color ~= color then
      last_color = color
      output_stream:write("\x1B[" .. colors[color] .. "m")
    end
  end
else
  colorize = function() end
end

local function write(value)
  local t = type(value)
  if t == 'string' then
    colorize("green")
    output_stream:write('"')
    output_stream:write(value)
    output_stream:write('"')
  elseif t == 'boolean' then
    colorize("normal")
    output_stream:write(tostring(value))
  elseif value == json.empty_object then
    colorize("white")
    output_stream:write('{}')
  elseif value == json.null or value == nil then
    colorize("grey")
    output_stream:write('null')
  elseif value == math.floor(value) then
    colorize("normal")
    output_stream:write(math.floor(value))
  else
    colorize("normal")
    output_stream:write(json.encode(tostring(value)))
  end
end

local pretty = not args.compressed

local function print_value(value)
  if type(value) ~= "table" then 
    write(value)
    output_stream:write("\n")
    return
  end
  local stack = { { value } }
  while #stack > 0 do 
    ::start::
    local depth = #stack - 1
    local s = stack[#stack]
    if type(s[1]) == 'table' then
      if #s[1] > 0 or (s[1] ~= json.empty_object and next(s[1]) == nil) then
        if s[2] == nil then
          colorize("white")
          output_stream:write('[')
          if pretty then
            output_stream:write("\n")
          end
        end
        for i = (s[2] or 1), #s[1] do
          local v = s[1][i]
          if i > 1 then 
            output_stream:write(",") 
            if pretty then
              output_stream:write("\n")
            end
          end
          if pretty then
            output_stream:write(string.rep("  ", #stack))
          end
          if type(v) == 'table' then
            table.insert(stack, { v })
            s[2] = i + 1
            goto start
          else
            write(v)
            s[2] = i + 1
          end
        end
        if not s[2] or s[2] > #s[1] then 
          colorize("white")
          table.remove(stack)
          if pretty then
            output_stream:write('\n')
            output_stream:write(string.rep("  ", #stack))
          end
          output_stream:write(']')
        end
      else
        local key, index
        if s[2] == nil then
          colorize("white")
          s[3] = {}
          for k in pairs(s[1]) do
            table.insert(s[3], k)
          end
          if args.canonical then
            table.sort(s[3])
          end
          output_stream:write('{')
          if pretty then
            output_stream:write("\n")
          end
          key = s[3][1]
          index = 1
        else
          if args.canonical then
            index = s[2] + 1
            key = s[3][index]
          else
            key = next(s[1], s[2])
          end
        end
        local canonical = s[3]
        while key ~= nil do
          if s[2] then 
            output_stream:write(',') 
            if pretty then
              output_stream:write("\n")
            end
          end
          local v = s[1][key]
          colorize("blue")
          if pretty then
            output_stream:write(string.rep("  ", #stack))
          end
          output_stream:write(json.encode(key))
          colorize("white")
          output_stream:write(":")
          if pretty then
            output_stream:write(" ")
          end
          if type(v) == 'table' then
            table.insert(stack, { v })
            if args.canonical then
              s[2] = index
            else
              s[2] = key
            end
            break
          else
            write(v)
          end
          if args.canonical then
            s[2] = index
            index = index + 1
            key = s[3][index]
          else
            s[2] = key
            key = next(s[1], key)
          end
        end
        if key == nil then 
          table.remove(stack) 
          colorize("white")
          if pretty then
            output_stream:write('\n')
            output_stream:write(string.rep("  ", #stack))
          end
          output_stream:write('}')
        end
      end
    end
  end
  output_stream:write("\n")
  colorize("normal")
end

for i,v in ipairs(t) do
  print_value(v)
end
os.exit(0) -- don't bother cleaning up cleanly
