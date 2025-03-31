local dbix = require "init"

local schema = dbix.schema.new()
local users = schema:table({
  name = "users",
  columns = {
    { name = "id", auto_increment = true, data_type = "int", not_null = true },
    { name = "updated", data_type = "datetime", not_null = true },
    { name = "created", data_type = "datetime", not_null = true },
    { name = "first_name", data_type = "string", length = 64 },
    { name = "last_name", data_type = "string", length = 64 },
    { name = "email", data_type = "string", length = 128 },
    { name = "requests", data_type = "text" },
    { name = "creator_id", data_type = "int" },
    { name = "last_login", data_type = "datetime" },
    { name = "visible_categories", data_type = "json" },
    { name = "profile", data_type = "text" }
  },
  primary_key = { "id" }
})

local serieses = schema:table({
  name = "serieses",
  singular = "series",
  columns = {
    { name = "id", auto_increment = true, data_type = "int", not_null = true },
    { name = "updated", data_type = "datetime", not_null = true },
    { name = "created", data_type = "datetime", not_null = true },
    { name = "title", data_type = "string", length = 255 },
    { name = "image", data_type = "text" },
    { name = "author", data_type = "string", length = 64 },
    { name = "tags", data_type = "text" },
    { name = "books_planned", data_type = "int" },
    { name = "books_written", data_type = "int" },
    { name = "female_pov", data_type = "text" },
    { name = "remote_id", data_type = "string", length = 128 },
    { name = "category", data_type = "string", length = 16 },
    { name = "supercategory", data_type = "string", length = 64 }
  },
  primary_key = { "id" }
})

local entries = schema:table({
  name = "entries",
  singular = "entry",
  columns = {
    { name = "id", auto_increment = true, data_type = "int", not_null = true },
    { name = "updated", data_type = "datetime", not_null = true },
    { name = "created", data_type = "datetime", not_null = true },
    { name = "description", data_type = "text" },
    { name = "remote_id", data_type = "string", length = 128 },
    { name = "title", data_type = "string", length = 255 },
    { name = "author", data_type = "string", length = 64 },
    { name = "position", data_type = "float" },
    { name = "image", data_type = "text" },
    { name = "series_id", data_type = "int" }
  },
  primary_key = { "id" }
})
entries:belongs_to(serieses)

local reviews = schema:table({
  name = "reviews",
  columns = {
    { name = "id", auto_increment = true, data_type = "int", not_null = true },
    { name = "updated", data_type = "datetime", not_null = true },
    { name = "created", data_type = "datetime", not_null = true },
    { name = "books_read", data_type = "int" },
    { name = "score", data_type = "float" },
    { name = "content", data_type = "text" },
    { name = "series_id", data_type = "int", not_null = true },
    { name = "user_id", data_type = "int", not_null = true },
    { name = "status", data_type = "string", length = 16 },
    { name = "required_reading", data_type = "boolean" },
    { name = "finished", data_type = "datetime" },
    { name = "entry_id", data_type = "int" }
  },
  primary_key = { "id" }
})
reviews:belongs_to(users)
reviews:belongs_to(serieses)
reviews:belongs_to(entries)
users:has_many(reviews)

local cr = coroutine.create(function()
  local c = schema:connect('mysql', { 
    database = 'bookreview',
    username = 'root',
    password = '',
    hostname = 'localhost',
    port = '3306',
    nonblocking = true
  })
  print(table.concat(c:deploy_statements(), "\n"))
  --c:txn(function() 
    for user in c.users:search({ first_name = { "Garry" } }):each() do
      print(user.first_name)
      print(user.reviews:count())
    end
  --end)
end)

while coroutine.status(cr) ~= "dead" do 
  coroutine.resume(cr)
end

