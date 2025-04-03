local dbix = {}

local schema, stable, resultset, result, connection, cschema, raw = {}, {}, {}, {}, {}, {}, {}

local function map(arr, func) local t = {} for i,v in ipairs(arr) do t[i] = func(v, i) end return t end
local function merge(a,b) local t = {} for k,v in pairs(a) do t[k] = v end for k,v in pairs(b) do t[k] = v end return t end

dbix.schema = schema
schema.table = stable
schema.resultset = resultset
schema.__index = schema
stable.__index = stable
connection.__index = connection
resultset.__index = resultset
dbix.raw = function(str)
  return setmetatable({ str }, raw)
end

function cschema.new(connection, schema)
  local self = setmetatable({ }, cschema)
  self._connection = connection
  self._schema = schema
  self._c = connection._c
  return self
end
function cschema:__index(key) return rawget(cschema, key) or connection[key] or resultset.new(self, assert(self._schema:table(key), "unknown table " .. key)) end

function cschema:query(str)
  local statement, err = self._connection:query(str)
  if not statement and err then error(err) end
  return statement, err
end

function schema:connect(driver, options)
  return cschema.new(connection.new(driver, options), self)
end

---@class schema
function schema.new()
  return setmetatable({ 
    tables = {},
    connection = nil
  }, schema)
end

--- Looks up, or defines a new table.
---@param t table|string
function schema:table(t)
  if type(t) == 'string' then
    for i,v in ipairs(self.tables) do if v.name == t then return v end end
  end
  assert(type(t) == 'table')
  t.schema = self
  if not t.plural then t.plural = t.name end
  if not t.singular then t.singular = t.plural:gsub("s$", "") end
  t.relationships = {}
  table.insert(self.tables, setmetatable(t, stable))
  return self.tables[#self.tables]
end
function stable:add_column(c) table.insert(self.columns, c) end
function stable:belongs_to(t, name, self_columns, foreign_columns) table.insert(self.relationships, { name = name or t.singular, type = "belong_to", self_columns = self_columns or { t.singular .. "_id" }, foreign_table = t, foreign_columns = columns or { "id" } }) end
function stable:has_many(t, name, self_columns, foreign_columns) table.insert(self.relationships, { name = name or t.plural, type = "has_many", self_columns = self_columns or { "id" }, foreign_table = t, foreign_columns = columns or { self.singular .. "_id" } }) end

function connection.new(driver, options)
  local self = setmetatable({ }, connection)
  self._driver = assert(type(driver) == 'string' and require("dbix.dbd." .. driver) or driver, "can't find driver " .. driver)
  self._options = options or {}
  self._log = os.getenv("DBIX_TRACE") and function(self, msg) io.stderr:write(msg, "\n") end or options.log or false
  self._c = assert(self._driver:connect(options))
  return self
end
-- all drivers should provide these functionalities
function connection:close() return self._c:close() end
function connection:escape(str) return self._c:escape(str) end
function connection:quote(str) return self._c:quote(str) end
function connection:query(statement) 
  if self._log then self._log(self, statement) end
  return self._c:query(statement) 
end 
-- optional methods
function connection:type(column) return self._c.type and self._c:type(column) end
function connection:txn_start(options) return self._c.txn_start and self._c:txn_start(options) end
function connection:txn_commit() return self._c.txn_commit and self._c:txn_commit() end
function connection:txn_rollback() return self._c.txn_rollback and self._c:txn_rollback() end
-- end of functionality to be provided by c modules
function connection:txn(func)
  self:txn_start()
  local status, err = pcall(func)
  if not status then 
    self:txn_rollback()
    error(err, 0)
  end
  self:txn_commit()
  return err
end

function connection:translate_value(value)
  if type(value) == "string" then
    return self:quote(value)
  elseif type(value) == "nil" then
    return "NULL"
  elseif type(value) == "number" then
    return value
  elseif type(value) == 'table' then
    if getmetatable(value) == raw then 
      return value[1] 
    end
  end
  return ''
end

function connection:translate_table(t, options)
  local c = self._c
  local table_statement = string.format("CREATE TABLE %s (", self:escape(t.name))
  for i, column in ipairs(t.columns) do
    if i > 1 then table_statement = table_statement .. ", " end
    if not column.deploy then 
      table_statement = table_statement .. string.format("%s %s", self:escape(column.name), self:type(column))
      if column.not_null then table_statement = table_statement .. " NOT NULL" end
      if column.default then table_statement = table_statement .. " DEFAULT " .. (type(column.default) == 'string' and self:quote(column.default) or column.default) end
    else
      table_statement = table_statement .. column.deploy(self, column, t)
    end
  end
  if t.primary_key and options.primary_key ~= false then table_statement = table_statement .. ", PRIMARY KEY(" .. table.concat(map(t.primary_key, function(e) return self:escape(e) end), ",") .. ")" end
  if t.deploy then table_statement = table_statement .. t.deploy(self, t, table_statement) end
  table_statement = table_statement .. ")"
  if t.transform then table_statement = t.transform(self, t, table_statement) end
  if options.transform then table_statement = t.transform(self, t, table_statement) end
  return table_statement
end

function cschema:deploy_statements(options)
  local c = self._c
  assert(c.type, "unable to generate deploy statments, driver doesn't supply `type`.")
  if not options then options = {} end
  local statements = {}
  for _, t in ipairs(self._schema.tables) do
    if options.drop then self._connection:query(string.format("DROP TABLE %s IF EXISTS", self:escape(t.name))) end
    table.insert(statements, self._connection:translate_table(t, options))
  end
  if self._connection._options.foreign_keys ~= false and options.foreign_keys == false then
    for _, t in ipairs(self._schema.tables) do
      for _, relationship in ipairs(t.relationships) do
        if relationship.type == "belong_to" then
          table.insert(statements, string.format("ALTER TABLE %s ADD CONSTRAINT %s FOREIGN KEY(%s) REFERENCES %s(%s)",
            self:escape(t.name),
            self:escape("fk_" .. relationship.name),
            table.concat(map(relationship.self_columns, function(e) return self:escape(e) end), ","),
            relationship.foreign_table.name,
            table.concat(map(relationship.foreign_columns, function(e) return self:escape(e) end, ","))
          ))
        end
      end
    end
  end
  return statements
end

function cschema:deploy(options) for i, statement in ipairs(self:deploy_statements(options)) do self:query(statement) end return self end


function resultset.new(connection, t)
  if getmetatable(connection) == resultset then
    local rs = setmetatable({ }, resultset)
    for k,v in pairs(connection) do rs[k] = v end
    return rs
  end
  return setmetatable({
    _where = {},
    _having = {},
    _rows = nil,
    _offset = nil,
    _columns = nil,
    _group_by = nil,
    _order_by = nil,
    _default_values = {},
    _connection = connection,
    _table = t
  }, resultset)
end

function resultset:search(params)
  local rs = resultset.new(self)
  for k,v in pairs(params) do
    table.insert(rs._where, { [k] = v })
  end
  return rs
end
resultset.where = resultset.search
function resultset:having(params)
  local rs = resultset.new(self)
  for k,v in pairs(params) do
    table.insert(rs._having, { [k] = v })
  end
  return rs
end
function resultset:rows(rows) local rs = resultset.new(self) rs._rows = rows return rs end
function resultset:offset(offset) local rs = resultset.new(self) rs._offset = offset return rs end
function resultset:group_by(columns) local rs = resultset.new(self) rs._group_by = type(columns) == 'table' and columns or { columns } return rs end
function resultset:order_by(columns) local rs = resultset.new(self) rs._order_by = type(columns) == 'table' and columns or { columns } return rs end


local function each_iteration(a, i)
  local current = a.statement:fetch()
  if not current then return nil end
  local result = result.new(a.rs._connection, a.rs._table, current)
  if result and a.rs._table.inflate then return a.rs._table.inflate(result) end
  return result
end

function resultset:each() return each_iteration, { rs = self, statement = self._connection:query(self:as_sql()) }, nil end
function resultset:all() local t = {} for row in self:each() do table.insert(t, row) end return t end
function resultset:first() return self:search({}):rows(1):all()[1] end
function resultset:count() 
  local query = self._connection:query(self:as_sql(true))
  local count = math.floor(query:fetch()[1]) 
  query:close()
  return count
end
function result.new(connection, table, row) return setmetatable({ _connection = connection, _table = table, _row = row, _dirty = {} }, result) end

function result:__index(key)
  if rawget(result, key) then return rawget(result, key) end
  for i,column in ipairs(self._table.columns) do
    if column.name == key then 
      return self._row[i]
    end
  end
  for i,relationship in ipairs(self._table.relationships) do
    if relationship.name == key then
      local t = {}
      for i,v in ipairs(relationship.foreign_columns) do 
        t[v] = self[relationship.self_columns[i]] 
      end
      local rs = self._connection[relationship.foreign_table.plural]:search(t)
      rs._default_values = t
      return rs
    end
  end
  return nil
end

function result:__newindex(key, value)
  for i = 1, #self._table.columns do
    if self._table.columns[i].name == key then
      self._row[i] = value
      self._dirty[i] = true
      break
    end
  end
end

function result:insert()
  local columns = {}
  local fields = {}
  for i = 1, #self._table.columns do
    if self._row[i] then
      table.insert(columns, self._connection:escape(self._table.columns[i].name))
      table.insert(fields, self._connection:translate_value(self._row[i]))
    end
  end
  local statement = "INSERT INTO " .. self._connection:escape(self._table.name) .. " (" .. table.concat(columns, ",") .. ") VALUES"
  statement = statement .. "(" .. table.concat(fields, ",") .. ")"
  local affected_rows, last_insert_id = self._connection:query(statement)
  if self._table.primary_key and #self._table.primary_key == 1 and last_insert_id and last_insert_id > 0 then
    self[self._table.primary_key[1]] = last_insert_id
    self._dirty = {}
  end
  return self
end

function result:update(params)
  if not params then
    params = { }
    local has_one = false
    for k,v in pairs(self._dirty) do
      params[self._table.columns[k].name] = self._row[k]
      has_one = true
    end
    self.dirty = {}
    if not has_one then return 0 end
  end
  local statement = "UPDATE " .. self._connection:escape(self._table.name) .. " SET "
  local fields = {} for k,v in pairs(params) do table.insert(fields, self._connection:escape(k) .. " = " .. self._connection:translate_value(v)) end
  return self._connection:query(statement .. table.concat(fields, ", ") .. " WHERE " .. table.concat(map(assert(self._table.primary_key, "requires a primary key"), function(k) return self._connection:escape(k) .. " = " .. self._connection:translate_value(self[k]) end), " AND "))
end

function result:delete()
  return self._connection:query("DELETE FROM " .. self._connection:escape(self._table.name) .. 
    " WHERE " .. table.concat(map(assert(self._table.primary_key, "requries a primary key"), function(k) return self._connection:escape(k) .. " = " .. self._connection:translate_value(self[k]) end), " AND "))
end

function resultset:shadow(params) return result.new(self._connection, self._table, map(self._table.columns, function(c, i) return params[c.name] end)) end
function resultset:create(params) return self:shadow(merge(self._default_values, params)):insert() end
function resultset:delete(params) 
  local statement = "DELETE FROM " .. self._connection:escape(self._table.name) 
  if self._where and #self._where > 0 then
    statement = statement .. " WHERE " .. table.concat(map(self._where, function(e) return self:translate_where(e) end, " AND "))
  end
  return self._connection:query(statement)
end
function resultset:update(params)
  local statement = "UPDATE " .. self._connection:escape(self._table.name) .. " SET "
  local updates = {}
  for k,v in pairs(params) do
    table.insert(updates, self._connection:escape(k) .. " = " .. self._connection:translate_value(v))
  end
  statement = statement .. table.concat(assert(#updates > 0 and updates, "requires update params"), ", ")
  if self._where and #self._where > 0 then
    statement = statement .. " WHERE " .. table.concat(map(self._where, function(e) return self:translate_where(e) end, " AND "))
  end
  return self._connection:query(statement)
end

function resultset:translate_condition_value(condition)
  local t = type(condition)
  if t == 'table' then
    if #condition > 0 then return "(" .. table.concat(map(condition, function(v) return self:translate_condition_value(v) end, ","), ",") .. ")" end
    for k,v in pairs(condition) do return k:gsub("_", " "):upper() .. " " .. self:translate_condition_value(v) end
  elseif t == 'string' then
    return self._connection:translate_value(condition)
  elseif t == 'number' then
    return self._connection:translate_value(condition)
  end
  return '1=0'
end

function resultset:translate_conditions(condition)
  if type(condition) == 'string' then return condition end
  for key, value in pairs(condition) do
    if key == "and" or key == "or" then
      return table.concat(map(value, function(c) return self:translate_conditions(c) end), key)
    else
      local t = type(value)
      if t == 'table' and #value > 0 then
        return self._connection:escape(key) .. " IN " .. self:translate_condition_value(value)
      elseif t == 'string' or t == 'number' then
        return self._connection:escape(key) .. " = " .. self:translate_condition_value(value)
      else
        return self._connection:escape(key) .. " " .. self:translate_condition_value(value)
      end
    end
  end
end


function resultset:as_sql(as_count)
  local statement = "SELECT "
  if as_count then
    statement = statement .. "COUNT(*)"
  elseif self._columns then
    statement = statement .. table.concat(map(self._columns, function(e) return self._connection:escape(e) end), ", ")
  else
    statement = statement .. table.concat(map(self._table.columns, function(e) return self._connection:escape(e.name) end), ", ")
  end
  statement = statement .. " FROM " .. self._connection:escape(self._table.name) .. " " .. self._connection:escape("me")
  if self._where and #self._where > 0 then
    statement = statement .. " WHERE " .. table.concat(map(self._where, function(e) return self:translate_conditions(e) end, " AND "))
  end
  if self._group_by and #self._group_by > 0 then
    statement = statmeent .. " GROUP BY " .. table.concat(map(self._group_by, function(e) return self:translate_conditions(e) end, ", "))
  end
  if self._where and #self._having > 0 then
    statement = statement .. " HAVING " .. table.concat(map(self._having, function(e) return self:translate_conditions(e) end, " AND "))
  end
  if self._where and #self._having > 0 then
    statement = statement .. " ORDER BY " .. table.concat(map(self._order_by, function(e) return self._connection:escape(e) end, ", "))
  end
  if self._offset then statement = statement .. " OFFSET " .. self._offset end
  if self._rows then statement = statement .. " LIMIT " .. self._rows end
  return statement
end

return dbix
