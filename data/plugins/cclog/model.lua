-- cclog/data.lua
--
-- Thin orchestration layer over the per-provider adapters in
-- plugins.cclog.adapters.*. Discovers which provider stores exist on the
-- machine, fans scans out across them, and groups the resulting sessions by
-- cwd into a single unified project list.
--
-- Message shape (per provider.normalise):
--   { kind, summary, raw, ts, tokens }
--
-- Session shape (per provider.scan):
--   { id, path, source, last_dt, cwd, title? }
--
-- Project shape (built here):
--   { key, label, display, last_dt, sessions, sources = {claude=true,...} }

local util = require "plugins.cclog.util"

-- Provider registry ---------------------------------------------------------
local providers = {
  claude  = require "plugins.cclog.adapters.claude",
  codex   = require "plugins.cclog.adapters.codex",
  copilot = require "plugins.cclog.adapters.copilot",
}

local data = {}

data.providers = providers

-- Re-export common helpers so callers that already use data.format_tokens et
-- al. keep working.
data.format_tokens   = util.format_tokens
data.short_model     = util.short_model
data.truncate_lines  = util.truncate_lines

-- ── Source discovery ──────────────────────────────────────────────────────

function data.discover_sources()
  local out = {}
  for kind, p in pairs(providers) do
    local root = p.default_root()
    if util.path_exists(root) then
      table.insert(out, { kind = kind, root = root })
    end
  end
  return out
end

-- ── Per-line normalisation (for SessionView) ──────────────────────────────

function data.normalise(line, source)
  local p = providers[source]
  if not p then return nil end
  return p.normalise(line)
end

-- ── Streaming reads (full + tail) ─────────────────────────────────────────

function data.read_session(path, source, yield_every)
  local f = io.open(path, "rb"); if not f then return {}, 0 end
  local msgs, n = {}, 0
  yield_every = yield_every or 100
  for line in f:lines() do
    if line ~= "" then
      local m = data.normalise(line, source)
      if m then msgs[#msgs + 1] = m end
    end
    n = n + 1
    if n % yield_every == 0 and coroutine.running() then coroutine.yield() end
  end
  local size = f:seek("end") or 0
  f:close()
  return msgs, size
end

function data.tail_session(path, source, offset)
  local f = io.open(path, "rb"); if not f then return {}, offset end
  local size = f:seek("end") or 0
  if size <= offset then f:close(); return {}, offset end
  f:seek("set", offset)
  local rest = f:read("*a") or ""
  f:close()
  local out = {}
  for line in (rest .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local m = data.normalise(line, source)
      if m then out[#out + 1] = m end
    end
  end
  local new_offset = offset + #rest
  if #rest > 0 and rest:byte(#rest) ~= 10 then
    -- Partial trailing line: roll back so we re-read it on the next tick.
    local last_nl = rest:find("\n[^\n]*$")
    if last_nl then
      new_offset = offset + last_nl
      table.remove(out)
    else
      new_offset = offset
      out = {}
    end
  end
  return out, new_offset
end

-- ── Scan + group by cwd ────────────────────────────────────────────────────

function data.scan(sources)
  sources = sources or data.discover_sources()
  local by_key = {}
  for _, src in ipairs(sources) do
    local provider = providers[src.kind]
    if provider then
      local list = provider.scan(src.root)
      for _, s in ipairs(list) do
        local key = s.cwd or "(unknown)"
        local pi = by_key[key]
        if not pi then
          pi = {
            key      = key,
            display  = key,
            label    = (key == "(unknown)") and "(unknown)" or util.basename(key),
            cwd      = key,
            last_dt  = 0,
            sessions = {},
            sources  = {},
          }
          by_key[key] = pi
        end
        pi.sources[s.source] = true
        if s.last_dt > pi.last_dt then pi.last_dt = s.last_dt end
        table.insert(pi.sessions, s)
      end
    end
  end
  local out = {}
  for _, pi in pairs(by_key) do
    table.sort(pi.sessions, function(a, b)
      if a.last_dt == b.last_dt then return a.path < b.path end
      return a.last_dt > b.last_dt
    end)
    table.insert(out, pi)
  end
  table.sort(out, function(a, b) return a.last_dt > b.last_dt end)
  return out
end

-- ── Per-session stats (model + tokens + active), with mtime caching ───────

data._stats_cache = {}

function data.stats_for(path, mtime, source)
  local cached = data._stats_cache[path]
  if cached and cached.mtime == mtime then return cached end
  local provider = providers[source]
  if not provider then return cached end
  local stats = provider.read_stats(path)
  if not stats then return cached end
  stats.mtime = mtime
  data._stats_cache[path] = stats
  return stats
end

-- Cheap, mtime-cached activity check. Each adapter implements is_active() as
-- a tail-read so this is safe to call on every scan tick without paying the
-- full read_stats cost.
data._active_cache = {}

function data.is_active(path, mtime, source)
  local cached = data._active_cache[path]
  if cached and cached.mtime == mtime then return cached.active end
  local provider = providers[source]
  if not provider or not provider.is_active then return false end
  local active = provider.is_active(path)
  data._active_cache[path] = { mtime = mtime, active = active }
  return active
end

return data
