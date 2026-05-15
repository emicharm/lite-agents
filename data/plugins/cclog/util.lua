-- cclog/util.lua
--
-- Shared helpers used by the provider adapters and the orchestration layer.
-- Pure functions only — no UI or core dependencies.

local json = require "libraries.json"

local util = {}

function util.home_dir()
  return os.getenv("HOME") or ""
end

function util.path_exists(p)
  return p and system.get_file_info(p) ~= nil
end

function util.basename(p)
  return (p or ""):match("[^/\\]+$") or p
end

function util.collapse_ws(s)
  s = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return "" end
  return (s:gsub("[\r\n\t]", " "):gsub("  +", " "))
end

-- Trim outer whitespace, normalise CRLF, but preserve interior newlines and
-- indentation. Use this for text we intend to render as markdown.
function util.trim(s)
  s = (s or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

function util.truncate_lines(s, n)
  if not s or n <= 0 then return "" end
  local seen, idx = 0, 0
  for i = 1, #s do
    if s:byte(i) == 10 then
      seen = seen + 1
      if seen >= n then idx = i; break end
    end
  end
  if idx == 0 then return s end
  local head = s:sub(1, idx - 1)
  local tail = s:sub(idx + 1)
  if tail == "" then return head end
  local more = 1
  for i = 1, #tail do if tail:byte(i) == 10 then more = more + 1 end end
  return head .. string.format("\n… (%d more lines)", more)
end

local function fmt_num(v, suf)
  local rounded = math.floor(v * 10 + 0.5) / 10
  if rounded == math.floor(rounded) then
    return string.format("%d%s", rounded, suf)
  end
  return string.format("%.1f%s", rounded, suf)
end

function util.format_tokens(n)
  if not n or n < 1000 then return tostring(n or 0) end
  if n < 1e6 then return fmt_num(n / 1000, "k") end
  return fmt_num(n / 1e6, "M")
end

function util.short_model(m)
  if not m or m == "" then return "" end
  local s = m:gsub("^claude%-", "")
  return (s:gsub("%-(%d%d%d%d%d%d%d%d)$", ""))
end

-- RFC3339 → epoch seconds. Returns 0 if unparseable.
function util.parse_rfc3339(s)
  if not s or s == "" then return 0 end
  local y, mo, d, h, mi, se, _, tzs, tzh, tzm =
    s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)(%.?%d*)([Zz+%-]?)(%d?%d?):?(%d?%d?)$")
  if not y then return 0 end
  local t = os.time{ year=tonumber(y), month=tonumber(mo), day=tonumber(d),
                     hour=tonumber(h), min=tonumber(mi), sec=tonumber(se) }
  local utc_offset = os.time() - os.time(os.date("!*t"))
  t = t + utc_offset
  if tzs == "+" or tzs == "-" then
    local off = (tonumber(tzh) or 0) * 3600 + (tonumber(tzm) or 0) * 60
    if tzs == "+" then t = t - off else t = t + off end
  end
  return t
end

-- yield when we're inside a coroutine (sidebar thread); no-op otherwise.
function util.maybe_yield(n, every)
  if (n % (every or 50)) == 0 and coroutine.running() then
    coroutine.yield()
  end
end

-- Render the "content" field of an Anthropic-shape message (string OR array
-- of typed parts) as a single-line summary. Returns (summary, kind) where
-- kind may be refined from the caller's role to "tool_use"/"tool_result"/
-- "thinking" based on the parts.
function util.summarise_content(content, role)
  if type(content) == "string" then return util.collapse_ws(content), role end
  if type(content) ~= "table"  then return "", role end

  local parts = {}
  local kind  = role
  for _, p in ipairs(content) do
    local t = p.type or ""
    if t == "text" or t == "input_text" or t == "output_text" then
      table.insert(parts, util.trim(p.text or ""))
    elseif t == "tool_use" then
      local inp = p.input or {}
      local tail = {}
      if inp.description and inp.description ~= "" then
        table.insert(tail, util.collapse_ws(inp.description))
      end
      if inp.command and inp.command ~= "" then
        tail[#tail + 1] = "`" .. util.collapse_ws(inp.command) .. "`"
      end
      local s = p.name or "?"
      if #tail > 0 then s = s .. " - " .. table.concat(tail, " - ") end
      table.insert(parts, s)
      kind = "tool_use"
    elseif t == "tool_result" then
      table.insert(parts, "[tool_result]")
      kind = "tool_result"
    elseif t == "thinking" then
      local th = util.collapse_ws(p.thinking or "")
      table.insert(parts, th == "" and "[thinking]" or ("[thinking] " .. th))
      if role == "assistant" then kind = "thinking" end
    elseif t ~= "" then
      table.insert(parts, "[" .. t .. "]")
    end
  end
  return table.concat(parts, " · "), kind
end

-- Walk a directory tree collecting .jsonl files. Used by the Codex adapter.
function util.walk_jsonl(root, out)
  out = out or {}
  local entries = system.list_dir(root) or {}
  for _, name in ipairs(entries) do
    local full = root .. "/" .. name
    local st = system.get_file_info(full)
    if st then
      if st.type == "dir" then
        util.walk_jsonl(full, out)
      elseif name:sub(-6) == ".jsonl" then
        table.insert(out, { path = full, mtime = st.modified or 0 })
      end
    end
  end
  return out
end

-- Tail-read up to `n` bytes from the end of `path`. Cheap; used to look for
-- short metadata lines (e.g. Claude's "ai-title" record) without scanning the
-- entire file.
function util.tail_read(path, n)
  local f = io.open(path, "rb")
  if not f then return "" end
  local sz = f:seek("end") or 0
  local read_n = math.min(sz, n or 16384)
  f:seek("set", sz - read_n)
  local s = f:read(read_n) or ""
  f:close()
  return s
end

-- Encode an absolute cwd into the single directory name claude uses under
-- ~/.claude/projects/. Empirically, claude maps every char that isn't
-- [A-Za-z0-9-] to '-' (so '/', '.', '_', ' ', '[', ']' all collapse). Existing
-- '-' chars and runs of unsafe chars produce runs of '-' (e.g. " ] " → "---").
function util.encode_claude_cwd(cwd)
  if not cwd or cwd == "" then return "" end
  return (cwd:gsub("[^%w%-]", "-"))
end

-- Decode JSON, returning nil on failure rather than raising.
function util.try_decode(line)
  local ok, obj = pcall(json.decode, line)
  if ok then return obj end
  return nil
end

return util
