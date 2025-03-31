## lua-dbix

This is a `luarocks` module inspired by [`DBIx::Class`](https://metacpan.org/pod/DBIx::Class), my favorite ORM.

### Key Principles

1. Small.
2. Simple.
3. Some magic, but not too much.
4. Nonblockable.
5. Supports at least MySQL/MariaDB, PostgresSQL and sqlite3.
6. Easily overridable to cover the cases we don't.

### Quickstart

Works like the following:

```sh
luarocks5.4 install dbix dbix-mysql
```

This will build the MySQL driver; it assumes you have the MySQL client libraries.

```lua
local dbix = require "dbix"
local schema = dbix.schema.new()
local users = schema:table({
  name = "users",
  columns = {
    { name = "id", auto_increment = true, data_type = "int", not_null = true },
    { name = "updated", data_type = "datetime", not_null = true },
    { name = "created", data_type = "datetime", not_null = true },
    { name = "first_name", data_type = "string", length = 64 },
    { name = "last_name", data_type = "string", length = 64 },
    { name = "email", data_type = "string", length = 128 }
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
    { name = "category", data_type = "string", length = 16 }
  },
  primary_key = { "id" }
})

local reviews = schema:table({
  name = "reviews",
  columns = {
    { name = "id", auto_increment = true, data_type = "int", not_null = true },
    { name = "updated", data_type = "datetime", not_null = true },
    { name = "created", data_type = "datetime", not_null = true },
    { name = "score", data_type = "float" },
    { name = "content", data_type = "text" },
    { name = "series_id", data_type = "int", not_null = true },
    { name = "user_id", data_type = "int", not_null = true },
  },
  primary_key = { "id" }
})
reviews:belongs_to(users)
reviews:belongs_to(serieses)
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
  end)
end)

```


