local wtk = require "wtk.c"
local system = require "wtk.c.system"
local xml = require "wtk.xml"

local function is_array(a) return type(a) == 'table' and not a.children end
local function sorted_keys(a) local t = {} for k,v in pairs(a) do table.insert(t, k) end table.sort(t) return t end
local wtkjq_functions = {
  map = {
    args = { "function", "..." },
    func = function(callback_function, tag)
      local t = { children = {} }
      if type(tag) ~= 'table' then return t end
      for i,v in ipairs(tag.children) do
        table.insert(t.children, callback_function(v))
      end
      return t
    end
  },
  attr = {
    args = { "value", "..." },
    func = function(str, tags) 
      local t = {}
      if tags.tag and tags.props[str] then 
        table.insert(t, tags.props[str])
      end
      for _, v in ipairs(tags.children) do
        if type(v) == 'table' and v.props then
          table.insert(t, v.props[str])
        end
      end
      return { children = t }
    end
  }
}

local args = wtk.pargs({ ... }, { 
  compress = "flag", 
  help = "flag",
  debug = "flag",
  tabs = "flag",
  indent = "number",
  unbuffered = "flag",
  strip = "flag",
  pretty = "flag",
  version = "flag",
  ["no-format"] = "flag",
  strict = "flag",
  html = "flag",
  ["monochrome-output"] = "flag",
  ["colorize-output"] = "flag",
}, {
  c = "compress",
  h = "help",
  X = "no-format",
  M = "monochrome-output",
  C = "colorize-output",
  V = "version"
})
local filter = (args[1] or '.')
if args.debug then
  io.stderr:write(target .. "\n")
  os.exit(0)
end
if args.version then
  io.stdout:write(VERSION .. "\n")
  os.exit(0)
elseif args.help or system.isatty(0) then
  io.stderr:write([[
wtkxml - A replacement for xmllint, with more sensible ergnomics and lua accessibility.

Reads from stdin, and outputs to stdout.

The following options are available:

  -c, --compact-output      compact instead of prettifying
  -a, --ascii-output        output strings by only ASCII characters
                            using escape sequences;
  -C, --color-output        colorize XML output;
  -S, --strip               strip out all whitespace inside tags;
      --strict              follow strict XML parsing standards;
  -H, --html                treat incoming XML as HTML;
  -M, --monochrome-output   disable colored output;
  -X, --no-format           don't prettify the output at all;
      --tab                 use tabs for indentation;
      --indent n            use n spaces for indentation
      --unbuffered          flush output stream after each output
  -V, --version             show the version
  -h, --help                show the help
]])
  os.exit(0)
end

local spacing = (args['no-format'] or args['compress'] or args['strip']) and "" or (tabs and "\t" or string.rep(' ', args.indent or 2))
local newline = (args['no-format'] or args['compress'] or args['strip']) and "" or "\n"

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

local function write(value, color)
  if color then colorize(color) end
  output_stream:write(value)
  if args.unbuffered then
    output_stream:flush()
  end
end


function splat(range, node)
  local result = {}
  for _, v1 in ipairs(node.children) do
    if type(v1) == 'table' then
      for _, v2 in ipairs(v1.children) do
        result[#result + 1] = v2
      end
    end
  end
  return { children = result }
end


function mod(key, callback_function, ...)
  for k, a in ipairs({ ... }) do
    if is_array(a) then
      for i, v in ipairs(a.children) do
        a.children[i][key] = mod(key, callback_function, v)
      end
    else
      a.children[key] = callback_function(a[key])
    end
  end
  return ...
end

function deref(key, tag)  
  local t = { children = {} }
  if type(tag) ~= 'table' then return t end
  for _, a in ipairs(tag.children) do
    if type(a) == 'table' and a.tag == key then
      table.insert(t.children, a)
    end
  end
  return t
end

function call(method, self, ...)
  if wtkjq_functions[method] then
    return wtkjq_functions[method].func(self, ...)
  elseif type(self) == 'table' and self[method] then
    return self:method(...)
  elseif type(self) == 'string' and self[method] then
    return self[method](..., self)
  else
    error("unknown function " .. method)
  end
end


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
  while i <= #str do
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
    local si = str:find("%S") or 1
    i = si
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
              final_function = "deref(\"" .. word .. "\", " .. (final_function or "a") .. ")"
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
          local t = {}
          local info = assert(wtkjq_functions[word], "unknown function " .. word)
          for i, arg in ipairs(contextual_split(func, "%s*,%s*")) do
            if info.args[i] == 'function' then
              assert(#arg > 0, "requires a callback body for '" .. word .. "'")
              table.insert(t, translate_function(arg, true))
            else
              table.insert(t, arg)
            end
          end
          final_function = "call(\"" .. word .. "\", " .. table.concat(t, ", ") .. "," .. (final_function or "a") .. ")"
        else
          assert(word ~= "select" and word ~= "map", "requires a callback body for '" .. word .. "'")
          final_function = "call(\"" .. word .. "\", " .. (final_function or "a") .. ")"
        end
        i = lambda_end + 1
      elseif str:sub(i, i) == "[" then
        local square_end = find_next(str, i, "%]")
        if i == si then
          local parts = {}
          local elements = contextual_split(str:sub(i + 1, square_end - 1), ",")
          for i,v in ipairs(elements) do
            table.insert(parts, translate_function(v))
          end
          final_function = "{ children = { " .. table.concat(parts, ", ") .. " } }"
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


local function xml_print(doc, depth)
  if getmetatable(doc) == xml.dmt then
    local t = {}
    if doc.prolog then write(string.format('<?xml version="%s" encoding="%s"?>', doc.prolog.version, doc.prolog.encoding)) write(newline) end
    if doc.doctype then write(string.format('<!DOCTYPE %s>', doc.doctype.definition)) write(newline) end
    for i,v in ipairs(doc.children) do xml_print(v, depth) end
  else
    if type(doc) ~= 'table' then 
      if type(doc) == 'string' then
        if args.compress == "compress" then
          doc = doc:gsub("^%s+", " ")
          doc = doc:gsub("%s+$", " ")
        elseif args.strip or not args["no-format"] then
          doc = doc:gsub("^%s+", "")
          doc = doc:gsub("%s+$", "")
        end
      end
      write(string.rep(spacing, depth), "normal")
      write(doc)
    elseif doc.tag then
      write(string.rep(spacing, depth))
      write("<", "grey")
      write(doc.tag, "green")
      for _, k in ipairs(sorted_keys(doc.props)) do
        write(" " .. k, "white")
        if (doc.props[k] ~= true) then
          write("=\"", "grey")
          write(doc.props[k]:gsub("\\", "\\\\"):gsub('"', '\\"'), "blue")
        end
        write("\"", "grey")
      end
      if #doc.children == 0 then
        write("/>", "grey")
      else
        write(">", "grey")
        if not args['no-format'] and #doc.children == 1 and type(doc.children[1]) ~= "table" then
          write(doc.children[1], "normal")
        else
          for i,v in ipairs(doc.children) do
            if args['no-format'] or type(v) ~= 'string' or v:find("%S") then
              write(newline)
              xml_print(v, depth + 1)
            end
          end
          write(newline)
          write(string.rep(spacing, depth))
        end
        write("</", "grey")
        write(doc.tag, "green")
        write(">", "grey")
      end
    else
      for i,v in ipairs(doc.children) do
        if args['no-format'] or type(v) ~= 'string' or v:find("%S") then
          if i > 1 then
            write(newline)
          end
          xml_print(v, depth)
        end
      end
    end
  end
end

xpcall(function() 
  local parse = args.html and xml.html or xml.parse
  local target = "return function(a) return " .. translate_function(filter or '.') .. " end"
  local filter_function = assert(load(target))()
  local doc = parse(io.stdin:read("*all"))
  xml_print(filter_function(doc), 0)
  write("\n")
  colorize("normal")
end, function(err)
  io.stderr:write(debug.traceback(err, 2) .. "\n")
  colorize("normal")
end)
os.exit(0) -- don't bother cleaning up cleanly
