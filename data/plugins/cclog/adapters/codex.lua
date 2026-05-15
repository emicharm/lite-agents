-- cclog/providers/codex.lua
--
-- Codex CLI stores sessions under ~/.codex/sessions/YYYY/MM/DD/*.jsonl. The
-- first line is always a `session_meta` record giving the id, cwd, and start
-- timestamp. Conversation content is wrapped in {type, timestamp, payload}.

local util = require "plugins.cclog.util"

local M = { name = "codex" }

function M.default_root()
  return util.home_dir() .. "/.codex/sessions"
end

-- ~/.codex/session_index.jsonl maps session ids to human thread names.
local function read_index()
  local p = util.home_dir() .. "/.codex/session_index.jsonl"
  local f = io.open(p, "rb")
  if not f then return {} end
  local out = {}
  for line in f:lines() do
    local obj = util.try_decode(line)
    if obj and obj.id then out[obj.id] = obj.thread_name or "" end
  end
  f:close()
  return out
end

-- Read only the first line; session_meta is always there.
local function read_meta(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local line = f:read("*l")
  f:close()
  if not line then return nil end
  local obj = util.try_decode(line)
  if not obj or obj.type ~= "session_meta" or type(obj.payload) ~= "table" then
    return nil
  end
  return {
    id  = obj.payload.id or "",
    cwd = obj.payload.cwd or "",
    ts  = util.parse_rfc3339(obj.payload.timestamp),
  }
end

-- ── Scan ───────────────────────────────────────────────────────────────────

function M.scan(root)
  local files = util.walk_jsonl(root)
  local titles = read_index()
  local sessions = {}
  for i, f in ipairs(files) do
    local meta = read_meta(f.path)
    if meta and meta.id and meta.id ~= "" then
      local ts = (meta.ts ~= 0) and meta.ts or f.mtime
      table.insert(sessions, {
        id      = meta.id,
        path    = f.path,
        source  = "codex",
        last_dt = ts,
        cwd     = (meta.cwd ~= "") and meta.cwd or "(unknown)",
        title   = titles[meta.id] or "",
      })
    end
    util.maybe_yield(i, 50)
  end
  return sessions
end

-- ── Normalise ──────────────────────────────────────────────────────────────

function M.normalise(line)
  local obj = util.try_decode(line)
  if type(obj) ~= "table" or obj.type ~= "response_item" then return nil end
  local p = obj.payload
  if type(p) ~= "table" then return nil end
  local msg = { raw = line, ts = util.parse_rfc3339(obj.timestamp), tokens = 0 }
  if p.type == "message" and p.role then
    local s, k = util.summarise_content(p.content, p.role)
    msg.kind, msg.summary = k or p.role, s
    return msg
  elseif p.type == "function_call" then
    local inp = {}
    if type(p.arguments) == "string" and p.arguments ~= "" then
      local parsed = util.try_decode(p.arguments)
      if type(parsed) == "table" then inp = parsed end
    end
    local parts = { p.name or "?" }
    if inp.description and inp.description ~= "" then
      table.insert(parts, util.collapse_ws(inp.description))
    end
    if inp.command and inp.command ~= "" then
      parts[#parts + 1] = "`" .. util.collapse_ws(inp.command) .. "`"
    end
    msg.kind, msg.summary = "tool_use", table.concat(parts, " - ")
    return msg
  elseif p.type == "function_call_output" then
    msg.kind = "tool_result"
    msg.summary = "[tool_result] " .. util.collapse_ws(tostring(p.output or ""))
    return msg
  elseif p.type == "reasoning" then
    local summ = ""
    if type(p.summary) == "table" then
      for _, item in ipairs(p.summary) do
        if type(item) == "table" and item.text then
          summ = summ .. " " .. item.text
        elseif type(item) == "string" then
          summ = summ .. " " .. item
        end
      end
    elseif type(p.summary) == "string" then
      summ = p.summary
    end
    summ = util.collapse_ws(summ)
    if summ == "" then return nil end
    msg.kind, msg.summary = "thinking", "[thinking] " .. summ
    return msg
  end
  return nil
end

-- ── Activity (cheap, tail-only) ───────────────────────────────────────────
--
-- Codex emits `event_msg` records with payload.type == "task_complete" when
-- a turn ends. We look at the tail of the file for one of those.

function M.is_active(path)
  local tail = util.tail_read(path, 32 * 1024)
  if tail == "" then return true end
  for line in (tail .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local obj = util.try_decode(line)
      if type(obj) == "table" and obj.type == "event_msg"
         and type(obj.payload) == "table"
         and obj.payload.type == "task_complete" then
        return false
      end
    end
  end
  return true
end

-- ── Stats ──────────────────────────────────────────────────────────────────

function M.read_stats(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local model, tokens, active = "", 0, true
  local n = 0
  for line in f:lines() do
    n = n + 1
    util.maybe_yield(n, 200)
    local obj = util.try_decode(line)
    if type(obj) == "table" then
      if obj.type == "turn_context" and type(obj.payload) == "table"
         and obj.payload.model and obj.payload.model ~= "" then
        model = obj.payload.model
      elseif obj.type == "event_msg" and type(obj.payload) == "table" then
        if obj.payload.type == "token_count" and type(obj.payload.info) == "table" then
          local last  = obj.payload.info.last_token_usage  or {}
          local total = obj.payload.info.total_token_usage or {}
          local t = last.total_tokens or 0
          if t == 0 then t = total.total_tokens or 0 end
          if t > 0 then tokens = t end
        end
        if obj.payload.type == "task_complete" then active = false end
      end
    end
  end
  f:close()
  return { model = model, tokens = tokens, active = active }
end

return M
