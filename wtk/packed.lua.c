// This is a dummy inclusion file for wtk projects.
// If included, this particular file means that no files are packed into this binary.
// However, if packed.lua.c is present in an earlier inclusion path (in the directory itself).
// Then, lua IS packed.
#ifndef WTK_UNPACKED
  #define WTK_UNPACKED
#endif
static void* luaW_packed[] = { NULL, NULL, NULL };
