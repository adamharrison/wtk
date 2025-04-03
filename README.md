# lua-dbix

This is a `luarocks` module inspired by [`DBIx::Class`](https://metacpan.org/pod/DBIx::Class), my favorite ORM.

## Key Principles

Below are my general goals for this project, some of them achieved, others aspirational.

1. Smol.
2. Simple.
3. Some magic, but not too much.
4. Optionally nonblockable via lua coroutines.
5. Supports at least MySQL/MariaDB, PostgresSQL and sqlite3.
6. Easily overridable to cover the cases we don't.
7. Stand-alone; doesn't require `restty` or `lapis` or anything else.
8. Well documented.

## Quickstart

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

## API

### High-Level API

#### dbix

`dbix` is the module that is returned from requiring this module. It has several internal
classes which can be used independently.

| Class                         | Description                                                |
|-------------------------------|------------------------------------------------------------|
| [`schema`](#schema)           | Defines a set of tables and relations.                     |
| [`connection`](#connecction)  | Represents a connection to a database.                     |
| [`cschema`](#cschema)         | Represents a schema and a connection together.             |
| [`table`](#table)`            | Represents a table.                                        |
| [`resultset`](#resultset)     | Represents a set of results from the database.             |
| [`record`](#record)           | Represents a single row from the database.                 |


| Function                   | Description                                                |
|----------------------------|------------------------------------------------------------|
| `raw(str)`                 | Allows you to pass raw sql directly into queries.          |    


#### schema

| Function                   | Description                                                |
|----------------------------|------------------------------------------------------------|
| `connect(options)`         | Connects to a database, based on a set of options.         |
| `table(table|string)`      | Specifies a table, or retrieves a previously specified one.|

#### connection

The methods specified here and thin wrappers over the methods supplied by a given `driver`.

Not all functions are supported across all drivers, only the first set of functions specified below are
guaranteed.

| Function                   | Description                                                                           |
|----------------------------|---------------------------------------------------------------------------------------|
| `new(driver, options?)`    | Connects to a database, based on a driver, set of options.                            |
| `quote(conn, string)`      | Quotes a string as a string.                                                          |  
| `escape(conn, literal)`    | Escapes a literal.                                                                    |  
| `close(conn)`              | Closes the connection to the database.                                                |  
| `query(conn, query)`       | Runs a query against the database connection. Returns `resutlset` or `int` and `int`  |

The following functions are optionally supported, and will be no-ops on certain drivers.

| Optional Function          |
|----------------------------|---------------------------------------------------------------------------------|  
| `type(conn, type)`         | Translates a standardized type for this specific database. Optionally supported.|
| `fd(conn)`                 | Returns the file descriptor for the underlying connection. Optinally suppoted.  |
| `txn_start(conn, options?)`| Starts a transaction. Optionally supported.                                     |
| `txn_commit(conn)`         | Commits a transaction. Optionally supported.                                    |  
| `txn_rollback(conn)`       | Rolls back a transaction. Optionally supported.                                 |  
| `txn(conn, func)`          | Calls `func` inside a transaction, and commits if no errors have occurred.      |  

#### cschema

Any method from `schema` or `connection` can be called here on a `cschema`. In addition, it has the following methods.

| Function                   | Description                                                                                |
|----------------------------|--------------------------------------------------------------------------------------------|
| `<table_name>`             | Referencing a table's name will return a [`resultset`](#resultset) relevant to this table. |

#### table

Represents a table in a database.

| Function                                                                      | Description                                                                |
|-------------------------------------------------------------------------------|----------------------------------------------------------------------------|
| `belongs_to(self, name, foreign?, self_columns?, foreign_columns?, options?)` | Specifies a `one-to-many` relation between `self` and a `foreign` `table`. |
| `has_many(self, name, foreign?, self_columns?, foreign_columns?, options?)`   | Specifies a `many-to-one` relation between `self` and a `foreign` `table`. |

#### resultset

Represents a set of results from the database.

| Function                   | Description                                                                           |
|----------------------------|---------------------------------------------------------------------------------------|
| `first()`                  | Returns the first record of a query.                                                  |
| `all()`                    | Returns all records from a query in a table.                                          |  
| `each()`                   | Efficiently iterates through one record at a time.                                    |  
| `where(conditions)`        | Adds `WHERE` conditions to existing conditions with `AND`.                            |  
| `search(conditions)`       | Synonym for `where`.                                                                  |  
| `having(conditions)`       | Adds `HAVING` conditions to existing conditions with `AND`.                           |  
| `rows(max_rows)`           | Retrieves at most `max_rows` in `all` and `each`.                                     |
| `prefetch(relation)`       | Adds clauses to retrieve the named `relation` in a single query.                      |
| `group_by(column)`         | Groups the resultset by the specified column or list of columns.                      |
| `create(columns)`          | Creates a record with the specified `WHERE` values as well as `columns` values.       |
| `update(columns)`          | Updates all relevant records in this resultset with the specified column values.      |
| `delete(columns)`          | Deletes all relevant records in this resultset.                                       |
| `as_sql(as_count)`         | Converts this resultset to an SQL expression.                                         |

#### result

Represents a single result from the datbase

| Function                   | Description                                                                           |
|----------------------------|---------------------------------------------------------------------------------------|
| `<column name>`            | Returns the specified column for this record.                                         |
| `<column name>=`           | Assigns a value to this column and flags it as dirty for `update`.                    |
| `insert()`                 | Inserts this record into the database if possible.                                    |
| `update(columns?)`         | Updates this record with the specified columns, and any dirty columns.                |
| `delete()`                 | Removes this record from the database.                                                |


### DBD

Database drivers are C modules that are required from `schema.connect` (or supplied directly as a table/userdata to), and define the following functions.

| Function         | mysql | postgres | sqlite3 | Notes |
|------------------|-------|----------|---------|-------|
| `connect`        | ✓     |  ✓       | ✓       |       |
| `quote`          | ✓     |  ✓       | ✓       |       | 
| `escape`         | ✓     |  ✓       | ✓       |       | 
| `close`          | ✓     |  ✓       | ✓       |       | 
| `query`          | ✓     |  ✓       | ✓       |       | 
| `type`           | ✓     |  ✓       | ✓       |       |
| `fd`             | ✓     |  ✓       | ✓       |       |
| `txn_start`      | ✓     |  ✓       | ✓       |       |
| `txn_commit`     | ✓     |  ✓       | ✓       |       |
| `txn_rollback`   | ✓     |  ✓       | ✓       |       |
