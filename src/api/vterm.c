/* vterm.c — libvterm Lua bindings.
**
**   vterm.new(rows, cols)            -> VTerm
**   vt:input_write(bytes)            -> n_consumed   (feed PTY output here)
**   vt:output_read()                 -> string       (drain bytes for the PTY)
**   vt:resize(rows, cols)
**   vt:get_size()                    -> rows, cols
**   vt:get_cell(row, col)            -> { ch, width, fg, bg, bold, italic,
**                                          underline, reverse, strike, blink }
**                                      row < 0 indexes scrollback: -1 is the
**                                      most recently scrolled-off line.
**   vt:get_cursor()                  -> row, col
**   vt:get_scrollback_count()        -> n  (lines available above row 0)
**   vt:keyboard_unichar(cp, mods)
**   vt:keyboard_key(name, mods)      -- name in {"enter","tab","up",...,"f12"}
**   vt:keyboard_start_paste()        -- emits \e[200~ iff bracketed paste is on
**   vt:keyboard_end_paste()          -- emits \e[201~ iff bracketed paste is on
**   vt:set_palette_color(idx, r, g, b) -- override the ANSI 16-color palette
**
** Mods may be an integer bitfield or a table { ctrl=true, shift=true, alt=true }.
*/

#include "api.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "vterm.h"

#define SB_CAPACITY 10000  /* lines of scrollback retained per terminal */

typedef struct {
  VTermScreenCell *cells;
  int              cap_cols;  /* allocated cells in this row */
  int              n_cols;    /* valid cells (the rest are blank) */
} SBLine;

typedef struct {
  VTerm        *vt;
  VTermScreen  *screen;
  VTermState   *state;
  SBLine       *sb;           /* ring buffer of past lines */
  int           sb_capacity;  /* == SB_CAPACITY */
  int           sb_head;      /* index of next slot to write */
  int           sb_count;     /* valid lines in the ring (≤ capacity) */
} LuaVTerm;


static LuaVTerm* check_term(lua_State *L, int idx) {
  return (LuaVTerm *) luaL_checkudata(L, idx, API_TYPE_VTERM);
}


/* Scrollback callbacks: libvterm calls sb_pushline when a line scrolls off
** the top of the visible screen, and sb_popline if it needs the most recent
** scrollback line back (e.g. the screen grew taller after a resize). */
static int sb_pushline(int cols, const VTermScreenCell *cells, void *user) {
  LuaVTerm *t = (LuaVTerm *) user;
  SBLine *line = &t->sb[t->sb_head];
  if (line->cap_cols < cols) {
    VTermScreenCell *p = (VTermScreenCell *) realloc(line->cells,
                                          sizeof(VTermScreenCell) * cols);
    if (!p) return 1;
    line->cells = p;
    line->cap_cols = cols;
  }
  memcpy(line->cells, cells, sizeof(VTermScreenCell) * cols);
  line->n_cols = cols;
  t->sb_head = (t->sb_head + 1) % t->sb_capacity;
  if (t->sb_count < t->sb_capacity) t->sb_count++;
  return 1;
}

static int sb_popline(int cols, VTermScreenCell *cells, void *user) {
  LuaVTerm *t = (LuaVTerm *) user;
  if (t->sb_count == 0) return 0;
  t->sb_head = (t->sb_head - 1 + t->sb_capacity) % t->sb_capacity;
  t->sb_count--;
  SBLine *line = &t->sb[t->sb_head];
  int n = line->n_cols < cols ? line->n_cols : cols;
  if (n > 0) memcpy(cells, line->cells, sizeof(VTermScreenCell) * n);
  for (int i = n; i < cols; i++) {
    memset(&cells[i], 0, sizeof(VTermScreenCell));
    cells[i].width = 1;
  }
  return 1;
}

static int sb_clear(void *user) {
  LuaVTerm *t = (LuaVTerm *) user;
  t->sb_head = 0;
  t->sb_count = 0;
  return 1;
}

static const VTermScreenCallbacks sb_callbacks = {
  .sb_pushline = sb_pushline,
  .sb_popline  = sb_popline,
  .sb_clear    = sb_clear,
};


static int f_new(lua_State *L) {
  int rows = (int) luaL_checkinteger(L, 1);
  int cols = (int) luaL_checkinteger(L, 2);
  LuaVTerm *t = (LuaVTerm *) lua_newuserdata(L, sizeof(LuaVTerm));
  memset(t, 0, sizeof(*t));
  luaL_setmetatable(L, API_TYPE_VTERM);
  t->vt = vterm_new(rows, cols);
  vterm_set_utf8(t->vt, 1);
  t->screen = vterm_obtain_screen(t->vt);
  t->state  = vterm_obtain_state(t->vt);
  vterm_screen_reset(t->screen, 1);

  t->sb_capacity = SB_CAPACITY;
  t->sb = (SBLine *) calloc(t->sb_capacity, sizeof(SBLine));
  if (t->sb) {
    vterm_screen_set_callbacks(t->screen, &sb_callbacks, t);
  }
  return 1;
}


static int f_gc(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  if (t->vt) {
    vterm_free(t->vt);
    t->vt = NULL;
  }
  if (t->sb) {
    for (int i = 0; i < t->sb_capacity; i++) free(t->sb[i].cells);
    free(t->sb);
    t->sb = NULL;
  }
  return 0;
}


static int f_input_write(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  size_t len;
  const char *s = luaL_checklstring(L, 2, &len);
  size_t n = vterm_input_write(t->vt, s, len);
  lua_pushinteger(L, (lua_Integer) n);
  return 1;
}


static int f_output_read(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  size_t avail = vterm_output_get_buffer_current(t->vt);
  if (avail == 0) {
    lua_pushliteral(L, "");
    return 1;
  }
  char *buf = (char *) malloc(avail);
  if (!buf) { lua_pushliteral(L, ""); return 1; }
  size_t n = vterm_output_read(t->vt, buf, avail);
  lua_pushlstring(L, buf, n);
  free(buf);
  return 1;
}


static int f_resize(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  int rows = (int) luaL_checkinteger(L, 2);
  int cols = (int) luaL_checkinteger(L, 3);
  vterm_set_size(t->vt, rows, cols);
  return 0;
}


static int f_get_size(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  int rows, cols;
  vterm_get_size(t->vt, &rows, &cols);
  lua_pushinteger(L, rows);
  lua_pushinteger(L, cols);
  return 2;
}


/* Push a {r,g,b} array for the cell color, or leave the field nil if vterm
** reports the default fg/bg (caller will substitute style.text / .background). */
static void push_color(lua_State *L, VTermScreen *screen, VTermColor src,
                       const char *key, int is_fg) {
  if (is_fg && VTERM_COLOR_IS_DEFAULT_FG(&src)) return;
  if (!is_fg && VTERM_COLOR_IS_DEFAULT_BG(&src)) return;
  if (VTERM_COLOR_IS_INDEXED(&src)) {
    vterm_screen_convert_color_to_rgb(screen, &src);
  }
  lua_newtable(L);
  lua_pushinteger(L, src.rgb.red);   lua_rawseti(L, -2, 1);
  lua_pushinteger(L, src.rgb.green); lua_rawseti(L, -2, 2);
  lua_pushinteger(L, src.rgb.blue);  lua_rawseti(L, -2, 3);
  lua_setfield(L, -2, key);
}


/* Encode up to 4 codepoints into the same UTF-8 buffer, in order. */
static size_t encode_utf8(uint32_t c, char *out) {
  if (c < 0x80) { out[0] = c; return 1; }
  if (c < 0x800) {
    out[0] = 0xc0 | (c >> 6);
    out[1] = 0x80 | (c & 0x3f);
    return 2;
  }
  if (c < 0x10000) {
    out[0] = 0xe0 | (c >> 12);
    out[1] = 0x80 | ((c >> 6) & 0x3f);
    out[2] = 0x80 | (c & 0x3f);
    return 3;
  }
  out[0] = 0xf0 | (c >> 18);
  out[1] = 0x80 | ((c >> 12) & 0x3f);
  out[2] = 0x80 | ((c >> 6) & 0x3f);
  out[3] = 0x80 | (c & 0x3f);
  return 4;
}


static void push_cell_table(lua_State *L, LuaVTerm *t, const VTermScreenCell *cell) {
  lua_newtable(L);

  char buf[32];
  size_t bp = 0;
  for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell->chars[i]; i++) {
    bp += encode_utf8(cell->chars[i], buf + bp);
    if (bp > sizeof(buf) - 8) break;
  }
  if (bp == 0) { buf[0] = ' '; bp = 1; }
  lua_pushlstring(L, buf, bp); lua_setfield(L, -2, "ch");

  lua_pushinteger(L, cell->width);                 lua_setfield(L, -2, "width");
  lua_pushboolean(L, cell->attrs.bold);            lua_setfield(L, -2, "bold");
  lua_pushboolean(L, cell->attrs.italic);          lua_setfield(L, -2, "italic");
  lua_pushboolean(L, cell->attrs.underline != 0);  lua_setfield(L, -2, "underline");
  lua_pushboolean(L, cell->attrs.reverse);         lua_setfield(L, -2, "reverse");
  lua_pushboolean(L, cell->attrs.strike);          lua_setfield(L, -2, "strike");
  lua_pushboolean(L, cell->attrs.blink);           lua_setfield(L, -2, "blink");

  push_color(L, t->screen, cell->fg, "fg", 1);
  push_color(L, t->screen, cell->bg, "bg", 0);
}


static int f_get_cell(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  int row = (int) luaL_checkinteger(L, 2);
  int col = (int) luaL_checkinteger(L, 3);

  if (row < 0) {
    int idx = -row;  /* row=-1 → newest scrollback line */
    if (idx > t->sb_count || !t->sb) { lua_pushnil(L); return 1; }
    int slot = (t->sb_head - idx + t->sb_capacity) % t->sb_capacity;
    SBLine *line = &t->sb[slot];
    if (col < 0 || col >= line->n_cols) { lua_pushnil(L); return 1; }
    push_cell_table(L, t, &line->cells[col]);
    return 1;
  }

  VTermPos pos;
  pos.row = row;
  pos.col = col;
  VTermScreenCell cell;
  if (!vterm_screen_get_cell(t->screen, pos, &cell)) {
    lua_pushnil(L);
    return 1;
  }
  push_cell_table(L, t, &cell);
  return 1;
}


static int f_get_scrollback_count(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  lua_pushinteger(L, t->sb_count);
  return 1;
}


static int f_get_cursor(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  VTermPos pos;
  vterm_state_get_cursorpos(t->state, &pos);
  lua_pushinteger(L, pos.row);
  lua_pushinteger(L, pos.col);
  return 2;
}


static int parse_mods(lua_State *L, int idx) {
  if (lua_isnoneornil(L, idx)) return VTERM_MOD_NONE;
  if (lua_isnumber(L, idx))    return (int) luaL_checkinteger(L, idx);
  if (lua_istable(L, idx)) {
    int m = 0;
    lua_getfield(L, idx, "shift"); if (lua_toboolean(L, -1)) m |= VTERM_MOD_SHIFT; lua_pop(L, 1);
    lua_getfield(L, idx, "alt");   if (lua_toboolean(L, -1)) m |= VTERM_MOD_ALT;   lua_pop(L, 1);
    lua_getfield(L, idx, "ctrl");  if (lua_toboolean(L, -1)) m |= VTERM_MOD_CTRL;  lua_pop(L, 1);
    return m;
  }
  return VTERM_MOD_NONE;
}


static int f_keyboard_unichar(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  uint32_t c = (uint32_t) luaL_checkinteger(L, 2);
  int mod = parse_mods(L, 3);
  vterm_keyboard_unichar(t->vt, c, (VTermModifier) mod);
  return 0;
}


static const struct { const char *name; int key; } key_map[] = {
  { "enter",     VTERM_KEY_ENTER     },
  { "return",    VTERM_KEY_ENTER     },
  { "tab",       VTERM_KEY_TAB       },
  { "backspace", VTERM_KEY_BACKSPACE },
  { "escape",    VTERM_KEY_ESCAPE    },
  { "up",        VTERM_KEY_UP        },
  { "down",      VTERM_KEY_DOWN      },
  { "left",      VTERM_KEY_LEFT      },
  { "right",     VTERM_KEY_RIGHT     },
  { "insert",    VTERM_KEY_INS       },
  { "delete",    VTERM_KEY_DEL       },
  { "home",      VTERM_KEY_HOME      },
  { "end",       VTERM_KEY_END       },
  { "pageup",    VTERM_KEY_PAGEUP    },
  { "pagedown",  VTERM_KEY_PAGEDOWN  },
  { "f1",  VTERM_KEY_FUNCTION_0 + 1  },
  { "f2",  VTERM_KEY_FUNCTION_0 + 2  },
  { "f3",  VTERM_KEY_FUNCTION_0 + 3  },
  { "f4",  VTERM_KEY_FUNCTION_0 + 4  },
  { "f5",  VTERM_KEY_FUNCTION_0 + 5  },
  { "f6",  VTERM_KEY_FUNCTION_0 + 6  },
  { "f7",  VTERM_KEY_FUNCTION_0 + 7  },
  { "f8",  VTERM_KEY_FUNCTION_0 + 8  },
  { "f9",  VTERM_KEY_FUNCTION_0 + 9  },
  { "f10", VTERM_KEY_FUNCTION_0 + 10 },
  { "f11", VTERM_KEY_FUNCTION_0 + 11 },
  { "f12", VTERM_KEY_FUNCTION_0 + 12 },
  { NULL,  0 },
};


static int f_keyboard_start_paste(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  vterm_keyboard_start_paste(t->vt);
  return 0;
}


static int f_keyboard_end_paste(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  vterm_keyboard_end_paste(t->vt);
  return 0;
}


static int f_set_palette_color(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  int idx = (int) luaL_checkinteger(L, 2);
  int r   = (int) luaL_checkinteger(L, 3);
  int g   = (int) luaL_checkinteger(L, 4);
  int b   = (int) luaL_checkinteger(L, 5);
  if (idx < 0 || idx > 255) return 0;
  VTermColor col;
  vterm_color_rgb(&col, (uint8_t) r, (uint8_t) g, (uint8_t) b);
  vterm_state_set_palette_color(t->state, idx, &col);
  return 0;
}


static int f_keyboard_key(lua_State *L) {
  LuaVTerm *t = check_term(L, 1);
  const char *name = luaL_checkstring(L, 2);
  int mod = parse_mods(L, 3);
  for (int i = 0; key_map[i].name; i++) {
    if (strcmp(name, key_map[i].name) == 0) {
      vterm_keyboard_key(t->vt, (VTermKey) key_map[i].key, (VTermModifier) mod);
      return 0;
    }
  }
  return 0;
}


static const luaL_Reg meta[] = {
  { "__gc",             f_gc                },
  { "input_write",      f_input_write       },
  { "output_read",      f_output_read       },
  { "resize",           f_resize            },
  { "get_size",         f_get_size          },
  { "get_cell",             f_get_cell             },
  { "get_cursor",           f_get_cursor           },
  { "get_scrollback_count", f_get_scrollback_count },
  { "keyboard_unichar",    f_keyboard_unichar    },
  { "keyboard_key",        f_keyboard_key        },
  { "keyboard_start_paste", f_keyboard_start_paste },
  { "keyboard_end_paste",   f_keyboard_end_paste   },
  { "set_palette_color",   f_set_palette_color   },
  { NULL, NULL },
};

static const luaL_Reg lib[] = {
  { "new", f_new },
  { NULL, NULL },
};


int luaopen_vterm(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_VTERM);
  luaL_setfuncs(L, meta, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, lib);
  return 1;
}
