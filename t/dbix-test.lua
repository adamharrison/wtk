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

schema:table({ 
  name = "people",
  columns = {
    { name = "id", data_type = "int", not_null = true },
    { name = "name", data_type = "string", not_null = true },
    { name = "birthday", data_type = "datetime" },
    { name = "deathday", data_type = "datetime" }
  }
})

--local cr = coroutine.create(function() 
--  local c = schema:connect('mysql', { 
--    database = 'bookreview',
--    username = 'root',
--    password = '',
--    hostname = 'localhost',
--    port = '3306',
--    nonblocking = true
--  })
--  for series in c.serieses:rows(10):each() do
--    print(series.title)
--  end
--  print(c.serieses:first().title)
--  print(c.serieses:first().title)
-- end)
-- while coroutine.status(cr) ~= "dead" do
--   coroutine.resume(cr)
-- end

--os.exit(0)

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
  c:txn(function() 
    print("Finding all Garrys...")
    for user in c.users:search({ first_name = { "Garry" } }):each() do
      print("User ID: ", user.id)
      print("Email: ", user.email)
      print("Review Count: ", user.reviews:count())
    end
    local user = c.users:create({ first_name = "John", last_name = "Smith", updated = os.date("%Y-%m-%dT%H:%M:%S"), created = os.date("%Y-%m-%dT%H:%M:%S") })
    print("Automatically assigned id: " .. user.id)
    user.email = "example@example.com"
    user:update()
    print("Updated existing user.")
    user:update({ last_name = "DeWalt" })
    local review = user.reviews:create({ series_id = 10, updated = os.date("%Y-%m-%dT%H:%M:%S"), created = os.date("%Y-%m-%dT%H:%M:%S") })
    print("New review id: " .. review.id)
    print("Updating all my reviews to 10/10.")
    user.reviews:update({ score = 10 })
    print("Increment all my scores to 20/10.")
    user.reviews:update({ score = dbix.raw("score + 10") })
    print("Deleting all user reviews.")
    user.reviews:delete()
    print("Deleting user.")
    user:delete()
    print("Total Reviews: " .. c.users:first().reviews:count())
    print("Fetching a user and their reviews in a single SQL statement.")
    local user = c.users:prefetch("reviews"):first()
    print("This resultset has been auto-fetched, and does not need to make another SQL query.")
    for review in user.reviews:each() do
      print("Review Score: " .. review.score)
    end
    print("We can also go the other way.")
    for review in c.reviews:prefetch("user"):distinct(true):each() do
      print("User Name: " .. review.user.first_name)
    end
  end)
end)

while coroutine.status(cr) ~= "dead" do 
  local status, err = coroutine.resume(cr)
  if not status then error(err) end
end

