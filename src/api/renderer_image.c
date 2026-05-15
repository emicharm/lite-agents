#include "api.h"
#include "renderer.h"
#include "rencache.h"


static int f_load(lua_State *L) {
  const char *filename = luaL_checkstring(L, 1);
  RenImage **self = lua_newuserdata(L, sizeof(*self));
  luaL_setmetatable(L, API_TYPE_IMAGE);
  *self = ren_load_image_file(filename);
  if (!*self) {
    lua_pushnil(L);
    lua_pushfstring(L, "failed to load image %s", filename);
    return 2;
  }
  return 1;
}


static int f_gc(lua_State *L) {
  RenImage **self = luaL_checkudata(L, 1, API_TYPE_IMAGE);
  if (*self) { ren_free_image(*self); *self = NULL; }
  return 0;
}


static int f_get_size(lua_State *L) {
  RenImage **self = luaL_checkudata(L, 1, API_TYPE_IMAGE);
  int w = 0, h = 0;
  if (*self) { ren_get_image_size(*self, &w, &h); }
  lua_pushnumber(L, w);
  lua_pushnumber(L, h);
  return 2;
}


static const luaL_Reg lib[] = {
  { "__gc",     f_gc       },
  { "load",     f_load     },
  { "get_size", f_get_size },
  { NULL, NULL }
};

int luaopen_renderer_image(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_IMAGE);
  luaL_setfuncs(L, lib, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  return 1;
}
