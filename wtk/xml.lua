local xml = {}
xml.cmt, xml.dtmt, xml.pmt = {}, {}, {}, {}
xml.tmt = {
  __len = function(self) return #self.nodes end,
  __index = function(self, key)
    if math.type(key) == 'integer' then
      return self.nodes[key]
    end
    if type(key) ~= "string" then return nil end
    if rawget(rawget(self, "props"), key) then return rawget(rawget(self, "props"), key) end
    for i, v in ipairs(self.nodes) do
      if type(v) == 'table' and v.tag == key then
        if #v.nodes == 0 then return nil end
        if #v.nodes == 1 and type(v.nodes[1]) == 'string' and v.nodes[1] then
          return v.nodes[1]
        end
        return v
      end
    end
    return nil
  end,
}
xml.dmt = {
  __index = function(self, key)
    if type(key) ~= "string" then return nil end
    for i,v in ipairs(rawget(self, 'children')) do
      if v.tag == key then return v end
    end
    return nil
  end
}


local function sorted_keys(a) local t = {} for k,v in pairs(a) do table.insert(t, k) end table.sort(t) return t end
local function merge(a,b) local t = {} for k,v in pairs(a) do t[k] = v end for k,v in pairs(b) do t[k] = v end return t end

local function find_end_of_string(str, offset) 
  local quote = str:sub(offset, offset)
  assert(quote == "'" or quote == '"')
  local escape_count = 0
  local actual_string = ""
  for i = offset + 1, #str do
    local chr = str:sub(i,i)
    if chr == '\\' then 
      escape_count = escape_count + 1 
      if escape_count == 2 then
        actual_string = actual_string .. '\\'
        escape_count = 0
      end
    elseif chr == quote and escape_count == 0 then
      return i, actual_string
    else
      actual_string = actual_string .. chr
      escape_count = 0
    end
  end
  return nil
end

function xml.tag(tag, props) return setmetatable({ tag = tag, props = props, children = { }, nodes = { } }, xml.tmt) end
function xml.comment(comment) return setmetatable({ comment = comment }, xml.cmt) end
function xml.prolog(version, encoding) return setmetatable({ version = version, encoding = encoding }, xml.pmt) end
function xml.doctype(definition) return setmetatable({ definition = definition }, xml.dtmt) end
function xml.document(prolog, doctype) return setmetatable({ prolog = prolog, doctype = doctype, children = {}, nodes = {} }, xml.dmt) end


xml.html_options = { autoclose = { "br", "hr", "img", "input", "meta", "link" }, strict = false, halts = { "script", "style" } }

function xml.parse(text, options)
  options = options or {}
  if options.infer == nil and not options.strict then options.infer = true end
  local offset = options.offset or 1
  local tags = {}
  local prolog = nil
  local doctype, dt = nil
  local open_quote = false
  local open_tag = false
  local open_comment = false
  local start_token = nil
  local s,e,p = text:find("^%s*<%s*%?%s*xml([^>]+)%?>", offset)
  if e then 
    local vs, ve = p:find("version%s*=%s*")
    local _, version = find_end_of_string(p, ve + 1)
    local vs, ve = p:find("encoding%s*=%s*")
    local _, encoding = find_end_of_string(p, ve + 1)
    prolog = xml.prolog(version, encoding)
    offset = e + 1
  end
  s,e,dt = text:find("^%s*<%s*%![dD][oO][cC][tT][yY][pP][eE]%s*([^>]+)>", offset)
  if e then 
    doctype = xml.doctype(dt)
    offset = e + 1
  end
  if (doctype and doctype.definition == "html") or text:find("^s*<%s*[hH][tT][mM][lL]", offset) then
    options = merge(xml.html_options, options)
  end
  local autoclose_tags, halt_tags = {}, {}
  for i,v in ipairs(options.autoclose or {}) do autoclose_tags[v] = true end
  for i,v in ipairs(options.halts or {}) do halt_tags[v] = true end
  local doc = xml.document(prolog, doctype)
  tags = { { children = doc.children, nodes = doc.nodes } }
  ::continue::
  while offset < #text do
    if open_comment then
      local s,e = assert(text:find("^%s*%-%->", offset), "can't find closing comment")
      table.insert(tags[#tags].children, xml.comment(text:sub(open_comment, s - 1)))
      offset = e + 1
      open_comment = false
      goto continue
    else
      local s,e = text:find("%s*<!%-%-%s*", offset)
      if s then
        open_comment = e + 1
        offset = e + 1
        goto continue
      end
    end
    if #tags > 0 and not open_tag then
      if halt_tags[tags[#tags].tag] then
        local s,e = text:find("<%s*/%s*" .. tags[#tags].tag .. "%s*>", offset)
        assert(s, "cannot find closing tag for " .. tags[#tags].tag)
        local subtext = text:sub(offset, s - 1)
        table.insert(tags[#tags].children, subtext)
        if subtext:find("%S") then
          table.insert(tags[#tags].nodes, subtext)
        end
        offset = e + 1 
        table.insert(tags[#tags - 1].children, tags[#tags])
        table.insert(tags[#tags - 1].nodes, tags[#tags])
        table.remove(tags)
        goto continue
      else
        local s,e, tag = text:find("^<%s*/%s*([^>%s]+)%s*>", offset)
        if s then
          assert(tag == tags[#tags].tag, "closing tag </" .. tag .. "> at offset " .. offset .. " doesn't match last open tag <" .. tags[#tags].tag .. ">")
          offset = e + 1 
          table.insert(tags[#tags - 1].children, tags[#tags])
          table.insert(tags[#tags - 1].nodes, tags[#tags])
          table.remove(tags)
          goto continue
        end
      end
    end
    if open_tag then
      local s, e, autoclose = text:find("^%s*(/?)%s*>", offset)
      if s and #autoclose == 0 and autoclose_tags[tags[#tags].tag] then
        autoclose = "/"
      end
      if s then
        open_tag = false
        offset = e + 1
        if #autoclose > 0 then
          table.insert(tags[#tags - 1].children, tags[#tags])
          table.insert(tags[#tags - 1].nodes, tags[#tags])
          table.remove(tags)
        end
      else
        local s, e, prop, quote = text:find("^%s*([^=%>]+)%s*=%s*([\"'])", offset)
        assert(s or not options.strict, "unrecognized property")
        if s then
          local ne, value = assert(find_end_of_string(text, e))
          tags[#tags].props[prop] = value
          offset = ne + 1
        else
          local s, e, prop, value = text:find("^%s*([^=%>]+)%s*=%s*(%S)", offset)
          if s then 
            tags[#tags].props[prop] = value
            offset = e + 1
          else
            local s, e, prop, value = text:find("^%s*([^=%>]+)", offset)
            assert(s, "unrecognizable property")
            tags[#tags].props[prop] = true
            offset = e + 1
          end
        end
      end
    else
      local s, e, content = text:find("^<%!%[CDATA%[%s*(.-)%s*%]%]%s*>", offset)
      if s then
        table.insert(tags[#tags].children, content);
        table.insert(tags[#tags].nodes, content);
        offset = e + 1
      else
        local s, e, tag = text:find("^<%s*([^%s>/]+)", offset)
        if s then 
          table.insert(tags, xml.tag(tag, {}))
          tags[#tags].parent = tags[#tags - 1]
          open_tag = true
          offset = e + 1
        else
          s, e, content = assert(text:find("^([^<]+)", offset))
          table.insert(tags[#tags].children, content);
          local _, _, stripped = content:find("%s*(%S+)%s*")
          if stripped then
            table.insert(tags[#tags].nodes, stripped)
          end
          offset = e + 1
        end
      end
    end
  end
  if #tags > 1 then error("didn't find closing tag for " .. tags[#tags].tag) end
  return doc
end

function xml.html(text, options) return xml.parse(text, merge(xml.html_options, options or {})) end
function xml.file(path, options) return xml[text:find("%.html$") and "html" or "parse"](assert(io.open(path, "rb")):read("*all"), options) end

function xml.print(doc, options, depth)
  options = options or {}
  if not depth then depth = 0 end
  if getmetatable(doc) == xml.dmt then
    local t = {}
    if doc.prolog then table.insert(t, string.format('<?xml version="%s" encoding="%s"?>', doc.prolog.version, doc.prolog.encoding)) end
    if doc.doctype then table.insert(t, string.format('<!DOCTYPE %s>', doc.doctype.definition)) end
    for i,v in ipairs(doc.tags) do table.insert(t, xml.print(v, options, depth)) end
    return table.concat(t, options.format == "pretty" and "\n" or "")
  end
  if type(doc) ~= 'table' then 
    if type(doc) == 'string' then
      if options.format == "compress" then
        doc = doc:gsub("^%s+", " ")
        doc = doc:gsub("%s+$", " ")
      elseif options.format == "strip" or options.format == "pretty" then
        doc = doc:gsub("^%s+", "")
        doc = doc:gsub("%s+$", "")
      end
    end
    return doc
  end
  local str = "<" .. doc.tag
  for _, k in ipairs(sorted_keys(doc.props)) do
    str = str .. string.format(" %s=\"%s\"", k, doc.props[k]:gsub("\\", "\\\\"):gsub('"', '\\"'))
  end
  if #doc == 0 then
    return str .. '/>'
  else
    local ending, beginning, tab = "", "", ""
    if options.format == "pretty" then
      tab = options.indent or "\t"
      beginning = string.rep(tab, depth)
      ending = options.newline or "\n"
    end
    if options.format == "pretty" and #doc == 1 and type(doc[1]) ~= "table" then
      return str .. ">" .. xml.print(doc[1], options, depth + 1) .. "</" .. doc.tag .. ">"
    else
      local children = {}
      for i,v in ipairs(doc.children) do
        local result = beginning .. tab .. xml.print(v, options, depth + 1) .. ending
        table.insert(children, result)
      end
      return str .. ">" .. ending .. table.concat(children) .. beginning .. "</" .. doc.tag .. ">"
    end
  end
  return str
end
xml.tmt.__tostring = xml.print
xml.dmt.__tostring = xml.print

local function gfind(self, t, tag)
  if self.tag == tag then
    table.insert(t, self)
  end
  for i,v in ipairs(self) do
    if type(v) == 'table' then
      gfind(v, t, tag)
    end
  end
end

function xml.gfind(self, tag)
  local t = {}
  gfind(self, t, tag)
  local i = 0
  return function()
    i = i + 1
    return t[i]
  end
end

return xml
