local xml = {}

xml.mt = {
  __index = function(self, key)
    if type(key) ~= "string" then return nil end
    if rawget(rawget(self, "props"), key) then return rawget(rawget(self, "props"), key) end
    for i, v in ipairs(self) do
      if type(v) == 'table' then
        if v.tag == key then
          if #v == 0 then return nil end
          if #v == 1 and type(v[1]) == 'string' then
            return v[1]
          end
          return v
        end
      end
    end
    return nil
  end,
}

local function find_end_of_string(str, offset) 
  local quote = str:sub(offset, offset)
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

function xml.new(tag, props, ...)
  return setmetatable({ tag = tag, props = props, ... }, xml.mt)
end

-- xml parser that return
function xml.parse(text, offset)
  if not offset then offset = 1 end
  local tags = {}
  local open_quote = false
  local open_tag = false
  local start_token = nil
  local s,e = text:find("^%s*<%s*%?%s*xml[^>]+%?>", offset)
  if e then 
    offset = e + 1
  end
  while offset < #text do
    ::continue::
    if #tags > 0 then
      local s,e, tag = text:find("^%s*<%s*/%s*([^>%s]+)%s*>", offset)
      if s then
        assert(tag == tags[#tags].tag)
        offset = e + 1 
        if #tags == 1 then
          return tags[1]
        else
          table.insert(tags[#tags - 1], tags[#tags])
          table.remove(tags)
          goto continue
        end
      end
    end
    if open_tag then
      local s, e, autoclose = text:find("^%s*(/?)%s*>", offset)
      if s then
        open_tag = false
        offset = e + 1
        if #autoclose > 0 then
          if #tags == 1 then
            return tags[1]
          else
            table.insert(tags[#tags - 1], tags[#tags])
            table.remove(tags)
          end
        end
      else
        local s, e, prop, quote = assert(text:find("^%s*([^=]+)%s*=%s*([\"'])", offset))
        local ne, value = assert(find_end_of_string(text, e))
        tags[#tags].props[prop] = value
        offset = ne + 1
      end
    else
      local s, e, content = text:find("^%s*<%!%[CDATA%[%s*(.-)%s*%]%]%s*>", offset)
      if s then
        table.insert(tags[#tags], content);
        offset = e + 1
      else
        local s, e, tag = text:find("^%s*<%s*([^%s>/]+)", offset)
        if s then 
          table.insert(tags, xml.new(tag, {}))
          tags[#tags].parent = tags[#tags - 1]
          open_tag = true
          offset = e + 1
        else
          s, e, content = assert(text:find("^%s*([^<]+)", offset))
          table.insert(tags[#tags], content);
          offset = e + 1
        end
      end
    end
  end
  error("didn't find closing tag for " .. tags[#tags].tag)
end

function xml.print(doc, options)
  if type(doc) ~= 'table' then return doc end
  local str = "<" .. doc.tag
  for k,v in pairs(doc.props) do
    str = str .. string.format(" %s=\"%s\"", k, v:gsub("\\", "\\\\"):gsub('"', '\\"'))
  end
  if #doc == 0 then
    return str .. '/>'
  else
    local children = {}
    for i,v in ipairs(doc) do
      table.insert(children, xml.print(v, options))
    end
    return str .. ">" .. table.concat(children, "") .. "</" .. doc.tag .. ">"
  end
  return str
end
xml.mt__tostring = xml.print

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
