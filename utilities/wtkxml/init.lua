local wtk = require "wtk.c"
local system = require "wtk.c.system"
local xml = require "wtk.xml"

local function sorted_keys(a) local t = {} for k,v in pairs(a) do table.insert(t, k) end table.sort(t) return t end
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



local function xml_print(doc, depth)
  if not depth then depth = 0 end
  if doc.tags then
    local t = {}
    if doc.prolog then write(string.format('<?xml version="%s" encoding="%s"?>', doc.prolog.version, doc.prolog.encoding)) write(newline) end
    if doc.doctype then write(string.format('<!DOCTYPE %s>', doc.doctype.definition)) write(newline) end
    for i,v in ipairs(doc.tags) do xml_print(v, options, depth) end
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
    else 
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
      if #doc == 0 then
        write("/>", "grey")
      else
        write(">", "grey")
        if not args['no-format'] and #doc == 1 and type(doc[1]) ~= "table" then
          write(doc[1], "normal")
        else
          for i,v in ipairs(doc) do
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
    end
  end
end

xpcall(function() 
  local parse = args.html and xml.html or xml.parse
  local doc = parse(io.stdin:read("*all"))
  print(xml_print(doc, { format = args.strip and "strip" or (args.compress and "compact" or (not args["no-format"] and "pretty")) }))
  colorize("normal")
end, function(err)
  io.stderr:write(debug.traceback(err, 2) .. "\n")
end)
os.exit(0) -- don't bother cleaning up cleanly
