local dbix = {}

local schema, stable, resultset, result, connection, cschema, raw, blob, NULL = {}, {}, {}, {}, {}, {}, {}, {}, {}

local function grep(arr, func) local t = {} for i,v in ipairs(arr) do if func(v,i) then table.insert(t,v) end end return t  end
local function map(arr, func) local t = {} for i,v in ipairs(arr) do t[i] = func(v, i) end return t end
local function merge(a,b) local t = {} for k,v in pairs(a) do t[k] = v end for k,v in pairs(b) do t[k] = v end return t end
local function group_by(a, func)
  local t = {}
  for i,v in ipairs(a) do
    local key = func(v)
    if not t[key] then t[key] = { } end
    table.insert(t[key], v)
  end
  return t
end
local function first(a) return a end

dbix.schema = schema
dbix.connection = connection
schema.table = stable
schema.resultset = resultset
schema.__index = schema
stable.__index = stable
connection.__index = connection
resultset.__index = resultset
dbix.raw = function(str)
  return setmetatable({ str }, raw)
end
dbix.null = NULL
dbix.blob = function(str)
  return setmetatable({ str }, blob)
end

function cschema.new(connection, schema)
  local self = setmetatable({ }, cschema)
  self._connection = connection
  self._schema = schema
  self._c = connection._c
  self._options = connection._options
  for i,v in ipairs(schema.tables) do
    self[v.name] = resultset.new(self, v)
  end
  return self
end
function cschema:__index(key) return rawget(cschema, key) or connection[key] end

function cschema:query(str, binds)
  assert(not binds or type(binds) == 'table', "binds should be passed as a table")
  local statement, err = self._connection:query(str, binds)
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
  for i, column in ipairs(t.columns) do t.columns[column.name] = column end
  t.relationships = {}
  table.insert(self.tables, setmetatable(t, stable))
  return self.tables[#self.tables]
end
function stable:add_column(c) table.insert(self.columns, c) end
function stable:belongs_to(t, name, self_columns, foreign_columns) 
  -- if we can have a NULL in at least one of our columns, thent his becomes a might_belong relationship
  self_columns = self_columns or { t.singular .. "_id" }
  table.insert(self.relationships, { 
    name = name or t.singular,
    type = #grep(self_columns, function(s) return not self.columns[s].not_null end) > 0 and "might_belong" or "belongs_to",
    self_columns = self_columns,
    foreign_table = t,
    foreign_columns = columns or { "id" } 
  }) 
end
function stable:has_many(t, name, self_columns, foreign_columns) table.insert(self.relationships, { name = name or t.plural, type = "has_many", self_columns = self_columns or { "id" }, foreign_table = t, foreign_columns = columns or { self.singular .. "_id" } }) end
function stable:has_one(t, name, self_columns, foreign_columns) table.insert(self.relationships, { name = name or t.plural, type = "has_one", self_columns = self_columns or { "id" }, foreign_table = t, foreign_columns = columns or { self.singular .. "_id" } }) end

function stable:validate_type(column, value)
  if column then
    if value and value ~= dbix.null then
      if column.data_type:find("int") or column.data_type:find("decimal") or column.data_type:find("float") then
        assert(tonumber(value) ~= nil, column.name .. " must be a number.")
      elseif type(value) == 'string' and column.data_type:find("date") then
        assert(value:find("^%d+%-%d+%-%d+"), column.name .. " must be a date.")
      end
    else
      assert(not column.not_null, column.name .. " must be non-null.")
    end
  end
end


function connection.new(driver, options)
  local self = setmetatable({ }, connection)
  self._driver = assert(type(driver) == 'string' and require("wtk.dbix.dbd." .. driver .. ".c") or driver, "can't find driver " .. driver)
  self._options = merge({ validate_types = true }, options or {})
  self._log = os.getenv("DBIX_TRACE") and function(self, msg) io.stderr:write(msg, "\n") end or options.log or false
  self._c = assert(self._driver:connect(options))
  return self
end
-- all drivers should provide these functionalities
function connection:close() return self._c:close() end
function connection:escape(...) 
  return table.concat(map({ ... }, function(e) 
    if getmetatable(e) == raw then return e[1] end
    if getmetatable(e) == NULL then return "NULL" end
    return self._c:escape(e) 
  end), '.') 
end
function connection:quote(str) return self._c:quote(str) end
function connection:query(statement, binds) 
  if self._log then self._log(self, statement) end
  return self._c:query(statement, binds) 
end 
-- optional methods
function connection:type(column) return self._c.type and self._c:type(column) end
function connection:txn_start(options) return self._c.txn_start and self._c:txn_start(options) end
function connection:txn_commit() return self._c.txn_commit and self._c:txn_commit() end
function connection:txn_rollback() return self._c.txn_rollback and self._c:txn_rollback() end
-- end of functionality to be provided by c modules
function connection:txn(func)
  self:txn_start()
  local status, err = xpcall(func, function(a) return debug.traceback(a, 3) end)
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
  elseif type(value) == 'boolean' then
    return value and 1 or 0
  elseif type(value) == "number" then
    return value
  elseif type(value) == 'table' then
    if getmetatable(value) == raw then 
      return value[1] 
    elseif getmetatable(value) == blob then 
      return '?' 
    elseif value == NULL then 
      return 'NULL'
    end
  end
  return ''
end

function connection:date(date)
  return os.date("%Y-%m-%d %H:%M:%S", date)
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
        if relationship.type == "belongs_to" or relationship.type == "might_belong" then
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


function resultset.new(connection, t, cached)
  if getmetatable(connection) == resultset then
    local rs = setmetatable({ }, resultset)
    for k,v in pairs(connection) do rs[k] = v end
    rs._where = { table.unpack(connection._where) }
    rs._having = { table.unpack(connection._having) }
    rs._prefetch = { table.unpack(connection._prefetch) }
    rs._join = { table.unpack(connection._join) }
    return rs
  end
  return setmetatable({
    _where = {},
    _having = {},
    _rows = nil,
    _offset = nil,
    _columns = nil,
    _distinct = false,
    _group_by = nil,
    _order_by = nil,
    _cached = cached,
    _default_values = {},
    _prefetch = {},
    _join = {},
    _variable_row_count = false,
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
function resultset:__len() return self:count() end
function resultset:rows(rows) local rs = resultset.new(self) rs._rows = rows return rs end
function resultset:offset(offset) local rs = resultset.new(self) rs._offset = offset return rs end
function resultset:columns(columns) local rs = resultset.new(self) rs._columns = columns return rs end
function resultset:group_by(columns) local rs = resultset.new(self) rs._group_by = type(columns) == 'table' and columns or { columns } return rs end
function resultset:order_by(columns) local rs = resultset.new(self) rs._order_by = type(columns) == 'table' and #columns > 0 and columns or { columns } return rs end
function resultset:distinct(distinct) local rs = resultset.new(self) rs._distinct = distinct return rs end
function resultset:join(str) local rs = resultset.new(self) table.insert(rs._join, str) return rs end
function resultset:prefetch(relationships) 
  local rs = resultset.new(self) 
  for i, relationship in ipairs(type(relationships) == 'table' and relationships or { relationships }) do
    local r = assert(grep(self._table.relationships, function(r) return r.name == relationship end)[1], "can't find relationship " .. relationship)
    table.insert(rs._prefetch, r)
    if r.type == "has_many" then
      rs._variable_row_count = true
      rs._order_by = map(self._table.primary_key, function(e) return dbix.raw(self._connection:escape("me", e)) end)
    end
  end
  return rs 
end


local function each_iteration(a, i)
  local current = a.statement:fetch()
  if not current then return nil end
  local result = result.new(a.rs._connection, a.rs._table, current)
  if result and a.rs._table.inflate then return a.rs._table.inflate(result) end
  if a.rs._prefetch and #a.rs._prefetch > 0 then
    return a.rs:merge_results({ result })
  end
  return result
end

local function each_multirow_iteration(a, i)
  local results = a.last_result and { a.last_result } or { }
  local primary_key = a.last_result and a.last_result:primary_key()
  while true do
    local current = a.statement:fetch()
    if current then 
      local result = result.new(a.rs._connection, a.rs._table, current, a.rs)
      if result and a.rs._table.inflate then result = a.rs._table.inflate(result) end
      if result then
        local result_primary_key = result:primary_key()
        if primary_key and primary_key ~= result_primary_key then
          a.last_result = result
          break
        end
        table.insert(results, result)
        primary_key = result_primary_key
      end
    else
      a.last_result = nil
      break
    end
  end
  return a.rs:merge_results(results)
end

local function each_cached_iteration(a, i)
  local item = a.cached[a.idx]
  a.idx = a.idx + 1
  return item
end

function resultset:offset_of_prefetch(relationship)
  local offset = 1 + #self._table.columns
  for i,v in ipairs(self._prefetch) do
    if v == relationship then
      break
    else
      offset = offset + #v.foreign_table.columns
    end
  end
  return offset
end

function resultset:merge_results(rows)
  if #rows == 0 then return nil end
  for i, relationship in ipairs(self._prefetch) do
    if relationship.type == "belongs_to" or relationship.type == "might_belong" or relationship.type == "has_one" then  
      local offset = self:offset_of_prefetch(relationship)
      local values = {}
      for j = offset, offset + #relationship.foreign_table.columns do
        values[j - offset + 1] = rows[1]._row[j]
      end
      rawset(rows[1], relationship.name, result.new(self._connection, relationship.foreign_table, values))
    elseif relationship.type == "has_many" then
      local offset = self:offset_of_prefetch(relationship)
      local records = map(rows, function(row)
        local values = {}
        local all_nil = true
        for j = offset, offset + (#relationship.foreign_table.columns - 1) do
          if row._row[j] ~= nil then all_nil = false end
          values[j - offset + 1] = row._row[j]
        end
        return not all_nil and result.new(self._connection, relationship.foreign_table, values) or nil
      end)
      local last_primary_key = nil
      local total_records = {}
      for i, record in ipairs(records) do
        local primary_key = record:primary_key()
        if not last_primary_key or last_primary_key ~= primary_key then
          table.insert(total_records, record)
        end
        last_primary_key = primary_key
      end
      rawset(rows[1], relationship.name, resultset.new(self._connection, relationship.table, total_records))
    end
  end
  return rows[1]
end

function resultset:each() 
  if self._cached then 
    return each_cached_iteration, { rs = self, cached = self._cached, idx = 1 }, nil
  elseif self._variable_row_count then
    return each_multirow_iteration, { rs = self, statement = self._connection:query(self:as_sql()), last_result = nil }, nil 
  else
    return each_iteration, { rs = self, statement = self._connection:query(self:as_sql()), last_result = nil }, nil 
  end
end
function resultset:all() local t = {} for row in self:each() do table.insert(t, row) end return t end
function resultset:find(conditions) 
  if (type(conditions) == "number" or type(conditions) == "string") then
    assert(self._table.primary_key and #self._table.primary_key == 1)
    conditions = { [self._table.primary_key[1]] = conditions }
  end
  return self:where(conditions):first() 
end
function resultset:first() 
  if self._variable_row_count then 
    for row in self:each() do 
      return row 
    end 
  end 
  return self:rows(1):all()[1] 
end
function resultset:take(num)
  if self._variable_row_count then 
    local t = {}
    local i = 0
    for row in self:each() do 
      table.insert(t, row) 
      i = i + 1
      if i >= num then
        break
      end
    end 
    return t
  end 
  return self:rows(num):all()
end
function resultset:count() 
  if self._cached then return #self._cached end
  local query = self._connection:query(self:as_sql(true))
  local count = math.floor(query:fetch()[1]) 
  query:close()
  return count
end

function result.new(connection, table, row, rs) return setmetatable({ _connection = connection, _table = table, _row = row, _dirty = {}, _rs = rs }, result) end

function result:__index(key)
  if rawget(result, key) then return rawget(result, key) end
  if rawget(self._table, key) then return rawget(self._table, key) end
  for i, column in ipairs(self._table.columns) do
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
  local found_index = false
  for i = 1, #self._table.columns do
    if self._table.columns[i].name == key then
      self._row[i] = value
      self._dirty[i] = true
      found_index = true
      break
    end
  end
  if not found_index then rawset(self, key, value) end
end

function result:insert()
  local columns = {}
  local fields = {}
  local binds = {}
  for i = 1, #self._table.columns do
    if self._row[i] then
      if self._connection._options.validate_types then self._table:validate_type(self._table.columns[i], self._row[i]) end
      table.insert(columns, self._connection:escape(self._table.columns[i].name))
      table.insert(fields, self._connection:translate_value(self._row[i]))
      if type(self._row[i]) == 'table' and getmetatable(self._row[i]) == blob then
        table.insert(binds, self._row[i])
      end
    end
  end
  local statement = "INSERT INTO " .. self._connection:escape(self._table.name) .. " (" .. table.concat(columns, ",") .. ") VALUES"
  statement = statement .. "(" .. table.concat(fields, ",") .. ")"
  local affected_rows, last_insert_id = self._connection:query(statement, binds)
  if self._table.primary_key and #self._table.primary_key == 1 and last_insert_id and last_insert_id > 0 then
    self[self._table.primary_key[1]] = last_insert_id
    self._dirty = {}
  end
  return self
end

function result:update(params)
  if params then
    for k,v in pairs(params) do
      self[k] = v
    end
  end
  params = { }
  local has_one = false
  for k,v in pairs(self._dirty) do
    params[self._table.columns[k].name] = self._row[k]
    has_one = true
  end
  self.dirty = {}
  if not has_one then return 0 end
  local statement = "UPDATE " .. self._connection:escape(self._table.name) .. " SET "
  local fields = {} 
  local binds = {}
  for k,v in pairs(params) do 
    if self._connection._options.validate_types then self._table:validate_type(self._table.columns[k], v) end
    table.insert(fields, self._connection:escape(k) .. " = " .. self._connection:translate_value(v)) 
    if type(v) == 'table' and getmetatable(v) == blob then
      table.insert(binds, v)
    end
  end
  local t = map(assert(self._table.primary_key, "requires a primary key"), function(k) return self._connection:escape(k) .. " = " .. self._connection:translate_value(self[k]) end)
  return self._connection:query(statement .. table.concat(fields, ", ") .. " WHERE " .. table.concat(t, " AND "), binds)
end

function result:delete()
  return self._connection:query("DELETE FROM " .. self._connection:escape(self._table.name) .. 
    " WHERE " .. table.concat(map(assert(self._table.primary_key, "requries a primary key"), function(k) return self._connection:escape(k) .. " = " .. self._connection:translate_value(self[k]) end), " AND "))
end

function result:primary_key()
  if not self._table.primary_key then return nil end
  return table.concat(map(self._table.primary_key, function(k) return self[k] end), ",")
end

function result:foreign_key(relationship)
  if not relationship.foreign_table.primary_key then return nil end
  local offset = self.rs:offset_of_prefetch(relationship)
  return table.concat(map(relationship.foreign_table.primary_key, function(k, i) return self._row[k + offset + 1] end), ",")
end

function resultset:shadow(params) return result.new(self._connection, self._table, map(self._table.columns, function(c, i) return params[c.name] end)) end
function resultset:create(params) return self:shadow(merge(self._default_values, params)):insert() end
function resultset:delete(params) 
  local statement = "DELETE FROM " .. self._connection:escape(self._table.name) 
  if self._where and #self._where > 0 then
    local t = map(self._where, function(e) return self:translate_conditions(e) end)
    statement = statement .. " WHERE " .. table.concat(t, " AND ")
  end
  return self._connection:query(statement)
end
function resultset:update(params)
  local statement = "UPDATE " .. self._connection:escape(self._table.name) .. " SET "
  local updates = {}
  local binds = {}
  for k,v in pairs(params) do
    if self._connection._options.validate_types then self._table:validate_type(self._table.columns[k], v) end
    table.insert(updates, self._connection:escape(k) .. " = " .. self._connection:translate_value(v))
    if type(v) == 'table' and getmetatable(v) == blob then
      table.insert(binds, v)
    end
  end
  statement = statement .. table.concat(assert(#updates > 0 and updates, "requires update params"), ", ")
  if self._where and #self._where > 0 then
    local t = map(self._where, function(e) return "(" .. self:translate_conditions(e) .. ")" end)
    statement = statement .. " WHERE " .. table.concat(t, " AND ")
  end
  return self._connection:query(statement, binds)
end

function resultset:translate_condition_value(condition)
  local t = type(condition)
  if t == 'table' then
    if condition == NULL then return "NULL" end
    if getmetatable(condition) == resultset then return condition:as_sql() end
    if #condition > 0 then return "(" .. table.concat(map(condition, function(v) return self:translate_condition_value(v) end, ","), ",") .. ")" end
    for k,v in pairs(condition) do 
      local key = k
      if k == "!=" and type(v) == 'table' then
        if v == NULL then return "IS NOT NULL" end
        key = "NOT IN"
      elseif k == "==" and type(v) == 'table' then
        if v == NULL then return "IS NULL" end
        key = "IN"
      end
      return key:gsub("_", " "):upper() .. " " .. self:translate_condition_value(v) 
    end
  elseif t == 'string' or t == 'number' or t == 'boolean' then
    return self._connection:translate_value(condition)
  end
  return '1=0'
end

function resultset:translate_conditions(condition)
  if type(condition) == 'string' then return condition end
  for key, value in pairs(condition) do
    if key == "and" or key == "or" then
      return table.concat(map(value, function(c) return self:translate_conditions(c) end), " " .. key .. " ")
    else
      local t = type(value)
      if t == 'table' and getmetatable(value) == resultset then
        return self._connection:escape(key) .. " IN (" .. value:as_sql() .. ")"
      elseif t == 'table' and #value > 0 then
        return self._connection:escape(key) .. " IN " .. self:translate_condition_value(value)
      elseif t == 'string' or t == 'number' or t == 'boolean' then
        return self._connection:escape(key) .. " = " .. self:translate_condition_value(value)
      elseif value == NULL then
        return self._connection:escape(key) .. " IS NULL"
      else
        return self._connection:escape(key) .. " " .. self:translate_condition_value(value)
      end
    end
  end
end

function resultset:as_sql(as_count)
  local statement = "SELECT "
  local disambiguate = self._prefetch and #self._prefetch > 0
  if self._distinct then
    statement = statement .. "DISTINCT " 
  end
  if as_count then
    statement = statement .. "COUNT(*)"
  elseif self._columns then
    statement = statement .. table.concat(map(self._columns, function(e) return self._connection:escape(e) end), ", ")
  else
    if disambiguate then
      statement = statement .. table.concat(map(self._table.columns, function(e) return self._connection:escape("me", e.name) end), ", ")
      for i, relationship in ipairs(self._prefetch) do
        statement = statement .. ", " .. table.concat(map(relationship.foreign_table.columns, function(e) return self._connection:escape(relationship.name, e.name) end), ", ")
      end
    else
      statement = statement .. table.concat(map(self._table.columns, function(e) return self._connection:escape(e.name) end), ", ")
    end
  end
  statement = statement .. " FROM " .. self._connection:escape(self._table.name) .. " " .. self._connection:escape("me")
  if self._prefetch and #self._prefetch > 0 then
    for i,v in ipairs(self._prefetch) do
      local join_type = (v.type == "has_many" or v.type == "might_belong") and "LEFT JOIN" or "JOIN"
      statement = statement .. " " .. join_type .. " " .. self._connection:escape(v.foreign_table.name) .. " " .. self._connection:escape(v.name) .. " ON " .. table.concat(map(v.self_columns, function(sc, i) 
        return self._connection:escape("me", sc) .. " = " .. self._connection:escape(v.name, v.foreign_columns[i])
      end), " AND ")
    end
  end
  if self._join and #self._join > 0 then
    statement = statement .. " " .. table.concat(self._join, " ")
  end
  if self._where and #self._where > 0 then
    local t = map(self._where, function(e) return "(" .. self:translate_conditions(e) .. ")" end)
    statement = statement .. " WHERE " .. table.concat(t, " AND ")
  end
  if self._group_by and #self._group_by > 0 then
    statement = statmeent .. " GROUP BY " .. table.concat(map(self._group_by, function(e) return self:translate_conditions(e) end, ", "))
  end
  if self._having and #self._having > 0 then
    statement = statement .. " HAVING " .. table.concat(map(self._having, function(e) return self:translate_conditions(e) end, " AND "))
  end
  if self._order_by and #self._order_by > 0 then
    statement = statement .. " ORDER BY " .. table.concat(map(self._order_by, function(e) 
      if getmetatable(e) == raw then 
        return e[1]
      elseif type(e) == 'table' then
        if e.desc then
          return self._connection:escape(e.desc) .. " DESC"
        elseif e.asc then
          return self._connection:escape(e.asc)  .. " ASC"
        end
      else
        return self._connection:escape(e) 
      end
    end, ", "))
  end
  if self._offset then statement = statement .. " OFFSET " .. self._offset end
  if self._rows then statement = statement .. " LIMIT " .. self._rows end
  return statement
end

return dbix
