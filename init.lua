local dbix = {}

local schema, stable, resultset, result, connection = {}, {}, {}, {}, {}

local function map(arr, func) local t = {} for i,v in ipairs(arr) do table.insert(t, func(v)) end return t end

dbix.schema = schema
schema.table = stable
schema.resultset = resultset
schema.__index = schema
stable.__index = function(self, k) return rawget(stable, k) end
resultset.__index = resultset

function schema:connect(driver, options)
  return connection.new(self, driver, options)
end

function schema.new()
  return setmetatable({ 
    tables = {},
    connection = nil
  }, schema)
end


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



function connection.new(schema, driver, options)
  local self = setmetatable({ }, connection)
  self._schema = schema
  self._driver = assert(require("dbix." .. driver), "can't find driver " .. driver)
  self._log = os.getenv("DBIX_TRACE") and function(self, msg) io.stderr:write(msg, "\n") end or false
  self._c = assert(self._driver:connect(options))
  return self
end
function connection:__index(key) return rawget(connection, key) or resultset.new(self, assert(self._schema:table(key), "unknown table " .. key)) end

function connection:translate_type(column)
  if column.data_type == 'string' then return "varchar(" .. (column.length or 255) .. ")" end
  if column.data_type == 'boolean' then return "tinyint(1)" end
  return column.data_type
end

-- all drivers should provide these functionalities
function connection:close() return self._c:close() end
function connection:txn_start() return self._c:txn_start() end
function connection:txn_commit() return self._c:txn_commit() end
function connection:txn_rollback() return self._c:txn_rollback() end
function connection:escape(str) return self._c:escape(str) end --  "`" .. str:gsub("\\", "\\\\"):gsub("`", "\\`") .. "`"
function connection:quote(str) return self._c:quote(str)  end -- "'" .. str:gsub("\\", "\\\\"):gsub("\"", "\\\"")  .. "'"
function connection:query(statement) -- a statement which does return something
  if self._log then self._log(self, statement) end
  local statement, err = self._c:query(statement)
  if err then error(err) end
  return statement
end
-- end of functionality to be provided by c modules

function connection:translate_table(t)
  local c = self._c
  local table_statement = string.format("CREATE TABLE %s (", self:escape(t.name))
  for i, column in ipairs(t.columns) do
    if i > 1 then table_statement = table_statement .. ", " end
    table_statement = table_statement .. string.format("%s %s", self:escape(column.name), self:translate_type(column))
    if column.not_null then table_statement = table_statement .. " NOT NULL" end
    if column.default then table_statement = table_statement .. " DEFAULT " .. (type(column.default) == 'string' and self:quote(column.default) or column.default) end
    if column.auto_increment then table_statement = table_statement .. " AUTO_INCREMENT"  end
  end
  if t.primary_key then table_statement = table_statement .. ", PRIMARY KEY(" .. table.concat(map(t.primary_key, function(e) return self:escape(e) end), ",") end
  table_statement = table_statement .. ")"
  return table_statement
end

function connection:deploy_statements(options)
  local c = self._c
  if not options then options = {} end
  local statements = {}
  for _, t in ipairs(self._schema.tables) do
    if options.deploy_drop then self:query(string.format("DROP TABLE %s IF EXISTS", self:escape(t.name))) end
    table.insert(statements, self:translate_table(t))
  end
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
  return statements
end

function connection:deploy(options) for i, statement in ipairs(self:deploy_statements(options)) do self:query(statement) end return self end


function connection:txn(func)
  self:txn_begin()
  local status, err = pcall(func)
  if not status then 
    self:txn_rollback()
    error(err)
  end
  self:txn_commit()
  return err
end

function resultset.new(connection, t)
  if getmetatable(connection) == resultset then
    local rs = setmetatable({ }, resultset)
    for k,v in pairs(connection) do rs[k] = v end
    return rs
  end
  return setmetatable({
    _conditions = {},
    _rows = nil,
    _offset = nil,
    _columns = nil,
    _connection = connection,
    _table = t
  }, resultset)
end

function resultset:search(params, attrs)
  local rs = resultset.new(self)
  for k,v in pairs(params) do
    table.insert(rs._conditions, { [k] = v })
  end
  if attrs then
    if attrs.rows then rs._rows = attrs.rows end
    if attrs.offset then rs.offset = attrs.offset end
  end
  return rs
end


local function each_iteration(a, i)
  local current = a.statement:fetch()
  if not current then return nil end
  local result = result.new(a.rs._connection, a.rs._table, current)
  if result and a.rs._table.inflate then return a.rs._table.inflate(result) end
  return result
end

function resultset:all() local t = {} for row in self:each() do table.insert(t, row) end return t end
function resultset:each() return each_iteration, { rs = self, statement = self._connection:query(self:as_sql()) }, nil end
function resultset:first() return self:search({}, { rows = 1 }):all()[1] end
function resultset:count() return math.floor(self._connection:query(self:as_sql(true)):fetch()[1]) end
function result.new(connection, table, row) return setmetatable({ _connection = connection, _table = table, _row = row }, result) end

function result:__index(key)
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
      return self._connection[relationship.foreign_table.plural]:search(t)
    end
  end
  return nil
end

function resultset:translate_value(condition)
  local t = type(condition)
  if t == 'table' then
    if #condition > 0 then return "(" .. table.concat(map(condition, function(v) return self:translate_value(v) end, ","), ",") .. ")" end
    for k,v in pairs(condition) do return k:gsub("_", " "):upper() .. " " .. self:translate_value(v) end
  elseif t == 'string' then
    return self._connection:quote(condition)
  elseif t == 'number' then
    return condition
  end
  return '1=0'
end

function resultset:translate_conditions(condition)
  if type(condition) == 'string' then return condition end
  for key, value in pairs(condition) do
    if key == "and" or key == "or" then
      return table.concat(map(value, function(c) return self:translate_condition(c) end), key)
    else
      local t = type(value)
      if t == 'table' and #value > 0 then
        return self._connection:escape(key) .. " IN " .. self:translate_value(value)
      elseif t == 'string' or t == 'number' then
        return self._connection:escape(key) .. " = " .. self:translate_value(value)
      else
        return self._connection:escape(key) .. " " .. self:translate_value(value)
      end
    end
  end
end


function resultset:as_sql(as_count)
  local statement = "SELECT "
  if as_count then
    statement = statement .. " COUNT(*)"
  elseif self._columns then
    statement = statement .. table.concat(map(self._columns, function(e) return self._connection:escape(e) end), ", ")
  else
    statement = statement .. table.concat(map(self._table.columns, function(e) return self._connection:escape(e.name) end), ", ")
  end
  statement = statement .. " FROM " .. self._connection:escape(self._table.name) .. " " .. self._connection:escape("me")
  if self._conditions and #self._conditions > 0 then
    statement = statement .. " WHERE " .. table.concat(map(self._conditions, function(e) return self:translate_conditions(e) end, " AND "))
  end
  if self._offset then statement = statement .. " OFFSET " .. self._offset end
  if self._rows then statement = statement .. " LIMIT " .. self._rows end
  return statement
end

return dbix
