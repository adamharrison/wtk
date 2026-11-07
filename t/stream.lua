local wtk = require "wtk"

local cr = coroutine.create(function()
  local f = wtk.io.file("/tmp/test", "wb")
  for l = 0, 4 do
    for i = 0, 200000 do
      f:write(i)
    end
    f:write("\n")
  end
  f:close()
  local stat = wtk.system.stat("/tmp/test");
  f = wtk.io.file("/tmp/test", "rb")
  assert(stat and stat.size == 5444485)
  local i = 0
  for line in f:lines() do
    assert(#line == 1088896, "invalid line length: " .. #line)
    i = i + 1
  end
  assert(i == 5)
  return true
end)

while coroutine.status(cr) ~= "dead" do 
  local status, err = coroutine.resume(cr)
  if not status then error(err) end
end

