#ifndef API_H
#define API_H

#include "lib/lua52/lua.h"
#include "lib/lua52/lauxlib.h"
#include "lib/lua52/lualib.h"

#define API_TYPE_FONT  "Font"
#define API_TYPE_IMAGE "Image"
#define API_TYPE_PTY   "Pty"

void api_load_libs(lua_State *L);

#endif
