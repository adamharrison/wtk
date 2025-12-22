local wtk = require "wtk"
local system = wtk.system
local json = require "wtk.json"



--[[
The following strings should be translated int he following actions

.products

  Derefrence products in a hash, and return the value.

.products[]

  Derference products in a hash, assume array, and splat it.

.products[1]

  Dereference products in a hash, and return the first element.

.products[1,2]

  Dereference products in a hash, and return the second and third element.

.products[1:10]

  Dereference products in a hash, and return elements 2 - 10.

.products[1:-1]

  Dereference products in a hash, and return elements 2 until the last one.

.products[].id

  Dereference products in a hash, splat the array, and then on each element, dereference id.

.products.id

  Dereference products in a hash, implied splat if in an array.

.products(.[0])'

  Modifies products to only include the first product.

.products(.[0].variants(.[0]))))'

  Modifies products to only include the first product, which only includes the first variant.

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


range = {}
local function translate_range(str)
  local colon = find_next(str, 1, ":")
  if colon then
    return "setmetatable({" .. str:sub(1, colon - 1) .. "," ..  str:sub(colon+1) .. "}, range)"
  elseif find_next(str, 1, ",") then
    return "{" .. str .. "}"
  else
    return str
  end
end

local function translate_function(str, wrap)
  
  local s, e, arrow = str:find("^%((.-)%)%s*=>%s*")
  local chunk
  local op = nil
  if arrow then
    return "function (" .. arrow .. ") return " .. translate_function(str:sub(e + 1)) .. " end"
  elseif str:find("^function") then
    return str
  else
    local i, s, e = 1
    i = str:find("%S") or 1
    local final_function = nil
    while i <= #str do
      if str:sub(i, i) == "." then
        local ns, ne, word, mod = str:find("^([%w_]*)(%(?)", i + 1)
        if ns then 
          if mod and #mod > 0 then
            local lambda_end = find_next(str, ne, "%)")
            local func = str:sub(ne + 1, lambda_end - 1)
            final_function = "mod(" .. json.encode(word) .. ", "  ..  translate_function(func, true) .. ", " .. (final_function or "a") .. ")"
            i = lambda_end + 1
          elseif word then
            if #word > 0 then
              final_function = "deref(" .. json.encode(word) .. ", " .. (final_function or "a") .. ")"
            else
              final_function = final_function or "a"
            end
            i = ne + 1
          end
        end
      elseif str:sub(i, i) == ":" then
        local ns, ne, word = str:find("(%w+)%(", i + 1)
        local lambda_end = assert(find_next(str, ne, "%)"), "can't find the end of function '" .. word .. "'")
        local func = str:sub(ne + 1, lambda_end - 1)
        if func:find("%S") then
          if word == "map" or word == "select" then
            assert(#func > 0, "requires a callback body for '" .. word .. "'")
            final_function = "call(\"" .. word .. "\", " .. translate_function(func, true) .. "," .. (final_function or "a") .. ")"
          else
            final_function = "call(\"" .. word .. "\", " .. func .. ", " .. (final_function or "a")  .. ")"
          end
        else
          assert(word ~= "select" and word ~= "map", "requires a callback body for '" .. word .. "'")
          final_function = "call(\"" .. word .. "\", " .. (final_function or "a") .. ")"
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
            final_function = "splat(" ..  translate_range(range_contents) .. ", " .. (final_function or "a") .. ")"
          else
            final_function = "splat(nil, " .. (final_function or "a") .. ")"
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

function mod(key, callback_function, ...)
  for k, a in ipairs({ ... }) do
    if is_array(a) then
      for i, v in ipairs(a) do
        a[i][key] = mod(key, callback_function, v)
      end
    else
      a[key] = callback_function(a[key])
    end
  end
  return ...
end

function deref(key, ...)  
  local t = {}
  for i, a in ipairs({ ... }) do
    if not a then return nil end
    if is_array(a) then
      local r = {}
      for _, v in ipairs(a) do
        table.insert(r, deref(key, v))
      end
      table.insert(t, r)
    else
      table.insert(t, a[key])
    end
  end
  return table.unpack(t)
end

local old_select = select
function splat(range, ...)
  local result = {}
  for _, a in ipairs({ ... }) do
    if type(range) == 'table' and getmetatable(range) == range then
      local t = {}
      if not a then return t end
      if range[1] < 0 then range[1] = #a + range[1] end
      if range[2] < 0 then range[2] = #a + range[2] end
      for i = range[1] + 1, range[2] do
        table.insert(t, a[i + 1])
      end
      result[#result + 1] = t
    elseif type(range) == 'table' then
      local t = {}
      if not a then return t end
      for i, v in ipairs(range) do
        if v < 0 then v = #a + v end
        table.insert(t, a[v + 1])
      end
      result[#result + 1] = t
    elseif type(range) == 'number' then 
      if not a then return nil end
      if range < 0 then range = #a + range end
      result[#result + 1] = a[range + 1]
    else
      table.move(a, 1, #a, #result + 1, result)
    end
  end
  return table.unpack(result)
end

function delete(key, ...)
  for _, a in pairs({ ... }) do
    if is_array(a) then
      for i, v in ipairs(a) do
        v[key] = nil
      end
    else
      a[key] = nil
    end
  end
  return ...
end

function sort(callback_function, ...)
  table.sort(callback_function, ...)
  for _, a in { ... } do
    table.sort(callback_function, a)
  end
  return ...
end

function select(callback_function, ...)
  local t = {}
  for _, a in ipairs({ ... }) do
    if is_array(a) then
      local r = {}
      for i, v in ipairs(a) do
        if callback_function(v, i) then 
          table.insert(r, v) 
        end
      end
      if #r > 0 then
        table.insert(t, r)
      end
    else
      if callback_function(a, 1) then 
        table.insert(t, a) 
      end
    end
  end
  return table.unpack(t)
end

function map(callback_function, ...)
  local t = {}
  for _, a in ipairs({ ... }) do
    if is_array(a) then
      local r = {}
      for i, v in ipairs(a) do
        table.insert(r, map(callback_function, v))
      end
      table.insert(t, r)
    else
      table.insert(t, callback_function(a))
    end
  end
  return table.unpack(t)
end


function call(method, self, ...)
  if _G[method] then
    return _G[method](self, ...)
  elseif type(self) == 'table' and self[method] then
    return self:method(...)
  elseif type(self) == 'string' and self[method] then
    return self[method](..., self)
  else
    error("unknown function " .. method)
  end
end

local args = wtk.pargs({ ... }, { 
  compress = "flag", 
  help = "flag",
  debug = "flag",
  slurp = "flag",
  tabs = "flag",
  indent = "number",
  unbuffered = "flag",
  version = "flag",
  ["from-file"] = "string",
  ["sort-keys"] = "flag",
  ["monochrome-output"] = "flag",
  ["colorize-output"] = "flag",
  ["raw-input"] = "flag",
  ["raw-output"] = "flag",
  ["raw-output0"] = "flag",
  ["join-output"] = "flag"
}, {
  C = "compres",
  S = "sort-keys", 
  s = "slurp",
  h = "help",
  f = "from-file",
  r = "raw-output",
  M = "monochrome-output",
  C = "colorize-output",
  V = "version"
})
local filter = (args[1] or '.')
if args["from-file"] then filter = assert(io.open(args["from-file"], "rb")):read("*all") end
local target = "return function(a) return " .. translate_function((args[1] or '.')) .. " end"
if args.debug then
  io.stderr:write(target)
  os.exit(0)
end
if args.help or system.isatty(0) then
  io.stderr:write([[
wtkjq - A replacement for jq, with more sensible ergnomics and lua accessibility.

Reads from stdin, and outputs to stdout.

The following options are available:

  -n, --null-input          use `null` as the single input value;
  -R, --raw-input           read each line as string instead of JSON;
  -s, --slurp               read all inputs into an array and use it as
                            the single input value;
  -c, --compact-output      compact instead of pretty-printed output;
  -r, --raw-output          output strings without escapes and quotes;
      --raw-output0         implies -r and output NUL after each output;
  -j, --join-output         implies -r and output without newline after
                            each output;
  -a, --ascii-output        output strings by only ASCII characters
                            using escape sequences;
  -S, --sort-keys           sort keys of each object on output;
  -C, --color-output        colorize JSON output;
  -M, --monochrome-output   disable colored output;
      --tab                 use tabs for indentation;
      --indent n            use n spaces for indentation
      --unbuffered          flush output stream after each output
  -f, --from-file file      load filter from the file
  -V, --version             show the version
  -h, --help                show the help
]])
  os.exit(0)
elseif args.version then
  io.stdout:write(VERSION)
  os.exit(0)
end

if args["raw-output0"] then args["raw-output"] = true end

local spacing = tabs and "\t" or string.rep(' ', args.indent or 2)

local colorize
local output_stream = io.stdout
if args["colorize-output"] or (system.isatty(1) and not args['monochrome-output'] and (os.getenv("TERM") and os.getenv("TERM") ~= "dumb")) then
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
    if args["raw-output"] then
      output_stream:write(value)
    else
      output_stream:write(json.encode(value))
    end
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
  if args.unbuffered then
    output_stream:flush()
  end
end

local pretty = not args.compress

local function print_value(value)
  if type(value) ~= "table" then 
    write(value)
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
            output_stream:write(string.rep(spacing, #stack))
          end
          s[2] = i + 1
          if type(v) == 'table' then
            if #v == 0 and is_array(v) then
              colorize("white")
              output_stream:write('[]')
            else
              table.insert(stack, { v })
              goto start
            end
          else
            write(v)
          end
        end
        if not s[2] or s[2] > #s[1] then 
          colorize("white")
          table.remove(stack)
          if pretty then
            output_stream:write('\n')
            output_stream:write(string.rep(spacing, #stack))
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
          if args["sort-keys"] then
            table.sort(s[3])
          end
          output_stream:write('{')
          if pretty then
            output_stream:write("\n")
          end
          key = s[3][1]
          index = 1
        else
          if args["sort-keys"] then
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
            output_stream:write(string.rep(spacing, #stack))
          end
          output_stream:write(json.encode(key))
          colorize("white")
          output_stream:write(":")
          if pretty then
            output_stream:write(" ")
          end
          if type(v) == 'table' then
            if #v == 0 and is_array(v) then
              colorize("white")
              output_stream:write('[]')
            else
              table.insert(stack, { v })
              if args["sort-keys"] then
                s[2] = index
              else
                s[2] = key
              end
              break
            end
          else
            write(v)
          end
          if args["sort-keys"] then
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
            output_stream:write(string.rep(spacing, #stack))
          end
          output_stream:write('}')
        end
      end
    end
  end
end

xpcall(function() 
  local filter_function = assert(load(target))()
  local t
  if args.slurp then
    for line in io.stdin.lines() do
      table.insert(t, json.decode(line))
    end
  elseif args["raw-input"] then
    for line in io.stdin.lines() do
      table.insert(t, line)
    end
  else
    t = json.decode(io.stdin:read("*all"))
  end
  t = { filter_function(t) }
  for i,v in ipairs(t) do
    print_value(v)
    if not args['join-output'] then
      if args['raw-output0'] then
        output_stream:write("\0")
      else
        output_stream:write("\n")
      end
    end
  end
  colorize("normal")
end, function(err)
  io.stderr:write(debug.traceback(err, 2))
end)
os.exit(0) -- don't bother cleaning up cleanly
