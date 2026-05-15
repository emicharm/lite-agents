-- beads/cli.lua
--
-- Wrapper around the `bd` CLI. Always called from inside core.add_thread —
-- io.popen blocks the calling coroutine; the editor stays responsive because
-- other threads run between yields. system.exec is unusable here because it
-- discards stdout (src/api/system.c).

local json = require "libraries.json"

local M = {}

local availability   -- nil = unknown, true/false = memoised
local workspace_cache = {}

local function shell_quote(s)
  if s == nil or s == "" then return "''" end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.available()
  if availability ~= nil then return availability end
  local h = io.popen("command -v bd 2>/dev/null")
  if not h then availability = false; return false end
  local out = h:read("*a") or ""
  h:close()
  availability = out:match("%S") ~= nil
  return availability
end

-- Walk up from `dir` looking for a `.beads/` directory. Returns absolute
-- workspace root, or nil if none. Cached per starting dir for the session.
function M.workspace_root(dir)
  if not dir or dir == "" then return nil end
  local cached = workspace_cache[dir]
  if cached ~= nil then
    if cached == false then return nil end
    return cached
  end
  local cur = dir
  while cur and cur ~= "" do
    local info = system.get_file_info(cur .. "/.beads")
    if info and info.type == "dir" then
      workspace_cache[dir] = cur
      return cur
    end
    local parent = cur:match("^(.+)/[^/]+$")
    if not parent or parent == cur then break end
    cur = parent
  end
  workspace_cache[dir] = false
  return nil
end

function M.run(args, project_dir)
  if not M.available() then return nil, "bd not installed" end
  local cmd = string.format(
    "bd -C %s %s --json --no-pager 2>&1",
    shell_quote(project_dir), args)
  local h = io.popen(cmd, "r")
  if not h then return nil, "popen failed" end
  local out = h:read("*a") or ""
  local ok, _, code = h:close()
  if not ok and code and code ~= 0 then
    local first = out:match("[^\r\n]+") or ""
    return nil, string.format("exit %d: %s", code, first)
  end
  local decoded_ok, decoded = pcall(json.decode, out)
  if not decoded_ok then
    local first = out:match("[^\r\n]+") or ""
    return nil, "bad json: " .. first
  end
  return decoded
end

return M
