#!/usr/bin/env lua
-- used to pack files into a single C file
-- usage: lua5.4 scripts/pack.lua *.lua > packed.c
print("const char* packed_luac[] = {") 
for i,file in ipairs({ ... }) do 
  cont = string.dump(load(io.lines(file..".lua","L"), "="..file..".lua")):gsub(".",function(c) return string.format("\\x%02X",string.byte(c)) end) 
  print("\t\""..file.."\",\""..cont.."\",(void*)"..math.floor(#cont/3)..",") 
end 
print("(void*)0, (void*)0, (void*)0\n};")
