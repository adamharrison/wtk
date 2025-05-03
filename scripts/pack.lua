-- used to pack files into a single C file
-- usage: lua scripts/pack.lua *.lua > packed.c
print("const char* packed_luac[] = {") 
for i,file in ipairs({ ... }) do 
  io.stderr:write("Packing " .. file .. "...\n")
  local f, err = load(io.lines(file,"L"), "="..file)
  if not f then error("Error packing " .. file .. ": " .. err) end
  cont = string.dump(f):gsub(".",function(c) return string.format("\\x%02X",string.byte(c)) end) 
  print("\t\""..file:gsub("/", "."):gsub("%.lua$", "") .."\",\""..cont.."\",(void*)"..math.floor(#cont/3)..",")
end 
print("(void*)0, (void*)0, (void*)0\n};")
