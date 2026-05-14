/* pty.c — pseudo-terminal Lua module.
**
** Exposes a `pty` global with:
**
**   pty.open(cmd, cols, rows) -> Pty | nil, err
**   pty:read()                -> string | nil[, err]   (non-blocking)
**   pty:write(bytes)          -> n_written | nil, err
**   pty:resize(cols, rows)
**   pty:close()
**   pty:pid()                 -> integer
**
** Unix only for now — uses forkpty(3). Windows support would need ConPTY.
*/

#include "api.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
  #include <util.h>
#elif defined(__linux__)
  #include <pty.h>
#endif


typedef struct {
  int   fd;     /* master end, or -1 once closed */
  pid_t pid;    /* child pid, or -1 once reaped  */
} Pty;


static Pty* check_pty(lua_State *L, int idx) {
  return (Pty *) luaL_checkudata(L, idx, API_TYPE_PTY);
}


static int f_open(lua_State *L) {
  const char *cmd = luaL_checkstring(L, 1);
  int cols = (int) luaL_optinteger(L, 2, 80);
  int rows = (int) luaL_optinteger(L, 3, 24);

  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short) rows;
  ws.ws_col = (unsigned short) cols;

  int master = -1;
  pid_t pid = forkpty(&master, NULL, NULL, &ws);
  if (pid < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }

  if (pid == 0) {
    /* child: inherit a clean enough env, then exec the command via sh -c. */
    setenv("TERM", "xterm-256color", 1);
    /* Some shells care about COLORTERM for truecolor. */
    setenv("COLORTERM", "truecolor", 1);
    execl("/bin/sh", "sh", "-c", cmd, (char *) NULL);
    _exit(127);
  }

  /* parent: non-blocking master fd so the editor loop never stalls. */
  int flags = fcntl(master, F_GETFL, 0);
  if (flags != -1) {
    fcntl(master, F_SETFL, flags | O_NONBLOCK);
  }

  Pty *p = lua_newuserdata(L, sizeof(Pty));
  luaL_setmetatable(L, API_TYPE_PTY);
  p->fd  = master;
  p->pid = pid;
  return 1;
}


static int f_read(lua_State *L) {
  Pty *p = check_pty(L, 1);
  if (p->fd < 0) { lua_pushnil(L); return 1; }

  char buf[16 * 1024];
  ssize_t n = read(p->fd, buf, sizeof(buf));
  if (n > 0) {
    lua_pushlstring(L, buf, n);
    return 1;
  }
  if (n == 0) {
    /* EOF: child closed its end. */
    lua_pushnil(L);
    lua_pushliteral(L, "eof");
    return 2;
  }
  if (errno == EAGAIN || errno == EWOULDBLOCK) {
    /* No data right now — perfectly normal in poll mode. */
    lua_pushnil(L);
    return 1;
  }
  lua_pushnil(L);
  lua_pushstring(L, strerror(errno));
  return 2;
}


static int f_write(lua_State *L) {
  Pty *p = check_pty(L, 1);
  size_t len;
  const char *s = luaL_checklstring(L, 2, &len);
  if (p->fd < 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "closed");
    return 2;
  }

  size_t written = 0;
  while (written < len) {
    ssize_t n = write(p->fd, s + written, len - written);
    if (n > 0) {
      written += (size_t) n;
      continue;
    }
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      /* Pipe full; return what we managed so the caller can retry later. */
      break;
    }
    if (n < 0 && errno == EINTR) { continue; }
    if (n < 0) {
      lua_pushnil(L);
      lua_pushstring(L, strerror(errno));
      return 2;
    }
  }
  lua_pushinteger(L, (lua_Integer) written);
  return 1;
}


static int f_resize(lua_State *L) {
  Pty *p = check_pty(L, 1);
  int cols = (int) luaL_checkinteger(L, 2);
  int rows = (int) luaL_checkinteger(L, 3);
  if (p->fd < 0) { return 0; }
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = (unsigned short) rows;
  ws.ws_col = (unsigned short) cols;
  ioctl(p->fd, TIOCSWINSZ, &ws);
  return 0;
}


static int f_pid(lua_State *L) {
  Pty *p = check_pty(L, 1);
  lua_pushinteger(L, (lua_Integer) p->pid);
  return 1;
}


static int f_running(lua_State *L) {
  Pty *p = check_pty(L, 1);
  if (p->pid <= 0) { lua_pushboolean(L, 0); return 1; }
  int status;
  pid_t r = waitpid(p->pid, &status, WNOHANG);
  if (r == 0) { lua_pushboolean(L, 1); return 1; }      /* still alive */
  if (r == p->pid) { p->pid = -1; }
  lua_pushboolean(L, 0);
  return 1;
}


static void shutdown_pty(Pty *p, int forceful) {
  if (p->fd >= 0) {
    close(p->fd);
    p->fd = -1;
  }
  if (p->pid > 0) {
    kill(p->pid, forceful ? SIGTERM : SIGHUP);
    /* Best-effort reap, non-blocking. */
    int status;
    waitpid(p->pid, &status, WNOHANG);
    p->pid = -1;
  }
}


static int f_close(lua_State *L) {
  Pty *p = check_pty(L, 1);
  shutdown_pty(p, 0);
  return 0;
}


static int f_gc(lua_State *L) {
  Pty *p = check_pty(L, 1);
  shutdown_pty(p, 1);
  return 0;
}


static const luaL_Reg meta[] = {
  { "__gc",   f_gc     },
  { "read",   f_read   },
  { "write",  f_write  },
  { "resize", f_resize },
  { "close",  f_close  },
  { "pid",    f_pid    },
  { "running", f_running },
  { NULL, NULL }
};


static const luaL_Reg lib[] = {
  { "open", f_open },
  { NULL, NULL }
};


int luaopen_pty(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_PTY);
  luaL_setfuncs(L, meta, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, lib);
  return 1;
}
