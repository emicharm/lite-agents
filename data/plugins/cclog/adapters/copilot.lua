-- cclog/providers/copilot.lua
--
-- GitHub Copilot CLI lays out one directory per session under
-- ~/.copilot/session-state/<id>/. Each holds an events.jsonl plus a flat
-- workspace.yaml with id/cwd/name/branch.

local util = require "plugins.cclog.util"
local json = require "libraries.json"

local M = { name = "copilot" }

function M.default_root()
  return util.home_dir() .. "/.copilot/session-state"
end

-- Flat key:value YAML parser. Copilot's workspace.yaml has no nesting; we
-- intentionally don't pull in a full YAML library.
local function parse_workspace_yaml(path)
  local f = io.open(path, "rb"); if not f then return {} end
  local out = {}
  for line in f:lines() do
    local k, v = line:match("^([%w_]+):%s*(.*)$")
    if k then
      v = v:gsub("^%s*\"(.-)\"%s*$", "%1")
      out[k] = v
    end
  end
  f:close()
  return out
end

-- ── Scan ───────────────────────────────────────────────────────────────────

function M.scan(root)
  local sessions = {}
  local entries = system.list_dir(root) or {}
  for i, sid in ipairs(entries) do
    local sdir = root .. "/" .. sid
    local st = system.get_file_info(sdir)
    if st and st.type == "dir" then
      local events = sdir .. "/events.jsonl"
      local fst = system.get_file_info(events)
      if fst then
        local ws = parse_workspace_yaml(sdir .. "/workspace.yaml")
        table.insert(sessions, {
          id      = ws.id or sid,
          path    = events,
          source  = "copilot",
          last_dt = fst.modified or 0,
          cwd     = ws.cwd or "(unknown)",
          title   = ws.name or "",
        })
      end
    end
    util.maybe_yield(i, 50)
  end
  return sessions
end

-- ── Normalise ──────────────────────────────────────────────────────────────

function M.normalise(line)
  local obj = util.try_decode(line)
  if type(obj) ~= "table" or not obj.type then return nil end
  local msg = { raw = line, ts = util.parse_rfc3339(obj.timestamp), tokens = 0 }
  local t = obj.type
  local d = obj.data or {}

  if t == "user.message" then
    msg.kind, msg.summary = "user", util.collapse_ws(d.content or d.text or d.message or "")
    return msg
  elseif t == "assistant.message" then
    msg.kind = "assistant"
    if type(d.content) == "string" then
      msg.summary = util.collapse_ws(d.content)
    else
      local s = util.summarise_content(d.content or d.parts, "assistant")
      msg.summary = s
    end
    if d.usage and type(d.usage) == "table" then
      msg.tokens = (d.usage.input_tokens or 0)
                 + (d.usage.cache_creation_input_tokens or 0)
                 + (d.usage.cache_read_input_tokens or 0)
                 + (d.usage.prompt_tokens or 0)
    end
    return msg
  elseif t == "tool.execution_start" then
    msg.kind = "tool_use"
    local name = d.toolName or d.tool or d.name or "?"
    local cmd  = d.command or (d.input and d.input.command) or ""
    if type(cmd) ~= "string" then cmd = "" end
    msg.summary = (cmd ~= "")
                  and (name .. " - `" .. util.collapse_ws(cmd) .. "`")
                  or  name
    return msg
  elseif t == "tool.execution_complete" then
    msg.kind = "tool_result"
    local out = d.output or d.result or ""
    if type(out) ~= "string" then out = json.encode(out) end
    msg.summary = "[tool_result] " .. util.collapse_ws(out)
    return msg
  elseif t == "assistant.turn_start" or t == "assistant.turn_end" then
    msg.kind, msg.summary = "system", "[" .. t .. "]"
    return msg
  elseif t == "session.start" or t == "session.resume" or t == "session.shutdown"
      or t == "session.info"  or t == "session.warning" or t == "session.error"
      or t == "session.model_change" then
    msg.kind = "system"
    local note = d.message or d.errorType or d.warningType or ""
    msg.summary = "[" .. t .. "] " .. util.collapse_ws(tostring(note))
    return msg
  elseif t == "permission.requested" or t == "permission.completed" then
    msg.kind = "system"
    msg.summary = "[" .. t .. "] " .. util.collapse_ws(tostring(d.message or ""))
    return msg
  elseif t == "skill.invoked" then
    msg.kind = "tool_use"
    msg.summary = "Skill " .. (d.skillName or d.name or "?")
    return msg
  elseif t == "hook.start" or t == "hook.end" then
    msg.kind = "system"
    msg.summary = "[" .. t .. "] " .. util.collapse_ws(tostring(d.hookName or d.name or ""))
    return msg
  elseif t == "system.message" then
    msg.kind = "system"
    msg.summary = util.collapse_ws(tostring(d.content or d.message or ""))
    return msg
  end
  msg.kind, msg.summary = "system", "[" .. t .. "]"
  return msg
end

-- ── Activity (cheap, tail-only) ───────────────────────────────────────────
--
-- Copilot writes session.shutdown (graceful) or abort (interrupted) records
-- when a session ends. Their presence in the tail means the session is done.

function M.is_active(path)
  local tail = util.tail_read(path, 32 * 1024)
  if tail == "" then return true end
  for line in (tail .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local obj = util.try_decode(line)
      if type(obj) == "table"
         and (obj.type == "session.shutdown" or obj.type == "abort") then
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
      if obj.type == "session.start" or obj.type == "session.model_change"
         or obj.type == "session.resume" then
        local d = obj.data or {}
        if d.model and d.model ~= "" then model = d.model end
        local ctx = d.context
        if type(ctx) == "table" and ctx.model and ctx.model ~= "" then
          model = ctx.model
        end
      elseif obj.type == "assistant.message" then
        local u = (obj.data or {}).usage
        if type(u) == "table" then
          local t = (u.input_tokens or 0) + (u.prompt_tokens or 0)
                  + (u.cache_creation_input_tokens or 0)
                  + (u.cache_read_input_tokens or 0)
          if t > 0 then tokens = t end
        end
      elseif obj.type == "session.shutdown" or obj.type == "abort" then
        active = false
      end
    end
  end
  f:close()
  return { model = model, tokens = tokens, active = active }
end

return M
