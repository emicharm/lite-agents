-- cclog/providers/claude.lua
--
-- Claude Code stores one directory per cwd under ~/.claude/projects. The
-- directory name is a dash-encoded form of the path. Each .jsonl file is a
-- session, with one JSON record per line.

local util = require "plugins.cclog.util"

local M = { name = "claude" }

function M.default_root()
  return util.home_dir() .. "/.claude/projects"
end

-- "-Users-emi-foo" → "/Users/emi/foo" (best effort; some dirnames double-
-- encode slashes which we don't try to perfectly invert).
local function decode_dirname(s)
  return (s:gsub("%-", "/"))
end

-- Find the ai-title line cheaply. ai-title records are short metadata that
-- appear once per session; we scan the tail of the file (up to 16 KB) for the
-- substring and parse only the matching line.
local function read_ai_title(path)
  local tail = util.tail_read(path, 16 * 1024)
  if tail == "" then return "" end
  for line in (tail .. "\n"):gmatch("([^\n]*)\n") do
    if line:find('"type":"ai%-title"', 1, false) then
      local obj = util.try_decode(line)
      if obj and obj.aiTitle and obj.aiTitle ~= "" then
        return obj.aiTitle
      end
    end
  end
  return ""
end

-- ── Scan ───────────────────────────────────────────────────────────────────

function M.scan(root)
  local sessions = {}
  local entries = system.list_dir(root) or {}
  local n = 0
  for _, dirname in ipairs(entries) do
    local full = root .. "/" .. dirname
    local st = system.get_file_info(full)
    if st and st.type == "dir" then
      local files = system.list_dir(full) or {}
      local cwd = decode_dirname(dirname)
      for _, name in ipairs(files) do
        if name:sub(-6) == ".jsonl" then
          local p = full .. "/" .. name
          local fst = system.get_file_info(p)
          if fst then
            table.insert(sessions, {
              id      = name:sub(1, -7),
              path    = p,
              source  = "claude",
              last_dt = fst.modified or 0,
              cwd     = cwd,
              title   = read_ai_title(p),
            })
            n = n + 1
            util.maybe_yield(n, 50)
          end
        end
      end
    end
  end
  return sessions
end

-- ── Normalise one line into a Message ──────────────────────────────────────

function M.normalise(line)
  local obj = util.try_decode(line)
  if type(obj) ~= "table" then return nil end
  local msg = {
    raw    = line,
    ts     = util.parse_rfc3339(obj.timestamp),
    kind   = obj.type or "?",
    tokens = 0,
  }
  if obj.summary and obj.summary ~= "" then
    msg.summary = util.collapse_ws(obj.summary)
    return msg
  end
  if type(obj.message) == "table" then
    local role = obj.message.role or obj.type or ""
    local s, k = util.summarise_content(obj.message.content, role)
    msg.summary = s
    if k and k ~= role then msg.kind = k end
    local u = obj.message.usage
    if type(u) == "table" then
      msg.tokens = (u.input_tokens or 0)
                 + (u.cache_creation_input_tokens or 0)
                 + (u.cache_read_input_tokens or 0)
    end
  end
  if type(obj.content) == "string" and not msg.summary then
    msg.summary = util.collapse_ws(obj.content)
  end
  msg.summary = msg.summary or obj.type or ""
  return msg
end

-- ── Activity (cheap, tail-only) ───────────────────────────────────────────
--
-- A Claude session is "finished" when its trailing entries contain a Stop
-- hook attachment. We scan the last ~32 KB so this stays cheap on multi-MB
-- sessions.

function M.is_active(path)
  local tail = util.tail_read(path, 32 * 1024)
  if tail == "" then return true end
  local recent = {}
  for line in (tail .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local obj = util.try_decode(line)
      if type(obj) == "table" then
        table.insert(recent, obj)
        if #recent > 5 then table.remove(recent, 1) end
      end
    end
  end
  for _, obj in ipairs(recent) do
    local att = obj.attachment
    if obj.type == "attachment" and type(att) == "table"
       and att.type == "hook_success" and att.hookEvent
       and att.hookEvent:lower() == "stop" then
      return false
    end
  end
  return true
end

-- ── Stats (model + tokens + activity) ─────────────────────────────────────

local activity_window = 5

function M.read_stats(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local model, tokens = "", 0
  local recent = {}
  local n = 0
  for line in f:lines() do
    local obj = util.try_decode(line)
    if type(obj) == "table" then
      if type(obj.message) == "table" then
        if obj.message.model and obj.message.model ~= "" then
          model = obj.message.model
        end
        local u = obj.message.usage
        if type(u) == "table" then
          local t = (u.input_tokens or 0)
                  + (u.cache_creation_input_tokens or 0)
                  + (u.cache_read_input_tokens or 0)
          if t > 0 then tokens = t end
        end
      end
      local att = obj.attachment or {}
      table.insert(recent, { top = obj.type, att_type = att.type, hook = att.hookEvent })
      if #recent > activity_window then table.remove(recent, 1) end
    end
    n = n + 1
    util.maybe_yield(n, 200)
  end
  f:close()
  local active = true
  for _, r in ipairs(recent) do
    if r.top == "attachment" and r.att_type == "hook_success"
       and r.hook and r.hook:lower() == "stop" then
      active = false; break
    end
  end
  return { model = model, tokens = tokens, active = active }
end

return M
